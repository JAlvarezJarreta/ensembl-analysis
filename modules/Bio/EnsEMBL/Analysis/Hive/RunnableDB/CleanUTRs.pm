=head1 LICENSE

Copyright [1999-2015] Wellcome Trust Sanger Institute and the EMBL-European Bioinformatics Institute
Copyright [2016-2021] EMBL-European Bioinformatics Institute

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

     http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

=head1 CONTACT

Please email comments or questions to the public Ensembl
developers list at <http://lists.ensembl.org/mailman/listinfo/dev>.

Questions may also be sent to the Ensembl help desk at
<http://www.ensembl.org/Help/Contact>.

=head1 NAME

Bio::EnsEMBL::Analysis::Hive::RunnableDB::CleanUTRs

=head1 SYNOPSIS


=head1 DESCRIPTION


=cut

package Bio::EnsEMBL::Analysis::Hive::RunnableDB::CleanUTRs;

use strict;
use warnings;

use Bio::EnsEMBL::Analysis::Tools::GeneBuildUtils::GeneUtils qw(empty_Gene);
use Bio::EnsEMBL::Analysis::Tools::Algorithms::ClusterUtils qw(make_types_hash cluster_Genes);

use parent qw(Bio::EnsEMBL::Analysis::Hive::RunnableDB::HiveBaseRunnableDB);


sub param_defaults {
  my ($self) = @_;

  return {
    %{$self->SUPER::param_defaults},
    min_size_utr_exon => 30,
    ratio_5prime_utr => .3,
    ratio_3prime_utr => .6,
    ratio_same_transcript => .02,
    ratio_max_allowed_difference => .05,
    ratio_expansion => 3,
    minimum_expanding_number_for_single_transcript => 2,
  }
}



sub fetch_input {
  my ($self) = @_;

  my $db = $self->get_database_by_name('source_db');
  if ($self->param_is_defined('target_db')) {
    $self->hrdb_set_con($self->get_database_by_name('target_db'), 'target_db');
  }
  else {
    $self->hrdb_set_con($db, 'target_db');
  }
  if ($self->param_is_defined('dna_db')) {
    my $dna_db = $self->get_database_by_name('dna_db');
    $db->dnadb($dna_db);
  }

  my $slice = $self->fetch_sequence($self->input_id, $db);
# We store the genes directly in output as we will store any genes but the transcripts will be modified
  my @genes;
  my @protein_coding;
  foreach my $gene (@{$slice->get_all_Genes}) {
    if (@{$gene->get_all_Transcripts}) {
      $gene->load;
      push(@genes, $gene);
      if ($gene->biotype eq 'protein_coding') {
        push(@protein_coding, $gene);
      }
    }
    else {
      $self->say_with_header($gene->display_id.' has no transcript');
    }
  }
  if (@genes) {
    $self->output(\@genes);
    $self->param('protein_coding_genes', \@protein_coding);
  }
  else {
    $self->complete_early('No genes found for '.$self->input_id);
  }
}

sub run {
  my ($self) = @_;

  my $min_size_utr_exon = $self->param('min_size_utr_exon');
  my $ratio_5prime_utr = $self->param('ratio_5prime_utr');
  my $ratio_3prime_utr = $self->param('ratio_3prime_utr');
  my $ratio_same_transcript = $self->param('ratio_same_transcript');
  my $ratio_max_allowed_difference = $self->param('ratio_max_allowed_difference');
  my $ratio_expansion = $self->param('ratio_expansion');
  my $minimum_expanding_number_for_single_transcript = $self->param('minimum_expanding_number_for_single_transcript');
  my ($clusters, $unclustered) = cluster_Genes($self->param('protein_coding_genes'), make_types_hash($self->param('protein_coding_genes'), undef, 'set1'));
  foreach my $cluster (@$clusters) {
    my @overlapping_genes = sort {$a->start <=> $b->start || $a->end <=> $b->end} @{$cluster->get_Genes_by_Set('set1')};
    for (my $gene_index = 0; $gene_index <= $#overlapping_genes; $gene_index++) {
      my $gene = $overlapping_genes[$gene_index];
      $self->say_with_header("Working on $gene_index ".$gene->display_id);
      my $transcripts = $gene->get_all_Transcripts;
      for (my $next_gene_index = 0; $next_gene_index <= $#overlapping_genes; $next_gene_index++) {
        my $next_gene = $overlapping_genes[$next_gene_index];
        if ($gene_index != $next_gene_index) {
          $self->say_with_header("Checking $next_gene_index ".$next_gene->display_id);
          if ($gene->overlaps_local($next_gene)) {
            $self->say_with_header('Comparing '.$gene->display_id.' '.$next_gene->display_id);
            my $change_happened = 0;
            foreach my $transcript (@$transcripts) {
              if ($transcript->overlaps_local($next_gene)) {
                my $cds_start_genomic = $transcript->coding_region_start;
                my $cds_end_genomic = $transcript->coding_region_end;
                my $cds_start_index = 0;
                my $cds_end_index = 0;
                $self->say_with_header($transcript->display_id.' overlaps '.$next_gene->display_id);
                my %overlapping_exons;
                my %exons_to_delete;
                my @exons = sort {$a->start <=> $b->start} @{$transcript->get_all_Exons};
                my $count = 0;
                foreach my $exon (@exons) {
                  if ($cds_start_genomic >= $exon->start and $cds_start_genomic <= $exon->end) {
                    $cds_start_index = $count;
                  }
                  if ($cds_end_genomic >= $exon->start and $cds_end_genomic <= $exon->end) {
                    $cds_end_index = $count;
                  }
                  if ($exon->overlaps_local($next_gene)) {
                    $overlapping_exons{$exon->start.':'.$exon->end} = $exon;
                    $self->say_with_header('OVERLAP '.join(' ', $exon->display_id, $exon->start, $exon->end));
                  }
                  ++$count;
                }
                if (scalar(keys %overlapping_exons)) {
                  $self->say_with_header("$cds_start_genomic $cds_start_index $cds_end_genomic $cds_end_index");
                  my $new_utr_exon_start = 0;
                  my $new_utr_exon_end = 0;
                  foreach my $next_transcript (@{$next_gene->get_all_Transcripts}) {
                    $self->say_with_header('Comparing '.$transcript->display_id.' against '.$next_transcript->display_id);
                    foreach my $cds_exon (@{$next_transcript->get_all_CDS}) {
                      foreach my $utr_exon (values %overlapping_exons) {
                        if ($cds_exon->overlaps_local($utr_exon)) {
                          $self->say_with_header($cds_exon->start.':'.$cds_exon->end.' is overlapped by '.$utr_exon->display_id);
                          $exons_to_delete{$utr_exon->start.':'.$utr_exon->end} = $utr_exon;
                          if (!exists $overlapping_exons{$cds_exon->start.':'.$cds_exon->end}) {
                            if ($utr_exon->start <= $cds_start_genomic and $utr_exon->end >= $cds_start_genomic
                                and $utr_exon->start <= $next_transcript->coding_region_end and $utr_exon->end >= $next_transcript->coding_region_end) {
                              $new_utr_exon_start = $cds_exon->end;
                            }
                            if ($utr_exon->start <= $cds_end_genomic and $utr_exon->end >= $cds_end_genomic
                                and $utr_exon->start <= $next_transcript->coding_region_start and $utr_exon->end >= $next_transcript->coding_region_start) {
                              $new_utr_exon_end = $cds_exon->start;
                            }
                            $self->say_with_header($cds_exon->start.':'.$cds_exon->end." is not in hash $new_utr_exon_start $new_utr_exon_end");
                          }
                        }
                      }
                    }
                  }
                  if (scalar(keys %exons_to_delete)) {
                    $change_happened = 1;
                    my $translation;
                    if ($new_utr_exon_end and $transcript->strand == -1) {
                      $translation = $transcript->translation;
                    }
                    elsif ($new_utr_exon_start and $transcript->strand == 1) {
                      $translation = $transcript->translation;
                    }
                    $transcript->flush_Exons;
                    my $start_index = 0;
                    my $end_index = $#exons;
                    $self->say_with_header("$end_index exons to start with");
                    $self->say_with_header("Working on 5' end");
                    for (my $index = $cds_start_index; $index >= 0; $index--) {
                      $self->say_with_header("$cds_start_index $index");
                      if (exists $exons_to_delete{$exons[$index]->start.':'.$exons[$index]->end}) {
                        if ($exons_to_delete{$exons[$index]->start.':'.$exons[$index]->end}->start <= $cds_start_genomic and $exons_to_delete{$exons[$index]->start.':'.$exons[$index]->end}->end >= $cds_start_genomic) {
                          $start_index = $index;
                        }
                        last;
                      }
                      else {
                        $start_index = $index;
                      }
                    }
                    $self->say_with_header("Working on 3' end");
                    for (my $index = $cds_end_index; $index <= $#exons; $index++) {
                      $self->say_with_header("$cds_end_index $index");
                      if (exists $exons_to_delete{$exons[$index]->start.':'.$exons[$index]->end}) {
                        if ($exons_to_delete{$exons[$index]->start.':'.$exons[$index]->end}->start <= $cds_end_genomic and $exons_to_delete{$exons[$index]->start.':'.$exons[$index]->end}->end >= $cds_end_genomic) {
                          $end_index = $index;
                        }
                        last;
                      }
                      else {
                        $end_index = $index;
                      }
                    }
                    $self->say_with_header("Result: $start_index $end_index");
                    foreach my $exon (@exons[$start_index..$end_index]) {
                      if ($new_utr_exon_start >= $exon->start and $new_utr_exon_start <= $exon->end) {
                        if ($exon->strand == -1) {
                          $new_utr_exon_start = $cds_start_genomic-int(($cds_start_genomic-$exon->start)*$ratio_3prime_utr);
                        }
                        else {
                          $new_utr_exon_start = $cds_start_genomic-int(($cds_start_genomic-$exon->start)*$ratio_5prime_utr);
                        }
                        $self->say_with_header($new_utr_exon_start);
                        if ($cds_start_genomic-$new_utr_exon_start < $min_size_utr_exon) {
                          $new_utr_exon_start = $cds_start_genomic-$min_size_utr_exon;
                        }
                        $self->say_with_header($new_utr_exon_start);
                        if ($new_utr_exon_start < $exon->start) {
                          $new_utr_exon_start = $exon->start;
                        }
                        $self->say_with_header($new_utr_exon_start);
                        $self->say_with_header($translation || 'NULL');
                        $translation->start($cds_start_genomic-$new_utr_exon_start+1) if ($translation);
                        $exon->start($new_utr_exon_start);
                      }
                      if ($new_utr_exon_end >= $exon->start and $new_utr_exon_end <= $exon->end) {
                        if ($exon->strand == -1) {
                          $new_utr_exon_end = $cds_end_genomic+int(($exon->end-$cds_end_genomic)*$ratio_5prime_utr);
                        }
                        else {
                          $new_utr_exon_end = $cds_end_genomic+int(($exon->end-$cds_end_genomic)*$ratio_3prime_utr);
                        }
                        $self->say_with_header($new_utr_exon_end);
                        if ($new_utr_exon_end-$cds_end_genomic < $min_size_utr_exon) {
                          $new_utr_exon_end = $cds_end_genomic+$min_size_utr_exon;
                        }
                        $self->say_with_header($new_utr_exon_end);
                        if ($new_utr_exon_end > $exon->end) {
                          $new_utr_exon_end = $exon->end;
                        }
                        $self->say_with_header($new_utr_exon_end);
                        $self->say_with_header($translation || 'NULL');
                        $translation->start($new_utr_exon_end-$cds_end_genomic+1) if ($translation);
                        $exon->end($new_utr_exon_end);
                      }
                      $transcript->add_Exon($exon);
                    }
                    if ($translation and $translation->start_Exon == $translation->end_Exon) {
                      if ($transcript->strand == -1) {
                        $translation->start($translation->start_Exon->end-$cds_end_genomic+1);
                        $translation->end($translation->start_Exon->end-$cds_start_genomic+1);
                      }
                      else {
                        $translation->start($cds_start_genomic-$translation->start_Exon->start+1);
                        $translation->end($cds_end_genomic-$translation->start_Exon->start+1);
                      }
                    }
                  }
                }
              }
            }
            if ($change_happened) {
              my %hashes;
              my $transcripts = $gene->get_all_Transcripts;
              foreach my $transcript (@$transcripts) {
                my $id = '';
                foreach my $exon (@{$transcript->get_all_Exons}) {
                  $id .= join(':', $exon->start, $exon->end, $exon->phase, $exon->end_phase);
                }
                if ($transcript->translation) {
                  $id .= $transcript->translation->start.':'.$transcript->translation->end;
                }
                push(@{$hashes{$id}}, $transcript);
              }
              if (scalar(keys %hashes) != @$transcripts) {
                $gene->flush_Transcripts;
                foreach my $item (values %hashes) {
                  $gene->add_Transcript($item->[0]);
                }
              }
              else {
                $gene->recalculate_coordinates;
              }
              $self->throw($gene->display_id.' has no transcript') unless (@{$gene->get_all_Transcripts});
            }
          }
        }
      }
    }
  }
  my @extra_genes;
  foreach my $gene (@{$self->param('protein_coding_genes')}) {
    my @transcripts = sort {$a->end-$a->start <=> $b->end-$b->start } @{$gene->get_all_Transcripts};
    my $tcount = 0;
    foreach my $transcript (@transcripts) {
      ++$tcount if ($transcripts[0]->overlaps($transcript));
    }
    if ($tcount != scalar(@transcripts)) {
      my %data;
      foreach my $transcript (@transcripts) {
        my $stable_id = $transcript->display_id;
        $data{$stable_id}->{cds_length} = $transcript->translation->length;
        $data{$stable_id}->{cds_content} = $self->calculate_sequence_content($transcript->translation->seq);
      }
      my @genes;
      my %bridging_transcripts;
      foreach my $transcript (@transcripts) {
        my $current_gene;
        foreach my $cluster_gene (reverse @genes) {
          if ($transcript->overlaps_local($cluster_gene)) {
            if ($current_gene) {
              $bridging_transcripts{$transcript->display_id} = $transcript;
              last;
            }
            else {
              $current_gene = $cluster_gene;
            }
          }
        }
        if (!exists $bridging_transcripts{$transcript->display_id}) {
          if ($current_gene) {
            $current_gene->add_Transcript($transcript);
          }
          else {
            $current_gene = Bio::EnsEMBL::Gene->new();
            $current_gene->add_Transcript($transcript);
            $current_gene->analysis($transcript->analysis);
            $current_gene->biotype('protein_coding');
            push(@genes, $current_gene);
          }
        }
      }
      if (scalar(keys %bridging_transcripts) == 1) {
        my ($bridging_transcript) = values %bridging_transcripts;
        my $max_allowed_difference = int($bridging_transcript->translation->length*$ratio_max_allowed_difference);
        my $bridging_stable_id = $bridging_transcript->display_id;
        my $remove_transcript = 0;
        my %bridging_exon_seen;
        my $bridging_exons = $bridging_transcript->get_all_Exons;
        foreach my $new_gene (@genes) {
          foreach my $new_transcript (@{$new_gene->get_all_Transcripts}) {
            my $new_stable_id = $new_transcript->display_id;
            if ($data{$bridging_stable_id}->{cds_length}/$data{$new_stable_id}->{cds_length} > 1-$ratio_same_transcript
                  and $data{$bridging_stable_id}->{cds_length}/$data{$new_stable_id}->{cds_length} < 1+$ratio_same_transcript) {
              my $bridge_value = 0;
              my $new_value = 0;
              my $diff = 0;
              $remove_transcript = 1;
              foreach my $key (keys $data{$new_stable_id}->{cds_content}) {
                $bridge_value += $data{$bridging_stable_id}->{cds_content}->{$key} || 0;
                $new_value += $data{$new_stable_id}->{cds_content}->{$key};
                $diff = abs($bridge_value-$new_value) if (abs($bridge_value-$new_value) > $diff);
                if ($diff > $max_allowed_difference) {
                  $remove_transcript = 0;
                }
              }
            }
            else {
              my $index = -1;
              foreach my $bridging_exon (@$bridging_exons) {
                ++$index;
                next if (exists $bridging_exon_seen{$bridging_exon});
                if ($bridging_exon->overlaps_local($new_transcript)) {
                  $bridging_exon_seen{$bridging_exon} = [$bridging_exon, $new_gene, $index];
                }
              }
            }
          }
        }
        if (keys %bridging_exon_seen) {
          my $previous_gene;
          my $previous_rank;
          foreach my $item (sort {$a->[2] <=> $b->[2]} values %bridging_exon_seen) {
            if (defined $previous_gene and $previous_gene != $item->[1]) {
              if ($previous_rank+1 == $item->[2]) {
                $remove_transcript = 1;
                last;
              }
            }
            $previous_gene = $item->[1];
            $previous_rank = $item->[2];
          }
        }
        if ($remove_transcript) {
          $gene->flush_Transcripts;
          my $first_gene = shift(@genes);
          foreach my $t (@{$first_gene->get_all_Transcripts}) {
            $gene->add_Transcript($t);
          }
          foreach my $new_gene (@genes) {
            $self->output([$new_gene]);
            push(@extra_genes, $new_gene);
          }
          $bridging_transcript->biotype('readthrough');
          my $readthrough = Bio::EnsEMBL::Gene->new();
          $readthrough->add_Transcript($bridging_transcript);
          $readthrough->analysis($bridging_transcript->analysis);
          $readthrough->biotype($bridging_transcript->biotype);
          $self->output([$readthrough]);
        }
      }
      else {
        $gene->flush_Transcripts;
        my $first_gene = shift(@genes);
        foreach my $t (@{$first_gene->get_all_Transcripts}) {
          $gene->add_Transcript($t);
        }
        foreach my $new_gene (@genes) {
          $self->output([$new_gene]);
          push(@extra_genes, $new_gene);
        }
        foreach my $bridging_transcript (values %bridging_transcripts) {
          $bridging_transcript->biotype('readthrough');
          my $readthrough = Bio::EnsEMBL::Gene->new();
          $readthrough->add_Transcript($bridging_transcript);
          $readthrough->analysis($bridging_transcript->analysis);
          $readthrough->biotype($bridging_transcript->biotype);
          $self->output([$readthrough]);
        }
      }
    }
  }
  foreach my $gene (@{$self->param('protein_coding_genes')}, @extra_genes) {
    my @transcripts = sort {$a->end-$a->start <=> $b->end-$b->start } @{$gene->get_all_Transcripts};
    my @genes;
    my %expanding_transcripts;
    my $current_gene_size = $transcripts[0]->end-$transcripts[0]->start;
    $gene->flush_Transcripts;
    foreach my $transcript (@transcripts) {
      if ($current_gene_size*$ratio_expansion > $transcript->end-$transcript->start) {
        $current_gene_size = $transcript->end-$transcript->start;
        $gene->add_Transcript($transcript);
      }
      else {
        $expanding_transcripts{$transcript->display_id} = $transcript
      }
    }
    if (@{$gene->get_all_Transcripts} == 1 and scalar(keys %expanding_transcripts) > $minimum_expanding_number_for_single_transcript) {
      foreach my $expanding_transcript (values %expanding_transcripts) {
        $gene->add_Transcript($expanding_transcript);
      }
    }
    elsif (scalar(keys %expanding_transcripts) >= @{$gene->get_all_Transcripts}) {
      foreach my $expanding_transcript (values %expanding_transcripts) {
        if ($gene->length*$ratio_expansion >= ($expanding_transcript->coding_region_end-$expanding_transcript->coding_region_start+1)) {
          my $expanding_exons = $expanding_transcript->get_all_Exons;
          $expanding_transcript->flush_Exons;
          my %utr_5p = map {$_->start.':'.$_->end => $_ } @{$expanding_transcript->get_all_five_prime_UTRs};
          foreach my $expanding_exon (@$expanding_exons) {
            $expanding_transcript->add_Exon($expanding_exon) unless (exists $utr_5p{$expanding_exon->start.':'.$expanding_exon->end});
          }
          $gene->add_Transcript($expanding_transcript);
        }
        else {
          my $expanding_gene = Bio::EnsEMBL::Gene->new();
          $expanding_gene->add_Transcript($expanding_transcript);
          $expanding_gene->analysis($expanding_transcript->analysis);
          $expanding_gene->biotype('expanding');
          $self->output([$expanding_gene]);
        }
      }
    }
    else {
      foreach my $expanding_transcript (values %expanding_transcripts) {
        my $expanding_gene = Bio::EnsEMBL::Gene->new();
        $expanding_gene->add_Transcript($expanding_transcript);
        $expanding_gene->analysis($expanding_transcript->analysis);
        $expanding_gene->biotype('expanding');
        $self->output([$expanding_gene]);
      }
    }
  }
}

sub write_output {
  my ($self) = @_;

  my $gene_adaptor = $self->hrdb_get_con('target_db')->get_GeneAdaptor;
  my $suffix = $self->param('suffix');
  foreach my $gene (@{$self->output}) {
    if ($suffix) {
      my $biotype = $gene->biotype."_$suffix";
      $gene->biotype($biotype);
      foreach my $transcript (@{$gene->get_all_Transcripts}) {
        $transcript->biotype($biotype);
      }
    }
    empty_Gene($gene);
    $gene_adaptor->store($gene);
  }
}

sub calculate_sequence_content {
  my ($self, $seq) = @_;

  my %content;
  my $index = 0;
  while ($index < length($seq)) {
    ++$content{substr($seq, $index++, 1)};
  }
  return \%content;
}

1;