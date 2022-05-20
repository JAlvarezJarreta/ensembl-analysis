=head1 LICENSE

 Copyright [2022] EMBL-European Bioinformatics Institute

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

=cut

=head1 NAME

Bio::EnsEMBL::Analysis::Runnable::LowDivergenceMapping

=head1 SYNOPSIS

  my $runnable =
    Bio::EnsEMBL::Analysis::Runnable::LowDivergenceMapping->new();

 $runnable->run;
 my @results = $runnable->output;

=head1 DESCRIPTION

This module acts as a follow up to the LowDivergenceProjection module. It uses an alternative strategy to try and map genes
and transcripts that are absent or problematic from the projected set. In some cases these genes will be correctly missing,
so should not really be mapped, but this module will try anyway. The idea is to look at the expected location of the gene,
based on finding syntenic regions in the source and target dbs through high confidence, unambiguous projections. High confidence
unambiguous projections are ones that
1) Have all their transcripts mapped >= 99 percent cov and identity
2) Have only been mapped to one place
3) Don't overlap with something, or only overlap with something that they overlap with in the source
4) Have the same neighbouring genes as in source. Might need to be less strict on this due to scaffold level assemblies and
   the fact that things were allowed multimap in the previous step. At the same time, it may be fine to be strict in practice
   since the goal is to confidently get the region and not necessarily to completely pinpoint the exact location

Another point to consider is that if the target gene is supposed to be between two high confidence projections and the region
has shrunk in the target assembly versus the source, then that's an indication that a deletion/expansion might have happened

The next step in the process is to take the combined set of genes from the two modules and remove things that shouldn't be there

=head1 METHODS

=cut


package Bio::EnsEMBL::Analysis::Runnable::LowDivergenceMapping;

use warnings;
use strict;
use feature 'say';
use Data::Dumper;
use POSIX;
use List::Util qw(min max);

use Bio::EnsEMBL::Analysis::Runnable::Minimap2;
use Bio::EnsEMBL::Analysis::Runnable::ExonerateTranscript;
use Bio::EnsEMBL::Analysis::Tools::Algorithms::ClusterUtils;
use Bio::EnsEMBL::Analysis::Tools::GeneBuildUtils::TranslationUtils qw(compute_best_translation);
use Bio::EnsEMBL::Analysis::Tools::GeneBuildUtils::TranscriptUtils qw(set_alignment_supporting_features attach_Slice_to_Transcript attach_Analysis_to_Transcript calculate_exon_phases replace_stops_with_introns);
use Bio::EnsEMBL::Analysis::Tools::Utilities qw(create_file_name align_nucleotide_seqs map_cds_location align_proteins);
use File::Spec;
use Bio::DB::HTS::Faidx;
use Bio::EnsEMBL::Utils::Argument qw( rearrange );

use parent ('Bio::EnsEMBL::Analysis::Runnable');


=head2 new

 Arg [DECOMPRESS]           : String as a command like 'gzip -c -'
 Arg [EXPECTED_ATTRIBUTES]  : String specify the attribute expected for the output, see STAR manual
 Description                : Creates a  object to align reads to a genome using STAR
 Returntype                 : 
 Exceptions                 : Throws if WORKDIR does not exist
                              Throws if the genome has not been indexed

=cut

sub new {
  my ( $class, @args ) = @_;

  my $self = $class->SUPER::new(@args);
  my ($genome_index, $input_file, $paftools_path, $source_adaptor, $target_adaptor, $delete_input_file, $parent_genes, $parent_gene_ids, $no_projection) = rearrange([qw (GENOME_INDEX INPUT_FILE PAFTOOLS_PATH SOURCE_ADAPTOR TARGET_ADAPTOR DELETE_INPUT_FILE PARENT_GENES PARENT_GENE_IDS NO_PROJECTION)],@args);
  $self->genome_index($genome_index);
  $self->input_file($input_file);
  $self->paftools_path($paftools_path);
  $self->source_adaptor($source_adaptor);
  $self->target_adaptor($target_adaptor);
  $self->delete_input_file($delete_input_file);
  $self->genes_to_process($parent_genes);
  $self->parent_gene_ids($parent_gene_ids);
  $self->no_projection($no_projection);
  return $self;
}

=head2 run

 Arg [1]    : None
 Description: Run Star to align reads to an indexed genome. The resulting output file will be stored in $self->output
 Returntype : None
 Exceptions : None

=cut

sub run {
  my ($self) = @_;

  my $gene_genomic_seqs_hash = {};
  my $source_adaptor = $self->source_adaptor();
  my $target_adaptor = $self->target_adaptor();
  my $source_gene_adaptor = $source_adaptor->get_GeneAdaptor();
  my $target_gene_adaptor = $target_adaptor->get_GeneAdaptor();
  my $source_genes = $self->genes_to_process();
  # TEST!!!!!!!!!!!!!!!!
  my $test_slice = $target_adaptor->get_SliceAdaptor->fetch_by_region('toplevel','17');
  my $target_genes = $target_adaptor->get_GeneAdaptor->fetch_all_by_Slice($test_slice);

#  my $target_genes = $target_gene_adaptor->fetch_all();
  my $source_genes_by_slice = $self->sort_genes_by_slice($source_genes);
  my $target_genes_by_slice = $self->sort_genes_by_slice($target_genes);
  my $source_genes_by_stable_id = $self->genes_by_stable_id($source_genes);
  my $target_genes_by_stable_id = $self->genes_by_stable_id($target_genes);
  say "Searching for missing source genes";
  my $missing_source_genes = $self->list_missing_genes($source_genes_by_stable_id,$target_genes_by_stable_id);
  say "Found ".scalar(@$missing_source_genes)." missing source genes";

  foreach my $gene (@$target_genes) {
    # TEST!!!!!
    unless($gene->seq_region_name eq '17') {
      next;
    }
    my $source_gene = ${$source_genes_by_stable_id->{$gene->stable_id()}}[0];
    # TEST!!!!!!!!!!!!!
    unless($source_gene) {
      next;
    }
    my $source_transcripts = $source_gene->get_all_Transcripts();
    $self->check_complete_mapping($gene,$source_transcripts);
  }

  # This will add a list of all the genes on the slice ordered by increasing midpoint distance to every gene in the source set
  # It's probably overkill to calculate all distances per gene, but will leave it this way for now. Later having all of them
  # could allow a highly accurate global distance between the synteny of the source and target genes to be calculated
  say "Calculating source gene neighbours and midpoints";
  foreach my $slice (keys(%$source_genes_by_slice)) {
    say " Getting info for source genes on region: ".$slice;
    # TEST!!!!!!!!!!!!!!!!!
    unless($slice eq '17') {
      next;
    }
    my $genes = $source_genes_by_slice->{$slice};
    my $midpoint_coords_by_id = {};
    foreach my $gene (@$genes) {
      my $midpoint = $gene->start + ceil($gene->length()/2);
      unless($midpoint_coords_by_id->{$gene->stable_id()}) {
        $midpoint_coords_by_id->{$gene->stable_id()} = [];
      }
      push(@{$midpoint_coords_by_id->{$gene->stable_id()}},$midpoint);
    }
    foreach my $gene (@$genes) {
      $self->set_closest_gene_ids($gene,$midpoint_coords_by_id);
    }
  }

  say "Calculating high confidence genes in target";
  my $high_confidence_genes = $self->list_high_confidence_genes($target_genes_by_slice,$target_genes_by_stable_id,$source_genes_by_stable_id);
  my $high_confidence_genes_by_slice = $self->sort_genes_by_slice($high_confidence_genes);
  my $high_confidence_genes_by_id = $self->genes_by_stable_id($high_confidence_genes);

  my $high_confidence_count = 0;
  foreach my $gene (@$target_genes) {
    if($gene->{'is_high_confidence'}) {
       $high_confidence_count++;
    }
  }

  say "Got ".$high_confidence_count." high condfidence genes from a total of ".scalar(@$target_genes);


  my $input_file = $self->create_input_file($missing_source_genes,$gene_genomic_seqs_hash,$source_adaptor);
  my $paf_file = $self->create_filename(undef,'paf');
  $self->files_to_delete($paf_file);
  my $genome_index  = $self->genome_index;

  # run minimap2
  my $minimap2_command = $self->program." --cs --secondary=no -x map-ont ".$genome_index." ".$input_file." > ".$paf_file;
  $self->warning("Command:\n".$minimap2_command."\n");
  if(system($minimap2_command)) {
    $self->throw("Error running minimap2\nError code: $?\nCommand line used:\n".$minimap2_command);
  }

  my $paf_results = [];
  open(IN,$paf_file);
  while(<IN>) {
    chomp($_);
    push(@$paf_results,$_);
  }
  close IN;

  my $total_results = 0;
  my $processed_gene_ids = {};
  my $paf_results_hash = {};
  foreach my $paf_result (@$paf_results) {
    say "PAF results for first pass:\n".$paf_result;
    my @result_cols = split("\t",$paf_result);
    my $gene_id = $result_cols[0];
    if($paf_results_hash->{$gene_id}) {
      push(@{$paf_results_hash->{$gene_id}},\@result_cols)
    } else {
      $paf_results_hash->{$gene_id} = [\@result_cols];
    }
  }

  foreach my $gene_stable_id (keys(%$paf_results_hash)) {
    my $paf_results = $paf_results_hash->{$gene_stable_id};
    my $source_gene = ${$source_genes_by_stable_id->{$gene_stable_id}}[0];
    $self->filter_paf_hits($source_gene,$paf_results);
  }

  foreach my $gene (@$missing_source_genes) {
    say "Processing missing source gene: ".$gene->stable_id();
    $self->process_results($gene,$paf_results_hash,$target_genes);
  }


  # First identify the multimapping genes
#  my $multimapped_target_genes = $self->get_multimapped_target_genes($target_genes_by_stable_id,$source_genes_by_slice,$high_confidence_genes_by_id);
#  say "Found ".scalar(@$multimapped_target_genes)." instances of multimapped genes";

  # Then set the expected regions based on high confidence genes (if possible)
#  $self->check_expected_regions($multimapped_target_genes,$source_genes_by_stable_id,$source_genes_by_slice,$high_confidence_genes_by_id);
#   $self->check_expected_regions($target_genes,$source_genes_by_stable_id,$source_genes_by_slice,$high_confidence_genes_by_id);

# IDEA!!!!!!!!!!!!!!
# For the neighbourhood, only use non-overlapping genes to calculate, that way if things are piled up there can still be neighbourhood scores
# that are more or less correct, despite the pileup

  # Check for conflic. Conflict is when we have a gene with exon overlap with another gene, that it does not have exon overlap with in the reference
  # There are different levels of conflict, for example a very minor overlap with a neighbouring gene in the reference might just be a slight misalignment
  # of a UTR. Whereas if you have two genes with significant overlap, the assumption is that that are paralogues and thus one of them is mismapped. There
  # might be lots of them mismapped at a locus. For the moment we just want to record if there is conflict
  $target_genes_by_slice = $self->sort_genes_by_slice($target_genes);
  $target_genes_by_stable_id = $self->genes_by_stable_id($target_genes);

  $self->check_conflict($target_genes_by_slice,$source_genes_by_slice,$source_genes_by_stable_id,$target_genes_by_stable_id,$high_confidence_genes_by_id);

  # At this point any gene with conflict is labelled with $gene->{'genomic_conflict'} = 1 and has a list of conflicting stable ids with dbIDs as the values
  # accessed via $gene->{'conflicting_genes'}->{$id} = $dbID
  # This means we can loop through all the genes on the slice and decide what to do for each conflicting pair
  $self->resolve_conflict($target_genes_by_slice,$source_genes_by_slice,$source_genes_by_stable_id,$target_genes_by_stable_id);


  # Now that the conflict is set, it should be possible to at least clean multimappers. A conflicting multimapper outside the expected region or with a bad neighbourhood
  # score, or a lower than expected perc id/coverage should be the first things to clear up


  # At this point there will be any found missing genes added to target genes, so update the genes by slice and stable id
   # hashes to reflect that

  # First thing to do is to look at multimapping genes

  # Process results adds genes
#  $self->throw("DEBUG");
} # End run


sub resolve_conflict {
  my ($self,$target_genes_by_slice,$source_genes_by_slice,$source_genes_by_stable_id,$target_genes_by_stable_id) = @_;

  # This will go through the target genes and look for what overlaps then. First check stranded genomic overlap and
  # then exon overlap. Conflict is when a gene has exon overlap (need to decide level of exon overlap), with something
  # it does not have exon overlap with on the reference


  say "Processing genes by slice to remove conflicts";
  my $coverage_cutoff = 99;
  my $identity_cutoff = 99;

  my $genes_to_remove = {};
  foreach my $slice (keys(%$target_genes_by_slice)) {
    my $target_genes = $target_genes_by_slice->{$slice};
    for(my $i=0; $i<scalar(@$target_genes)-1; $i++) {
      my $gene = ${$target_genes}[$i];
      unless($gene->{'genomic_conflict'}) {
        next;
      }

      say "Examing gene ".$gene->stable_id()." (".$gene->dbID().") as it is listed as having conflict";
      if($genes_to_remove->{$gene->stable_id()}->{$gene->dbID()}) {
        say "  Skipping gene ".$gene->stable_id()." (".$gene->dbID().") as it is already listed for removal";
        next;
      }

      say "  Gene ".$gene->stable_id()." is in conflict with ".scalar(keys(%{$gene->{'conflicting_genes'}}))." genes, processing to resolve conflict";

      # How to resolve conflict, take the easiest cases first
      # Gene A is high confidence, Gene B is not
      # Gene A has a lower than expected cov/identity, gene B has passes
      # Gene A is in expected location, gene B is not
      # Gene A has a lower neighbourhood score than gene B
      # Gene A further from expected order than gene B
      # If it's sort of impossible to pick, just pick the one with the most exons
      foreach my $stable_id (keys(%{$gene->{'conflicting_genes'}})) {
        my $conflicting_db_id = $gene->{'conflicting_genes'}->{$stable_id};
        # If the conlficting gene has already been processed for removal, then there's nothing to do
        if($genes_to_remove->{$stable_id}->{$conflicting_db_id}) {
          next;
        }

        my $conflicting_gene;
        foreach my $target_conflicting_gene (@{$target_genes_by_stable_id->{$stable_id}}) {
          if($target_conflicting_gene->dbID == $conflicting_db_id) {
            $conflicting_gene = $target_conflicting_gene;
            last;
          }
        }

        # We now have the current gene and the conflicting gene, so start filtering
        # NOTE: ultimately a better strategy in terms of using syntenty info to begin with should go in here. But in this iteration
        #       we will use a more straightforward strategy to begin with

        # 1) Fliter based on confidence
        if($gene->{'is_high_confidence'} and !($conflicting_gene->{'is_high_confidence'})) {
          say "  Removing conflicting gene ".$conflicting_gene->stable_id()." (".$conflicting_gene->dbID().") as it is not high confidence while ".$gene->stable_id()." (".$gene->dbID().") is";
          $genes_to_remove->{$conflicting_gene->stable_id()}->{$conflicting_gene->dbID()} = 1;
          next;
        } elsif($conflicting_gene->{'is_high_confidence'} and !($gene->{'is_high_confidence'})) {
          $genes_to_remove->{$gene->stable_id()}->{$gene->dbID()} = 1;
          say "  Removing current gene ".$gene->stable_id()." (".$gene->dbID().") as it is not high confidence while ".$conflicting_gene->stable_id()." (".$conflicting_gene->dbID().") is";
          last;
        } else {
          say "  Both genes are high confidence";
        }

        # 2) Filter based on one gene passing cut-offs while the other fails
        if(($gene->{'avg_cov'} >= $coverage_cutoff and $gene->{'avg_perc_id'} >= $identity_cutoff) and ($conflicting_gene->{'avg_cov'} < $coverage_cutoff or $conflicting_gene->{'avg_perc_id'} < $identity_cutoff)) {
          $genes_to_remove->{$conflicting_gene->stable_id()}->{$conflicting_gene->dbID()} = 1;
          say "  Removing conflicting gene ".$conflicting_gene->stable_id()." (".$conflicting_gene->dbID().") as it fails the coverage/identity cut-off while ".$gene->stable_id()." (".$gene->dbID().") does not";
          next;
        } elsif(($conflicting_gene->{'avg_cov'} >= $coverage_cutoff and $conflicting_gene->{'avg_perc_id'} >= $identity_cutoff) and ($gene->{'avg_cov'} < $coverage_cutoff or $gene->{'avg_perc_id'} < $identity_cutoff)) {
          $genes_to_remove->{$gene->stable_id()}->{$gene->dbID()} = 1;
          say "  Removing current gene ".$gene->stable_id()." (".$gene->dbID().") as it fails the coverage/identity cut-off while ".$conflicting_gene->stable_id()." (".$conflicting_gene->dbID().") does not";
          last;
        } else {
          say "  Both genes pass coverage/perc id cut-offs: ".$gene->{'avg_cov'}."/".$gene->{'avg_perc_id'}." vs ".$conflicting_gene->{'avg_cov'}."/".$conflicting_gene->{'avg_perc_id'};
        }

        # 3) Filter by expected location
        if($gene->{'expected_location'} and !($conflicting_gene->{'expected_location'})) {
          $genes_to_remove->{$conflicting_gene->stable_id()}->{$conflicting_gene->dbID()} = 1;
          say "  Removing conflicting gene ".$conflicting_gene->stable_id()." (".$conflicting_gene->dbID().") as it is not in the expected location ".$gene->stable_id()." (".$gene->dbID().") is";
          next;
        } elsif($conflicting_gene->{'expected_location'} and !($gene->{'expected_location'})) {
          $genes_to_remove->{$gene->stable_id()}->{$gene->dbID()} = 1;
          say "  Removing current gene ".$gene->stable_id()." (".$gene->dbID().") as it is not in the expected location ".$conflicting_gene->stable_id()." (".$conflicting_gene->dbID().") is";
          last;
        } else {
          say "  Both genes are in the expected location";
        }

      }
    } # for(my $i=0; $i<scalar
  } # foreach my $slice (keys

}

sub check_conflict {
  my ($self,$target_genes_by_slice,$source_genes_by_slice,$source_genes_by_stable_id,$target_genes_by_stable_id,$high_confidence_genes_by_id) = @_;

  # This will go through the target genes and look for what overlaps then. First check stranded genomic overlap and
  # then exon overlap. Conflict is when a gene has exon overlap (need to decide level of exon overlap), with something
  # it does not have exon overlap with on the reference
  foreach my $slice (keys(%$target_genes_by_slice)) {
    say "Calculating genomically overlapping genes for target slice: ".$slice;
    my $target_genes = $target_genes_by_slice->{$slice};
    for(my $i=0; $i<scalar(@$target_genes)-1; $i++) {
      my $gene1 = ${$target_genes}[$i];
      unless($gene1->{'genomic_overlapping_genes'}) {
        $gene1->{'genomic_overlapping_genes'} = {};
      }

      # Would be faster to go in both directions from the current gene and keep adding till no overlap
      my $overlap = 1;
      for(my $j=$i+1; $j<scalar(@$target_genes) and $overlap; $j++) {
        my $gene2 = ${$target_genes}[$j];

        if($self->coords_overlap($gene1->seq_region_start(),$gene1->seq_region_end(),$gene2->seq_region_start(),$gene2->seq_region_end()) and $gene1->strand() == $gene2->strand()) {
          $gene1->{'genomic_overlapping_genes'}->{$gene2->stable_id()} = $gene2->dbID();
        } else {
          $overlap = 0;
        }
      } # end for(my $j=$i+1;

      $overlap = 1;
      for(my $j=$i-1; $j>=0 and $overlap; $j--) {
        my $gene2 = ${$target_genes}[$j];
        if($self->coords_overlap($gene1->seq_region_start(),$gene1->seq_region_end(),$gene2->seq_region_start(),$gene2->seq_region_end()) and $gene1->strand() == $gene2->strand()) {
          $gene1->{'genomic_overlapping_genes'}->{$gene2->stable_id()} = $gene2->dbID();
        } else {
          $overlap = 0;
        }
      } # end for(my $j=$i-1;
    } # end for(my $i=0
  } # end foreach my $slice

  foreach my $slice (keys(%$target_genes_by_slice)) {
    say "Calculating source gene overlap for target genes that have overlap: ".$slice;
    my $target_genes = $target_genes_by_slice->{$slice};
    foreach my $target_gene (@$target_genes) {
      unless(scalar(keys(%{$target_gene->{'genomic_overlapping_genes'}}))) {
        next;
      }
      # At this point the target gene has something that overlaps with it on the same strand, so we want to investigate
      # If it has the same set of things overlapping as the reference (or less, since maybe something didn't project) then it's
      # not conflicting. If there are extra things overlapping, then there is some level of conflict. If there is no exon overlap
      # then at least for the moment we will mark it as non-conflicting. If there is exon overal, then there is positional conflict
      # and a decision needs to be made. Ideally if there's only a very small overlap we could forgive this as it's possibly just
      # an issue with a terminal UTR being misaligned slightly, but at least to being with we'll just count any exon overlap as conflict
      # We want to group things into conflicting sets and then try and reduce the contents of the sets down to a single choice wherever possible
      my $source_gene = ${$source_genes_by_stable_id->{$target_gene->stable_id()}}[0];
      my $slice_source_genes = $source_genes_by_slice->{$source_gene->seq_region_name()};
      foreach my $slice_source_gene (@$slice_source_genes) {
        if($source_gene->stable_id() eq $slice_source_gene->stable_id()) {
          next;
        }
        if($self->coords_overlap($source_gene->seq_region_start(),$source_gene->seq_region_end(),$slice_source_gene->seq_region_start(),$slice_source_gene->seq_region_end())
           and $source_gene->strand() == $slice_source_gene->strand()) {
          $source_gene->{'genomic_overlapping_genes'}->{$slice_source_gene->stable_id()} = $source_gene->dbID();
        }
      }

      # At this point we have all the overlapping genes for the source and target
      foreach my $id (keys(%{$target_gene->{'genomic_overlapping_genes'}})) {
        unless($source_gene->{'genomic_overlapping_genes'}->{$id}) {
          my $source_conflict_gene = ${$source_genes_by_stable_id->{$id}}[0];
          my $target_conflict_gene_db_id =  $target_gene->{'genomic_overlapping_genes'}->{$id};
          my $target_conflict_gene;
          foreach my $gene (@{$target_genes_by_stable_id->{$id}}) {
            if($gene->dbID == $target_conflict_gene_db_id) {
              $target_conflict_gene = $gene;
              last;
            }
          }

          say "For ".$target_gene->stable_id()." got an unexpected overlap with ".$id.": Source: ".$source_gene->seq_region_name().":".$source_gene->seq_region_start().":".
              $source_gene->seq_region_end().":".$source_gene->strand()." ".$source_conflict_gene->seq_region_name().":".$source_conflict_gene->seq_region_start().":".
              $source_conflict_gene->seq_region_end().":".$source_conflict_gene->strand().", Target: ".$target_gene->seq_region_name().":".$target_gene->seq_region_start().":".
              $target_gene->seq_region_end().":".$target_gene->strand()." ".$target_conflict_gene->seq_region_name().":".$target_conflict_gene->seq_region_start().":".
              $target_conflict_gene->seq_region_end().":".$target_conflict_gene->strand();

          my $pairwise_coverage_cutoff = 0.75;
          my $pairwise_coverage = $self->get_pairwise_coverage($target_gene,$target_conflict_gene);
          if($pairwise_coverage >= $pairwise_coverage_cutoff) {
            say "The genes fail the average coverage check, classing as conflict. Average coverage: ".$pairwise_coverage;
            $target_gene->{'genomic_conflict'} = 1;
            $target_gene->{'conflicting_genes'}->{$target_conflict_gene->stable_id()} = $target_conflict_gene->dbID();
            $self->set_expected_regions([$source_gene],$source_genes_by_slice,$high_confidence_genes_by_id);
          }
        } # end unless($source_gene->{'genomic_overlapping_genes'}
      } # end foreach my $id (keys
    } # end oreach my $target_gene
  } # end foreach my $slice
}


sub get_pairwise_coverage {
  my ($self,$gene1,$gene2) = @_;

  my $max_start = max($gene1->seq_region_start(),$gene2->seq_region_start());
  my $min_end = min($gene1->seq_region_end(),$gene2->seq_region_end());
  my $overlap = max(1,$min_end-$max_start);

  my $gene1_overlap = $overlap / ($gene1->seq_region_end() - $gene1->seq_region_start());
  my $gene2_overlap = $overlap / ($gene2->seq_region_end() - $gene2->seq_region_start());

  my $average_overlap = ($gene1_overlap + $gene2_overlap) / 2;

  return($average_overlap);
}


sub check_expected_regions {
  my ($self,$target_genes,$source_genes_by_stable_id,$source_genes_by_slice,$high_confidence_genes_by_id) = @_;

#  foreach my $genes (@$multimapped_target_genes) {
  foreach my $gene (@$target_genes) {
#    my $stable_id = ${$genes}[0]->stable_id();
    my $stable_id = $gene->stable_id();
 #   say "FERGAL SID CHECK: ".$stable_id;
    my $source_gene = ${$source_genes_by_stable_id->{$stable_id}}[0];

    # TEST!!!
##    unless($source_gene) {
#      say "FERGAL DEBUG: issue with finding source gene so skipping";
#      next;
#    }
    unless($source_gene->seq_region_name eq '17') {
      next;
    }
 #   say "FERGAL SID CHECK2: ".$source_gene->stable_id();
    $self->set_expected_regions([$source_gene],$source_genes_by_slice,$high_confidence_genes_by_id);
    say "Checking multimappers for ".$stable_id;
#    foreach my $gene (@$genes) {
      # TEST!!!!!!!!!!!
      unless($gene->seq_region_name eq '17') {
        next;
      }

      if($gene->seq_region_name eq $source_gene->{'target_slice'} and $gene->seq_region_start() >= $source_gene->{'left_boundary'} and
         $gene->seq_region_end() <= $source_gene->{'right_boundary'}) {
        $gene->{'expected_location'} = 1;
        say "  Gene ".$gene->seq_region_start().":".$gene->seq_region_end().":".$gene->seq_region_strand().":".$gene->seq_region_name()." is in expected location:".
            "  ".$source_gene->{'target_slice'}.":".$source_gene->{'left_boundary'}.":".$source_gene->{'right_boundary'}.", Neighbourhood score: ".
            $gene->{'neighbourhood_score'}.", Avg cov: ".$gene->{'avg_cov'}.", Avg perc id: ".$gene->{'avg_perc_id'};
      } else {
        $gene->{'expected_location'} = 0;
        say "  Gene ".$gene->seq_region_start().":".$gene->seq_region_end().":".$gene->seq_region_strand().":".$gene->seq_region_name()." is not in expected location:".
            "  ".$source_gene->{'target_slice'}.":".$source_gene->{'left_boundary'}.":".$source_gene->{'right_boundary'}.", Neighbourhood score: ".
            $gene->{'neighbourhood_score'}.", Avg cov: ".$gene->{'avg_cov'}.", Avg perc id: ".$gene->{'avg_perc_id'};
      }
#    }
  }
}

sub get_multimapped_target_genes {
  my ($self,$target_genes_by_stable_id,$source_genes_by_slice,$high_confidence_genes_by_id) = @_;

  my $multimapped_genes = [];
  foreach my $id (keys(%$target_genes_by_stable_id)) {
    my $genes = $target_genes_by_stable_id->{$id};
    if(scalar(@$genes) > 1) {
      push(@$multimapped_genes,$genes);
    }
  }
  return($multimapped_genes);
}


sub create_input_file {
  my ($self,$genes,$gene_genomic_seqs_hash,$source_adaptor) = @_;

  my $source_sequence_adaptor = $source_adaptor->get_SequenceAdaptor();
  my $genomic_reads = [];
  foreach my $gene (@$genes) {
    my $slice = $gene->slice();

    # There's a big issue in terms of small genes, even with a fair amount of padding. To counter this have a minimum
    # target region size of about 50kb. If the gene is bigger then the padding itself should be enough as it's likely
    # there are many neutral sites in the gene already
    my $min_padding = 25000;

    my $region_start = $gene->seq_region_start - $min_padding;
    if($region_start < $slice->seq_region_start()) {
       $region_start = $slice->seq_region_start();
    }

    my $region_end = $gene->seq_region_end + $min_padding;
    if($region_end > $slice->seq_region_end()) {
      $region_end = $slice->seq_region_end();
    }

    my $genomic_seq = ${ $source_sequence_adaptor->fetch_by_Slice_start_end_strand($slice,$region_start,$region_end,1) };

    my $fasta_record = ">".$gene->stable_id()."\n".$genomic_seq;
    push(@$genomic_reads, $fasta_record);
    $gene_genomic_seqs_hash->{$gene->stable_id()} = [$region_start,$region_end,$genomic_seq];
  }

  my $output_file = $self->write_input_file($genomic_reads);
  return($output_file);
}


sub write_input_file {
  my ($self,$genomic_reads) = @_;

  my $output_file = $self->create_filename();
  open(OUT,">".$output_file);
  foreach my $genomic_read (@$genomic_reads) {
    say OUT $genomic_read;
  }
  close OUT;

  return($output_file);
}


sub set_expected_regions {
  my ($self,$genes,$source_genes_by_slice,$high_confidence_genes_by_id) = @_;

  # Foreach missing source gene, find the nearest non-overlapping 5' and 3' genes. Look these up in the high confidence set, keep looking up until
  # you either find a high confidence 5' and 3' on the same slice, or just take the nearest high confidence one and the expected length of the region
  # Maybe if you can't find two high confidence ones on the same slice that's a sign that we should try further anyway
  # Could take a few and see what the consensue region is, then focus on the two closest on that?

  foreach my $gene (@$genes) {
    say "Setting expected region for missing source gene with stable id ".$gene->stable_id();
    my $five_prime_neighbours = $self->fetch_neighbours($gene,$source_genes_by_slice,1);
    my $three_prime_neighbours = $self->fetch_neighbours($gene,$source_genes_by_slice,0);
    say "  Retrieved ".scalar(@$five_prime_neighbours)." 5' neighbours";
    say "  Retrieved ".scalar(@$three_prime_neighbours)." 3' neighbours";

    my $target_slice = $self->identify_target_slice([@$five_prime_neighbours,@$three_prime_neighbours],$high_confidence_genes_by_id);
    unless($target_slice) {
      say "  No target slice identified for missing gene with stable id ".$gene->stable_id().", skipping";
      next;
    }

    say "  Target slice retrieved: ".$target_slice;
    my ($left_boundary,$right_boundary) = $self->get_boundaries($gene,$five_prime_neighbours,$three_prime_neighbours,$high_confidence_genes_by_id,$target_slice);
    if($left_boundary and $right_boundary) {
      say "  Boundaries calculated: ".$left_boundary."..".$right_boundary;
    }
    $gene->{'left_boundary'} = $left_boundary;
    $gene->{'right_boundary'} = $right_boundary;
    $gene->{'target_slice'} = $target_slice;
  }
}


sub get_boundaries {
  my ($self,$gene,$five_prime_neighbours,$three_prime_neighbours,$high_confidence_genes_by_id,$target_slice) = @_;

  my $five_prime_gene;
  my $three_prime_gene;
  foreach my $neighbour_gene (@$five_prime_neighbours) {
    # THINK THIS WILL NEED TO ACCOUNT FOR ARRAYREF
    if($high_confidence_genes_by_id->{$neighbour_gene->stable_id()} and ${$high_confidence_genes_by_id->{$neighbour_gene->stable_id()}}[0]->seq_region_name eq $target_slice) {
      $five_prime_gene = ${$high_confidence_genes_by_id->{$neighbour_gene->stable_id()}}[0];
      last;
    }
  }

  foreach my $neighbour_gene (@$three_prime_neighbours) {
    # THINK THIS WILL NEED TO ACCOUNT FOR ARRAYREF
    if($high_confidence_genes_by_id->{$neighbour_gene->stable_id()} and ${$high_confidence_genes_by_id->{$neighbour_gene->stable_id()}}[0]->seq_region_name eq $target_slice) {
      $three_prime_gene = ${$high_confidence_genes_by_id->{$neighbour_gene->stable_id()}}[0];
      last;
    }
  }

  unless($five_prime_gene and $three_prime_gene) {
    say "Did not find both a high confidence 5' and 3' gene on the target slice, so cannot calculate a target region";
    return;
  }

  if($five_prime_gene->seq_region_end() < $three_prime_gene->seq_region_start()) {
    return($five_prime_gene->seq_region_end(),$three_prime_gene->seq_region_start());
  } else {
    return($three_prime_gene->seq_region_end(),$five_prime_gene->seq_region_start());
  }
}


sub identify_target_slice {
  my ($self,$neighbours,$high_confidence_genes_by_id) = @_;

  my $region_counter = {};
#  say "FERGAL DEBUG CHECKING NEIGHBOURS: ".scalar(@$neighbours)." ".scalar(keys(%$high_confidence_genes_by_id));
  foreach my $gene (@$neighbours) {
#    say "FERGAL DEBUG GSID: ".$gene->stable_id();
    unless($high_confidence_genes_by_id->{$gene->stable_id()}) {
      next;
    }

#    say "FERGAL DEBUG GSRN: ".$gene->seq_region_name();
    unless($region_counter->{$gene->seq_region_name()}) {
      $region_counter->{$gene->seq_region_name()} = 1;
    } else {
      $region_counter->{$gene->seq_region_name()}++;
    }
  }

  my $best_region;
  my $best_region_count = 0;
  foreach my $region (keys(%$region_counter)) {
    my $count = $region_counter->{$region};
    if($count > $best_region_count) {
      $best_region = $region;
      $best_region_count = $count;
    }
  }

  unless($best_region) {
    $self->warning("Didn't find a target region, implies no high confidence neighbours in the set");
  }
  return($best_region);
}

sub fetch_neighbours {
  my ($self,$gene,$genes_by_slice,$direction) = @_;

  my $slice_name = $gene->seq_region_name();
  my $slice_genes = $genes_by_slice->{$slice_name};

  my $neighbour_limit = 50;
  my $neighbours = [];
  for(my $i=0; $i<scalar(@$slice_genes); $i++) {
    my $slice_gene = ${$slice_genes}[$i];
    if($slice_gene->stable_id() eq $gene->stable_id()) {
      my $neighbour_counter = 0;
      if($direction) {
        for(my $j=$i-1; $j>=0 and $neighbour_counter < $neighbour_limit; $j--) {
          my $neighbour_gene = ${$slice_genes}[$j];
          if($self->coords_overlap($gene->seq_region_start(),$gene->seq_region_end(),$neighbour_gene->seq_region_start(),$neighbour_gene->seq_region_end())) {
            next;
          }
          # At this point we have a gene that doesn't overlap in the 5' direction
          push(@$neighbours,$neighbour_gene);
          $neighbour_counter++;
        }
      } else {
        for(my $j=$i+1; $j<scalar(@$slice_genes) and $neighbour_counter < $neighbour_limit; $j++) {
          my $neighbour_gene = ${$slice_genes}[$j];
          if($self->coords_overlap($gene->seq_region_start(),$gene->seq_region_end(),$neighbour_gene->seq_region_start(),$neighbour_gene->seq_region_end())) {
            next;
          }
          # At this point we have a gene that doesn't overlap in the 3' direction
          push(@$neighbours,$neighbour_gene);
          $neighbour_counter++;
        }
      }
      last;
    }
  }
  return($neighbours);
}

sub list_high_confidence_genes {
  my ($self,$target_genes_by_slice,$target_genes_by_stable_id,$source_genes_by_stable_id) = @_;

  my $high_confidence_genes = [];
  foreach my $target_slice (keys(%$target_genes_by_slice)) {
    unless($target_slice eq '17') {
      next;
    }
    my $target_slice_genes = $target_genes_by_slice->{$target_slice};
    my $midpoint_coords_by_id = {};

    # First calculate the midpoints for the all the genes and store them by stable id. As the target ids might not be unique, this means
    # we have to store an arrayref
    say "  Setting midpoints for genes on ".$target_slice;
    foreach my $gene (@$target_slice_genes) {
      # By default say the gene is not high confidence
      $gene->{'is_high_confidence'} = 0;
      my $midpoint = $gene->start + ceil($gene->length()/2);
      unless($midpoint_coords_by_id->{$gene->stable_id()}) {
        $midpoint_coords_by_id->{$gene->stable_id()} = [];
      }
      push(@{$midpoint_coords_by_id->{$gene->stable_id()}},$midpoint);
    }

    # Now set the closest set of ids on the target genes, so we can get a score later against the reference
    say "  Setting closest genes for genes on ".$target_slice;
    foreach my $gene (@$target_slice_genes) {
      $self->set_closest_gene_ids($gene,$midpoint_coords_by_id);
    }

    # The source genes have already had their ordered neighbours calculated, so foreach target gene we should be able to get a score
    # for how similar the ordering is
    say "  Setting neighbourhood scores for genes on ".$target_slice;
    foreach my $gene (@$target_slice_genes) {
      my $source_gene = $source_genes_by_stable_id->{$gene->stable_id};
      unless($source_gene) {
#        $self->throw("Couldn't find a source gene with a matching stable id to the target. Target stable id: ".$gene->stable_id());
        # TEST!!!!!!!!!!
        say "Couldn't find a source gene with a matching stable id to the target. Target stable id: ".$gene->stable_id();
        $gene->{'neighbourhood_score'} = 0;
        next;
      }
      $self->set_neighbourhood_score($gene,${$source_genes_by_stable_id->{$gene->stable_id}}[0]);
    }


    # We now have a score on each gene in terms of how similar the source and target neighbours are (though a very basic calculation)
    # We can start deciding what genes are high confidence at this point
    my $neighbourhood_cutoff = 0.8;
    foreach my $id (keys(%$target_genes_by_stable_id)) {

      my $genes = $target_genes_by_stable_id->{$id};
      my $gene =  ${$genes}[0];
      # TEST!!!!!!!!!!!!!!!!!!
      unless($gene->seq_region_name eq '17') {
        next;
      }

      my $source_gene = ${$source_genes_by_stable_id->{$id}}[0];
      my $source_transcripts = $source_gene->get_all_Transcripts();

      if(scalar(@$genes) > 1) {
        say "  Gene with stable id ".$id." has multiple mappings, so not high confidence";
        next;
      }

      unless($gene->{'complete_mapping'}) {
        say "  Gene with stable id ".$id." fails the transcript mapping check, so not high confidence";
        next;
      }

      if($gene->{'neighbourhood_score'} < $neighbourhood_cutoff) {
        say "  Gene with stable id ".$gene->stable_id." fails the neighbourhood score cutoff, so not high confidence";
        next;
      }


      # At this point we are reasonably confident the gene is mapped correctly because it only maps in one place, has
      # all the transcripts mapped with hight coverage and identity and it has a very similar set of neighbouring genes
      # The weakness here is in the fact that the similar set of neighbouring genes is not that strict, but at the same
      # time some of these assemblies are scaffold level and thus break synteny artifically, there are real expansions
      # and contractions and the fact that these are single loci and have excellent mapping scores means it should almost
      # always be correct
      $gene->{'is_high_confidence'} = 1;
      push(@$high_confidence_genes,$gene);
    }
  }

  say "Found ".scalar(@$high_confidence_genes)." high confidence genes in target";
  return($high_confidence_genes);
}


sub check_complete_mapping {
  my ($self,$gene,$source_transcripts) = @_;

  my $coverage_cutoff = 99;
  my $perc_id_cutoff = 99;
  my $target_transcripts = $gene->get_all_Transcripts();

  $gene->{'complete_mapping'} = 1;

  my $target_transcript_ids = {};
  my $total_cov = 0;
  my $total_perc_id = 0;
  foreach my $target_transcript (@$target_transcripts) {
    my $description = $target_transcript->description();
    $description =~ /Parent: (ENS.+)\.\d+\, Coverage\: (\d+\.\d+)\, Perc id\: (\d+\.\d+)/;
    my $stable_id = $1;
    my $coverage = $2;
    my $perc_id = $3;
    unless($stable_id and defined($coverage) and defined($perc_id)) {
      $self->throw("Issue finding info for parent stable id and coverage/identity from transcript description. Description: ".$description);
    }
    $target_transcript_ids->{$stable_id} = 1;
    $total_cov += $coverage;
    $total_perc_id += $perc_id;
  }

  my $avg_cov = $total_cov/scalar(@$target_transcripts);
  my $avg_perc_id = $total_perc_id/scalar(@$target_transcripts);
  $gene->{'avg_cov'} = $avg_cov;
  $gene->{'avg_perc_id'} = $avg_perc_id;
  unless($avg_perc_id >= $perc_id_cutoff and $avg_cov >= $coverage_cutoff) {
    say "  Gene fails average coverage and identity cutoffs, so failing: Covereage: ".$avg_cov.", Perc id: ".$avg_perc_id;
    $gene->{'complete_mapping'} = 0;
    return(0);
  }

  foreach my $source_transcript (@$source_transcripts) {
    unless($target_transcript_ids->{$source_transcript->stable_id}) {
      say "  Source transcript with stable id ".$source_transcript->stable_id." was not found in the target transcript stable id list, so failing";
      $gene->{'complete_mapping'} = 0;
      return(0);
    }
  }

  # This would be unusual given the other checks, but no harm keeping
  unless(scalar(@$source_transcripts) == scalar(@$target_transcripts)) {
    say "  Source and target transcript count differ, so failing";
    $gene->{'complete_mapping'} = 0;
    return(0);
  }

#  say "  Mapping check okay!";
  return(1);
}


sub set_neighbourhood_score {
  my ($self,$target_gene,$source_gene) = @_;

  my $neighbour_limit = 100;
  my $source_neighbours = $source_gene->{'sorted_neighbours'};
  my $filtered_source_neighbours = [];

  my $target_neighbours = $target_gene->{'sorted_neighbours'};
  my $target_neighbours_by_id = {};
  for(my $i=0; $i<scalar(@$target_neighbours) and $i<$neighbour_limit; $i++) {
    $target_neighbours_by_id->{${$target_neighbours}[$i]} = 1;
  }

  my $score = 0;
  for(my $i=0; $i<scalar(@$source_neighbours) and $i<$neighbour_limit; $i++) {
    my $id = ${$source_neighbours}[$i];
    if($target_neighbours_by_id->{$id}) {
      $score++;
    }
  }

  my $neighbourhood_score = $score/$neighbour_limit;
#  say "Neighbourhood score ".$target_gene->stable_id.": ".$neighbourhood_score;
  $target_gene->{'neighbourhood_score'} = $neighbourhood_score;
}


sub set_closest_gene_ids {
  my ($self,$gene,$midpoint_coords_by_id) = @_;

  my $id_distances = {};
  my $gene_midpoint = $gene->start + ceil($gene->length()/2);

  # Loop through each id, calculate the distance between the midpoint of the current gene and the midpoint of each other gene
  # If there are more than one genes for an id, then take the distance of the closest one
  foreach my $id (keys(%$midpoint_coords_by_id)) {
    if($id eq $gene->stable_id()) {
      next;
    }
    my $slice_gene_id_midpoints = $midpoint_coords_by_id->{$id};
    my $min_dist;
    foreach my $midpoint (@$slice_gene_id_midpoints) {
      my $dist = abs($gene_midpoint - $midpoint);
      unless($id_distances->{$id}) {
        $id_distances->{$id} = $dist;
      } elsif($dist < $id_distances->{$id}) {
        $id_distances->{$id} = $dist;
      }
    }
  }

  # At this point $id_distance will have exactly one distance per id so we should sort and add up to the ten closest ids
  my @sorted_ids = sort {$id_distances->{$a} <=> $id_distances->{$b}} keys(%$id_distances);
  $gene->{'sorted_neighbours'} = \@sorted_ids;
}

sub list_missing_genes {
  my ($self,$source_genes_by_stable_id,$target_genes_by_stable_id) = @_;

  my $missing_source_genes = [];
  foreach my $stable_id (keys(%$source_genes_by_stable_id)) {
    unless($target_genes_by_stable_id->{$stable_id}) {
      say "Missing the following stable id in target, will add to list: ".$stable_id;
      # TEST!!!!!!!!!!!!!!!!!!!
      unless(${$source_genes_by_stable_id->{$stable_id}}[0]->seq_region_name eq '17') {
        next;
      }
      push(@$missing_source_genes,${$source_genes_by_stable_id->{$stable_id}}[0]);
    }
  }
  return($missing_source_genes);
}


sub genes_by_stable_id {
  my ($self,$genes) = @_;

  # This holds genes in a hash using the stable id as the key. Note that while in the source we expect the stable id to be unique, we don't expect that in the target
  # Therefore the hash keys will point to an arrayref instead of just directly to the gene
  my $genes_by_id = {};
  foreach my $gene (@$genes) {
    unless($gene->stable_id()) {
      $self->throw("Gene with dbID ".$gene->dbID()." does not have a stable id assigned, need an assigned stable id to compare between source and target sets");
    }
    unless($genes_by_id->{$gene->stable_id()}) {
      $genes_by_id->{$gene->stable_id()} = [];
    }
    push(@{$genes_by_id->{$gene->stable_id()}},$gene);
  }
  return($genes_by_id);
}


sub sort_genes_by_slice {
  my ($self,$genes) = @_;

  my $genes_by_slice_hash = {};
  foreach my $gene (@$genes) {
    unless($genes_by_slice_hash->{$gene->seq_region_name()}) {
      $genes_by_slice_hash->{$gene->seq_region_name()} = [];
    }
    push(@{$genes_by_slice_hash->{$gene->seq_region_name()}},$gene);
  }

  foreach my $slice (keys(%$genes_by_slice_hash)) {
    my $slice_genes = $genes_by_slice_hash->{$slice};
    my @sorted_slice_genes  = sort { $a->start <=> $b->start } @{$slice_genes};
    $genes_by_slice_hash->{$slice} = \@sorted_slice_genes;
  }

  return($genes_by_slice_hash);
}


sub process_results {
  my ($self,$source_gene,$gene_genomic_seqs_hash,$target_genes) = @_;

  my $high_confidence = 0;

  my $gene_seq = $source_gene->seq();

  my $source_transcripts = $source_gene->get_all_Transcripts();
  my $source_transcript_id_hash = {}; # A hash to organise transcripts by dbID (note that the dbID is somewhat confusingly saved in the stable id field here, safer than using the realstable id)

  say "Source transcript list:";
  foreach my $source_transcript (@$source_transcripts) {
    say "  ".$source_transcript->stable_id();
    my $source_transcript_id = $source_transcript->dbID();
    $source_transcript_id_hash->{$source_transcript_id} = $source_transcript;
  }

  my $max_intron_size = $self->calculate_max_intron_size($source_transcripts);
  $max_intron_size = ceil($max_intron_size);
  say "Max intron size of transcripts in the cluster: ".$max_intron_size;

  my $good_transcripts = []; # Transcripts that pass the cut-off thresholds
  my $bad_source_transcripts = []; # The source transcripts for mapped Transcripts that don't pass the threshold
  my $bad_transcripts = []; # When both the minimap and exonerate mappings fail the cut-offs, this will store the version with the highest combined coverage and percent id

  my $target_adaptor = $self->target_adaptor();
  my $final_genes = [];
  my $paf_results = $source_gene->{'paf_regions'};
  foreach my $paf_result (@$paf_results) {
    my $best_transcripts_by_id = {};
    my $target_genomic_start = ${$paf_result}[0];
    my $target_genomic_end = ${$paf_result}[1];
    my $target_strand = ${$paf_result}[2];
    my $target_genomic_name = ${$paf_result}[3];

    if($target_strand eq '+') {
      $target_strand = 1;
    } else {
      $target_strand = -1;
    }

    say "Mapping gene ".$source_gene->stable_id()." to ".$target_genomic_start.":".$target_genomic_end.":".$target_strand.":".$target_genomic_name;

    my $target_slice_adaptor = $target_adaptor->get_SliceAdaptor();
    my $target_parent_slice = $target_slice_adaptor->fetch_by_region('toplevel',$target_genomic_name);

    unless($target_parent_slice) {
      $self->throw("Could not fetch the slice in the target assembly. Slice name: ".$target_genomic_name);
    }

    # Note that we are going to use the forward strand regardless of what strand the PAF hit is on here because minimap2/exonerate assume the region is on the forward strand
    my $target_sequence_adaptor = $target_adaptor->get_SequenceAdaptor;
    my $target_genomic_seq = ${ $target_sequence_adaptor->fetch_by_Slice_start_end_strand($target_parent_slice, $target_genomic_start, $target_genomic_end, 1) };
    my $target_region_slice = $target_slice_adaptor->fetch_by_region('toplevel', $target_genomic_name, $target_genomic_start, $target_genomic_end, 1);
    say "Target slice identified to search for transcripts in after first pass: ".$target_region_slice->name();
    my $target_genomic_fasta = ">".$target_genomic_name."\n".$target_genomic_seq;
    my $target_genome_file = $self->write_input_file([$target_genomic_fasta]);

    say "Projecting gene: ".$source_gene->stable_id();


    my $coverage_threshold = 98;
    my $perc_id_threshold = 98;
    my $projected_transcripts_by_id = $self->project_gene_coords($source_gene,$source_transcripts,$target_genomic_start,$target_region_slice,$target_strand,$gene_genomic_seqs_hash);
    $self->print_transcript_stats($projected_transcripts_by_id,'projection');
    $self->update_best_transcripts($best_transcripts_by_id,$projected_transcripts_by_id);

    my $minimap_transcripts_by_id = $self->map_gene_minimap($source_gene,$source_transcripts,$target_genomic_start,$target_region_slice,$target_strand,
                                                            $target_genome_file,$source_transcript_id_hash,$max_intron_size,$target_adaptor,$target_slice_adaptor,
                                                            $best_transcripts_by_id);
    $self->print_transcript_stats($minimap_transcripts_by_id,'minimap local');
    $self->update_best_transcripts($best_transcripts_by_id,$minimap_transcripts_by_id);

    my $exonerate_transcripts_by_id = $self->map_gene_exonerate($source_transcripts,$target_genomic_start,$target_region_slice,$target_strand,
                                                                $target_genome_file,$source_transcript_id_hash,$max_intron_size,$target_adaptor,
                                                                $target_slice_adaptor,$best_transcripts_by_id);
    $self->print_transcript_stats($exonerate_transcripts_by_id,'exonerate local');
    $self->update_best_transcripts($best_transcripts_by_id,$exonerate_transcripts_by_id);

    $self->set_cds_sequences($best_transcripts_by_id,$source_transcript_id_hash);
    $self->qc_cds_sequences($best_transcripts_by_id,$source_transcript_id_hash);
    $self->fix_cds_issues($best_transcripts_by_id);
    $self->set_transcript_descriptions($best_transcripts_by_id,$source_transcript_id_hash);

    my $all_transcripts = $self->label_transcript_status($best_transcripts_by_id);
    my $biotypes_hash = $self->generate_biotypes_hash($all_transcripts);

    # Need to create single transcript genes for clustering purposes
    say "Building single transcript genes ahead of clustering";
    my $single_transcript_genes = $self->generate_single_transcript_genes($all_transcripts);

    my $genes_by_seq_region = {};
    foreach my $gene (@$single_transcript_genes) {
      my $seq_region_name = $gene->seq_region_name();
      unless($genes_by_seq_region->{$seq_region_name}) {
        $genes_by_seq_region->{$seq_region_name} = [];
      }
      push(@{$genes_by_seq_region->{$seq_region_name}},$gene);
    }

    say "Clustering genes";
    my $found_good_cluster = 0;
    my $all_clusters = [];
    foreach my $seq_region_name (keys(%{$genes_by_seq_region})) {
      my $genes = $genes_by_seq_region->{$seq_region_name};
      my ($clusters, $unclustered) = cluster_Genes($genes,$biotypes_hash);
      # There's an issue here in terms of genes
      say "Found ".scalar(@$clusters)." transcript clusters";
      say "Found ".scalar(@$unclustered)." unclustered transcripts";
      push(@$all_clusters,@$clusters);
      push(@$all_clusters,@$unclustered);
    }

    say "Found ".scalar(@$all_clusters)." initial clusters";

    # The all_clusters array now has every cluster associated with mapped transcripts from the current source gene
    # Some of these clusters may have multiple mappings for a source transcript, or even multiple copies across clusters
    # So there needs to be a way to take the best copies, ideally only having one mapped transcript per source transcript
    foreach my $cluster (@$all_clusters) {
      $self->check_cluster_status($cluster);
      if($cluster->{'status'} eq 'good') {
        $found_good_cluster = 1;
      }
    }

    # To get the final list of clusters, you take all good clusters. If there are no good clusters you take the bad clusters
    my $final_clusters = [];
    foreach my $cluster (@$all_clusters) {
      if($cluster->{'status'} eq 'good') {
        push(@$final_clusters,$cluster);
      } elsif($cluster->{'status'} eq 'bad' and !$found_good_cluster) {
        push(@$final_clusters,$cluster);
      }
    }

    say "Found ".scalar(@$final_clusters)." final clusters";

    say "Building genes from final clusters";
    # Now remove duplicates and form genes
    my $parent_gene_ids = $self->parent_gene_ids();

    foreach my $cluster (@$final_clusters) {
      my $gene = $self->create_gene_from_cluster($cluster,$parent_gene_ids,$source_transcript_id_hash);
      say "Created gene: ".$gene->stable_id()." ".$gene->seq_region_name().":".$gene->seq_region_start.":".$gene->seq_region_end.":".$gene->strand();
      my $transcripts = $gene->get_all_Transcripts();
      foreach my $transcript (@$transcripts) {
        say "  Transcript: ".$transcript->stable_id()." ".$transcript->seq_region_start.":".$transcript->seq_region_end.":".$transcript->strand();
        my $updated_description = $transcript->description().", Annotation method: ".$transcript->{'annotation_method'};
        $transcript->description($updated_description);
      }

      push(@$final_genes,$gene);
    }

  }

  say "Build ".scalar(@$final_genes)." final genes";
  return($final_genes);
#  push(@$target_genes,@$final_genes);
#  $self->output($final_genes);
}


sub set_transcript_descriptions {
  my ($self,$transcripts_by_id,$source_transcript_id_hash) = @_;

  foreach my $id (keys(%$transcripts_by_id)) {
    my $transcript = $transcripts_by_id->{$id};
    my $source_transcript = $source_transcript_id_hash->{$transcript->stable_id()};
    my $description_string = "Parent: ".$source_transcript->stable_id().".".$source_transcript->version().", Coverage: ".$transcript->{'cov'}.", Perc id: ".$transcript->{'perc_id'};
    if($transcript->{'cds_description'}) {
      $description_string .= $transcript->{'cds_description'};
    }
    $transcript->description($description_string);
  }
}


sub qc_cds_sequences {
  my ($self,$transcripts_by_id,$source_transcript_id_hash) = @_;

  foreach my $id (keys(%$transcripts_by_id)) {
    my $transcript = $transcripts_by_id->{$id};
    my $source_transcript = $source_transcript_id_hash->{$transcript->stable_id()};
    if($source_transcript->translation()) {
      my ($cds_coverage,$cds_percent_id,$aligned_source_seq,$aligned_target_seq) = align_nucleotide_seqs($source_transcript->translateable_seq(),$transcript->translateable_seq());
      my $cds_description = ", CDS coverage: ".$cds_coverage." CDS perc id: ".$cds_percent_id;
      my $aligned_source_seq_copy = $aligned_source_seq;
      my $aligned_target_seq_copy = $aligned_target_seq;
      $aligned_source_seq_copy =~ s/\-\-\-//g;
      $aligned_target_seq_copy =~ s/\-\-\-//g;

      if($aligned_source_seq_copy =~ /\-/ or $aligned_target_seq_copy =~ /\-/) {
        $cds_description .= ", CDS gap: 1";
        my $transcript_attrib = Bio::EnsEMBL::Attribute->new(-CODE => 'proj_parent_t',
                                                             -VALUE => ">source_cds_align\n".$aligned_source_seq."\n>target_cds_align\n".$aligned_target_seq."\n");
        $transcript->add_Attributes($transcript_attrib);
        my $translation_attrib = Bio::EnsEMBL::Attribute->new(-CODE => 'proj_parent_t',
                                                              -VALUE => ">source_translation\n".$source_transcript->translation->seq().
                                                                        "\n>target_translation\n".$transcript->translation->seq()."\n");
        $transcript->translation->add_Attributes($translation_attrib);
      } else {
        $cds_description .= ", CDS gap: 0";
      }
      $transcript->{'cds_description'} = $cds_description;
    }
  }
}


sub set_cds_sequences {
  my ($self,$transcripts_by_id,$source_transcript_id_hash) = @_;

  foreach my $id (keys(%$transcripts_by_id)) {
    my $transcript = $transcripts_by_id->{$id};
    my $source_transcript = $source_transcript_id_hash->{$transcript->stable_id()};
    if($source_transcript->translation()) {
      $self->project_cds($transcript,$source_transcript);
    }
  }
}


sub project_cds {
  my ($self,$transcript,$source_transcript) = @_;

  # Here we want to utilise the alignment between the parent and target sequences to map the parent CDS start/end
  # Each transcript has the alignment stored on the object regardless of the reconstruction method, so this can be
  # a generic process. Note that the alignment stored is done on the transcipt seqs relative to whatever strand they
  # are on, so the two seqs will be in 5' to 3' orientation
  my $aligned_source_seq = $transcript->{'aligned_source_seq'};
  my $aligned_target_seq = $transcript->{'aligned_target_seq'};
  unless($aligned_source_seq and $aligned_target_seq) {
    $self->throw("Issue fetching alignment for transcript with stable_id ".$source_transcript->stable_id().", expected target transcript to have the alignment stored on it");
  }

  my $source_seq = $aligned_source_seq;
  $source_seq =~ s/\-//g;
  my $target_seq = $aligned_target_seq;
  $target_seq =~ s/\-//g;

  my @source_align_array = split('',$aligned_source_seq);
  my @target_align_array = split('',$aligned_target_seq);
  my $source_cds_pos = 0;
  my $source_align_seq_pos = 0;
  my $target_cds_pos = 0;
  my $target_align_seq_pos = 0;

  # Seen to have some issue in terms of getting the real start/end for some features. Was using +1, but seems off
  my $source_cds_start = $source_transcript->cdna_coding_start();
  my $source_cds_end = $source_transcript->cdna_coding_end();
  say "Source CDS start: ".$source_cds_start;
  say "Source CDS end: ".$source_cds_end;

  my $source_cds_start_index;
  my $source_cds_end_index;
  my $target_cds_start_index;
  my $target_cds_end_index;
  my $in_feature_alignment = 0;
  my $out_of_feature_alignment = 0;
  for(my $i=0; $i < scalar(@source_align_array); $i++) {
    my $source_value = $source_align_array[$i];
    my $target_value = $target_align_array[$i];
    if($source_value ne '-') {
      $source_cds_pos++;
    }

    if($target_value ne '-') {
      $target_cds_pos++;
    }

    if($source_cds_pos == $source_cds_start) {
      $source_cds_start_index = $source_cds_pos - 1;
      say "Index of the feature start in source seq: ".$source_cds_start_index;
      $in_feature_alignment = 1;
    }

    if($in_feature_alignment and $target_value ne '-' and !(defined($target_cds_start_index))) {
      $target_cds_start_index = $target_cds_pos - 1;
    }

    if($source_cds_pos == $source_cds_end) {
      $source_cds_end_index = $source_cds_pos - 1;
      $target_cds_end_index = $target_cds_pos - 1;
      say "Index of the feature end in source seq: ".$source_cds_end_index;
      $in_feature_alignment = 0;
    }
  }

  my $source_feature_length = $source_cds_end_index - $source_cds_start_index + 1;
  my $target_feature_length = $target_cds_end_index - $target_cds_start_index + 1;
  my $recovered_source_feature_seq = substr($source_seq,$source_cds_start_index,$source_feature_length);
  my $recovered_target_feature_seq = substr($target_seq,$target_cds_start_index,$target_feature_length);
  say "For transcript ".$source_transcript->stable_id()." original and mapped CDS sequences:\n".$recovered_source_feature_seq."\n".$recovered_target_feature_seq;

  my $cds_start_exon;
  my $cds_end_exon;
  my $cds_start_offset = 0;
  my $cds_end_offset = 0;
  my $cumulative_length = 0;
  my $exons = $transcript->get_all_Exons();
  foreach my $exon (@$exons) {
    say "Checking exons with the following start/end for CDS coords: ".$exon->start()."/".$exon->end();
    if(($target_cds_start_index >= $cumulative_length) and ($target_cds_start_index <= $cumulative_length + $exon->length())) {
      $cds_start_exon = $exon;
      if($transcript->strand == 1) {
        $cds_start_offset = $target_cds_start_index - $cumulative_length + 1;
      } else {
        say "FERGAL CDS START DEBUG: ".$exon->length." - (".($exon->length - $target_cds_start_index).") + 1";
        $cds_start_offset = $exon->length - ($exon->length - $target_cds_start_index) - $cumulative_length + 1;
      }
    }

    if(($target_cds_end_index >= $cumulative_length) and ($target_cds_end_index <= $cumulative_length + $exon->length())) {
      $cds_end_exon = $exon;
      if($transcript->strand == 1) {
        $cds_end_offset = $target_cds_end_index - $cumulative_length + 1;
      } else {
        say "FERGAL CDS END DEBUG: ".$exon->length." - (".($exon->length - $target_cds_end_index).") + 1";
        $cds_end_offset = $exon->length - ($exon->length - $target_cds_end_index) - $cumulative_length + 1;
      }
    }
    $cumulative_length += $exon->length();
  }

  unless($cds_start_exon and $cds_end_exon) {
    # Note this is only for testing, if this happens we should just put a warning and do a compute_translation
    # as there will probably be plenty of cases where a bad mapping means the exons are missing
    $self->warning("For ".$source_transcript->stable_id()." couldn't find the equivalent CDS start/end exon in the alignment of the transcripts. ".
                   "Will compute translation instead");
    compute_best_translation($transcript);
    return;
  }

  say "Orig CDS start/end exon lengths: ".$source_transcript->translation->start_Exon->length."/".$source_transcript->translation->end_Exon->length;
  say "Orig CDS start/end exon phases: ".$source_transcript->translation->start_Exon->phase()."/".$source_transcript->translation->end_Exon->end_phase();
  say "Orig CDS start exon frame: ".$source_transcript->translation->start_Exon->frame();
  say "Orig CDS start/end exon offsets: ".$source_transcript->translation->start()."/".$source_transcript->translation->end();
  say "CDS start/end index: ".$target_cds_start_index."/".$target_cds_end_index;
  say "CDS start/end exon lengths: ".$cds_start_exon->length()."/".$cds_end_exon->length();
  say "CDS start/end exon offsets: ".$cds_start_offset."/".$cds_end_offset;
  my $translation = Bio::EnsEMBL::Translation->new();
  $translation->start_Exon($cds_start_exon);
  $translation->start($cds_start_offset);
  $translation->end_Exon($cds_end_exon);
  $translation->end($cds_end_offset);
  $transcript->translation($translation);

  # Set the phases
  calculate_exon_phases($transcript,0);
  # Set the phase of the start exon to match the start exon of the source. We probably want some checks on this in general to ensure there's a
  # valid alignment at the start of the CDS. If the start is not conserved the best option would probably be to clip the start in the target to
  # the nearest aligned codon
  $transcript->translation->start_Exon->phase($source_transcript->translation->start_Exon->phase());

  say "For transcript ".$source_transcript->stable_id()." translateable seq:\n".$transcript->translateable_seq();
  say "For transcript ".$source_transcript->stable_id()." translation seq:\n".$transcript->translation->seq();
  say "Source transcript translation seq:\n".$source_transcript->translation->seq();
}


sub fix_cds_issues {
  my ($self,$transcripts_by_id) = @_;

  # First we should consider any transcript that has a non-perfect cds alignment


  # After the CDS has been updated in terms of potential issues with frameshifts or gaps, then examine for inframe stops and remove them
  # as needed. Polymorphic pseudogenes are expected to have inframe stops, so ignore these
  my $max_stops = 999;
  foreach my $id (keys(%$transcripts_by_id)) {
    my $transcript = $transcripts_by_id->{$id};
    if ($transcript->translation and $transcript->translation->seq() =~ /\*/ and $transcript->biotype ne 'polymorphic_pseudogene') {
      $transcript = replace_stops_with_introns($transcript,$max_stops);
      if ($transcript and $transcript->translate()->seq !~ /\*/) {
          #;#push(@$minimap_transcripts,$transcript_after_replaced_stops);
      } elsif (!$transcript->translate()) {
        print STDERR "minimap transcript (seq_region_start,seq_region_end,seq_region_strand,seq_region_name) (".$transcript->seq_region_start().
                     ",".$transcript->seq_region_end().",".$transcript->seq_region->strand().",".$transcript->seq_region_name().") does not translate after replacing a maximum of $max_stops stops. Discarded.\n";
        $transcript->translation(undef);
        $transcript->biotype("processed_transcript");
      } else {
        print STDERR "minimap transcript (seq_region_start,seq_region_end,seq_region_strand,seq_region_name) (".$transcript->seq_region_start().
                     ",".$transcript->seq_region_end().",".$transcript->seq_region->strand().",".$transcript->seq_region_name().") has more than the maximum of $max_stops stops or it has stops after replace_stops_with_introns. Discarded.\n";
        $transcript->translation(undef);
        $transcript->biotype("processed_transcript");
      }
    }

    if($transcript->translation()) {
      $self->check_and_fix_translation_boundaries($transcript);
    }
  }
}


sub filter_paf_hits {
  my ($self,$gene,$paf_results) = @_;

  my $hit_identity_cutoff = 0.99;
  say "Calculating hit regions withing expected boundaries for ".$gene->stable_id();
  my $gene_left_boundary = $gene->{'left_boundary'};
  my $gene_right_boundary = $gene->{'right_boundary'};
  my $gene_target_slice = $gene->{'target_slice'};
  unless($gene_left_boundary and $gene_right_boundary and $gene_target_slice) {
    say "Couldn't find expected gene boundaries for gene with stable id ".$gene->stable_id()."";
    return;
  }

  my $overlapping_paf_results = [];
  foreach my $paf_result (@$paf_results) {
    my $paf_target_genomic_start = ${$paf_result}[7];
    my $paf_target_genomic_end = ${$paf_result}[8];
    my $paf_target_genomic_name = ${$paf_result}[5];
    my $paf_hit_length = ${$paf_result}[1];
    my $paf_hit_identities = ${$paf_result}[9];
    my $paf_perc_ident = $paf_hit_identities/$paf_hit_length;

    if($gene_left_boundary and $gene_right_boundary and $gene_target_slice) {
      unless($paf_target_genomic_start >= $gene_left_boundary and $paf_target_genomic_end <= $gene_right_boundary and $gene_target_slice eq $paf_target_genomic_name and $paf_perc_ident >= $hit_identity_cutoff) {
        next;
      } else {
        push(@$overlapping_paf_results,$paf_result);
      }
    } elsif($paf_perc_ident >= $hit_identity_cutoff) {
      say "Missing gene ".$gene->stable_id()." did not have an identified high confidence target region. Will take only the top paf as it passes the identity cutoff";
      push(@$overlapping_paf_results,$paf_result);
      last;
    } else {
      say "Missing gene ".$gene->stable_id()." did not have an identified high confidence target region and failed identity cutoff on top hit, so will not process";
      last;
    }
  }

  my $extended_regions = [];
  foreach my $paf_result (@$overlapping_paf_results) {
    my $paf_strand = ${$paf_result}[4];
    my $paf_source_genomic_start = ${$paf_result}[2];
    my $paf_source_genomic_end = ${$paf_result}[3];
    my $paf_target_genomic_start = ${$paf_result}[7];
    my $paf_target_genomic_end = ${$paf_result}[8];
    my $paf_target_genomic_name = ${$paf_result}[5];
    my $source_genomic_length = ${$paf_result}[1];
    my $target_genomic_length = ${$paf_result}[6];

    say "  Initial paf hit: ".$paf_target_genomic_start.":".$paf_target_genomic_end.":".$paf_strand.":".$paf_target_genomic_name;
    # This will control the variability of the gap between two hits on the target relative to the
    # gap in coverage on the source sequence

    my $source_genomic_start = $paf_source_genomic_start;
    my $source_genomic_end = $paf_source_genomic_end;
    my $target_genomic_start = $paf_target_genomic_start;
    my $target_genomic_end = $paf_target_genomic_end;

    my $target_flanking = 500;
    my $scaling_ratio = 1.5;

    my $source_missing_coverage = $source_genomic_length - ($paf_source_genomic_end - $paf_source_genomic_start) + 1;
    my $source_missing_left = $paf_source_genomic_start;
    my $source_missing_right = $source_genomic_length - $paf_source_genomic_end;
    my $source_scaled_left = ceil($scaling_ratio * $source_missing_left) + $target_flanking;
    my $source_scaled_right = ceil($scaling_ratio * $source_missing_right) + $target_flanking;

    if($paf_strand eq '-') {
      my $tmp = $source_scaled_left;
      $source_scaled_left = $source_scaled_right;
      $source_scaled_right = $tmp;
    }

    $target_genomic_start -= $source_scaled_left;
    $target_genomic_end += $source_scaled_right;

    if($target_genomic_start <= 0) {
      $target_genomic_start = 1;
    }

    if($target_genomic_end > $target_genomic_length) {
      $target_genomic_end = $target_genomic_length;
    }

    push(@$extended_regions,[$target_genomic_start,$target_genomic_end,$paf_strand,$paf_target_genomic_name]);
  }

  # At this point, extended regions has any paf hit in the region, and it will have been extended based on the expected length of the region
  # versus the length of the hit itself. So if there were a few hits, it's likely that the different extended regions will actually just
  # describe the same region. If there are close paralogues, there may be distinct regions. This is okay, we will allow multi mapping and
  # then try and clear up later. At this point we want to cluster into however many distinct regions there are based on overlap
  my @sorted_res = sort { $a->[1] cmp $b->[1] } @$extended_regions;
  foreach my $region (@sorted_res) {
    my $start = ${$region}[0];
    my $end = ${$region}[1];
    my $strand = ${$region}[2];
  }

  for(my $i=0; $i<scalar(@sorted_res)-1; $i++) {
    my $res1 = $sorted_res[$i];
    unless($res1) {
      next;
    }
    my $coord_i_1 = ${$res1}[0];
    my $coord_i_2 = ${$res1}[1];
    my $strand_i = ${$res1}[2];
    my $region_i = ${$res1}[3];
    for(my $j=$i+1; $j<scalar(@sorted_res); $j++) {
      my $res2 = $sorted_res[$j];
      unless($res2) {
        next;
      }
      my $coord_j_1 = ${$res2}[0];
      my $coord_j_2 = ${$res2}[1];
      my $strand_j = ${$res2}[2];
      my $region_j = ${$res2}[3];
      if($self->coords_overlap($coord_i_1,$coord_i_2,$coord_j_1,$coord_j_2) and $strand_i eq $strand_j and $region_i eq $region_j) {
        $sorted_res[$i] = [min($coord_i_1,$coord_j_1),max($coord_i_2,$coord_j_2),$strand_i,$region_i];
        $sorted_res[$j] = undef;
      }
    } # End for $j
  } # End for $i

  my $final_paf_regions = [];
  foreach my $region (@sorted_res) {
    if($region) {
      push(@$final_paf_regions,$region);
      say " Chosen hit: ".${$region}[0].":".${$region}[1].":".${$region}[2].":".${$region}[3];
    }
  }

  $gene->{'paf_regions'} = $final_paf_regions;
}



sub chain_paf_results {
  my ($self,$paf_results) = @_;

  my $top_paf_result = shift(@$paf_results);
  my $top_paf_strand = ${$top_paf_result}[4];
  my $top_paf_source_genomic_start = ${$top_paf_result}[2];
  my $top_paf_source_genomic_end = ${$top_paf_result}[3];
  my $top_paf_target_genomic_start = ${$top_paf_result}[7];
  my $top_paf_target_genomic_end = ${$top_paf_result}[8];
  my $top_paf_target_genomic_name = ${$top_paf_result}[5];
  my $source_genomic_length = ${$top_paf_result}[1];

  say "Top paf source start/end: ".$top_paf_source_genomic_start."/".$top_paf_source_genomic_end;
  say "Top paf target start/end: ".$top_paf_target_genomic_start."/".$top_paf_target_genomic_end;
  # This will control the variability of the gap between two hits on the target relative to the
  # gap in coverage on the source sequence

  my $cluster_source_genomic_start = $top_paf_source_genomic_start;
  my $cluster_source_genomic_end = $top_paf_source_genomic_end;
  my $cluster_target_genomic_start = $top_paf_target_genomic_start;
  my $cluster_target_genomic_end = $top_paf_target_genomic_end;

  my $min_allowed_gap = 500;
  my $small_cluster_gap_size = 5000;
  my $small_cluster_gap_ratio = 2.5;
  my $large_cluster_gap_ratio = 1.2;
  foreach my $paf_result (@$paf_results) {
    my $hit_strand = ${$paf_result}[4];
    my $hit_genomic_name = ${$paf_result}[5];
    my $hit_source_genomic_start = ${$paf_result}[2];
    my $hit_source_genomic_end = ${$paf_result}[3];
    my $hit_target_genomic_start = ${$paf_result}[7];
    my $hit_target_genomic_end = ${$paf_result}[8];
    my $hit_target_genomic_name = ${$paf_result}[5];

    unless($hit_strand eq $top_paf_strand and $hit_genomic_name eq $top_paf_target_genomic_name) {
      next;
    }

    # Check if there's a feature overlap with the current cluster boundaries. If so skip
    if($self->coords_overlap($hit_source_genomic_start,$hit_source_genomic_end,$top_paf_source_genomic_start,$top_paf_source_genomic_end) or
       $self->coords_overlap($hit_target_genomic_start,$hit_target_genomic_end,$top_paf_target_genomic_start,$top_paf_target_genomic_end)) {
      next;
    }

    say "Hit source start/end: ".$hit_source_genomic_start."/".$hit_source_genomic_end;
    say "Hit target start/end: ".$hit_target_genomic_start."/".$hit_target_genomic_end;

    # At this point find the gap between the source region and the top hit source region, then do the same with the target regions
    # and determine if the source gap is similar to the target gap and if it is then adjust the cluster boundaries on the target
    my $source_gap = $self->calculate_coord_distance($top_paf_source_genomic_start,$top_paf_source_genomic_end,$hit_source_genomic_start,$hit_source_genomic_end);
    my $scaled_source_gap = $source_gap;
    if($source_gap <= $small_cluster_gap_size) {
      $scaled_source_gap = ($source_gap * $small_cluster_gap_ratio) + $min_allowed_gap;
    } else {
      $scaled_source_gap = ($source_gap * $large_cluster_gap_ratio) + $min_allowed_gap;;
    }

    my $target_gap = $self->calculate_coord_distance($top_paf_target_genomic_start,$top_paf_target_genomic_end,$hit_target_genomic_start,$hit_target_genomic_end);

    say "Source gap: ".$source_gap;
    say "Scaled source gap: ".$scaled_source_gap;
    say "Target gap: ".$target_gap;

    if($target_gap <= $scaled_source_gap) {
      if($hit_target_genomic_start < $cluster_target_genomic_start) {
        $cluster_target_genomic_start = $hit_target_genomic_start;
      }

      if($hit_target_genomic_end > $cluster_target_genomic_end) {
        $cluster_target_genomic_end = $hit_target_genomic_end;
      }

      if($hit_source_genomic_start < $cluster_source_genomic_start) {
        $cluster_source_genomic_start = $hit_source_genomic_start;
      }

      if($hit_source_genomic_end > $cluster_source_genomic_end) {
        $cluster_source_genomic_end = $hit_source_genomic_end;
      }
    }
  }

  say "Source cluster coverage start-end: ".$cluster_source_genomic_start."-".$cluster_source_genomic_end;
  say "Unadjuster cluster details: Start: ".$cluster_target_genomic_start.", End: ".$cluster_target_genomic_end.", Strand: ".$top_paf_strand.", Name: ".$top_paf_target_genomic_name;
  my $adjust_left = $cluster_target_genomic_start - $cluster_source_genomic_start;
  my $adjust_right = $cluster_target_genomic_end + ($source_genomic_length - $cluster_source_genomic_end);
  say "Final cluster details: Start: ".$cluster_target_genomic_start.", End: ".$cluster_target_genomic_end.", Strand: ".$top_paf_strand.", Name: ".$top_paf_target_genomic_name;
  return([$cluster_target_genomic_start,$cluster_target_genomic_end,$top_paf_strand,$top_paf_target_genomic_name]);
}


sub coords_overlap {
  my ($self,$s1,$e1,$s2,$e2) = @_;

  if (($s1 <= $e2) and ($e1 >= $s2)) {
    return 1;
  }
  return 0;
}


sub calculate_coord_distance {
  my ($self,$s1,$e1,$s2,$e2) = @_;

  my $dist = 0;
  if($s1 < $s2) {
    $dist = $s2-$e1;
  } else {
    $dist = $s1-$e2;
  }

  if($dist < 0) {
    $dist = 0;
  }
  return $dist;
}



sub check_for_small_gene {
  my ($self,$transcripts) = @_;

  # For the moment it's just going to check for genes with single exon short transcripts
  my $small_length = 100;
  my $is_small = 1;
  foreach my $transcript (@$transcripts) {
    if($transcript->length > $small_length) {
      $is_small = 0;
    }

    my $exons = $transcript->get_all_Exons();
    if(scalar(@$exons) > 1) {
      $is_small = 0;
    }
  }
  return($is_small);
}


sub print_transcript_stats {
  my ($self,$transcripts_by_id,$tag) = @_;

  say "Transcript stats for ".$tag;
  foreach my $id (keys(%$transcripts_by_id)) {
    my $transcript = $transcripts_by_id->{$id};
    say "  ID: ".$transcript->stable_id().", Cov: ".$transcript->{'cov'}.", Perc id: ".$transcript->{'perc_id'};
  }
}


sub map_gene_minimap {
  my ($self,$gene,$source_transcripts,$target_genomic_start,$target_region_slice,$target_strand,
      $target_genome_file,$source_transcript_id_hash,$max_intron_size,$target_adaptor,$target_slice_adaptor,$best_transcripts_by_id) = @_;

  my $target_genome_index = $target_genome_file.".mmi";
  my $target_index_command = $self->program()." -d ".$target_genome_index." ".$target_genome_file;
  my $index_result = system($target_index_command);
  if($index_result) {
    $self->throw('The minimap2 index command returned a non-zero exit code. Commandline used:\n'.$target_index_command);
  }

  my $source_transcript_fasta_seqs = [];
  my $source_transcripts_to_map = $self->filter_transcripts_to_map($source_transcripts,$best_transcripts_by_id);

  say "Processing a total of ".scalar(@$source_transcripts_to_map)." source transcripts via local minimap";

  foreach my $source_transcript (@$source_transcripts_to_map) {
    say "Writing ".$source_transcript->stable_id()." to file for mapping";
    my $source_transcript_sequence = $source_transcript->seq->seq();
    my $fasta_record = ">".$source_transcript->dbID()."\n".$source_transcript_sequence;
    push(@$source_transcript_fasta_seqs,$fasta_record);
  }

  say "Generating initial set of minimap2 mappings";
  my $minimap_transcripts = $self->generate_minimap_transcripts($source_transcript_fasta_seqs,$target_genome_index,$target_adaptor,$target_genomic_start,$max_intron_size);

  my $transcripts_by_id = {};
  foreach my $transcript (@$minimap_transcripts) {
    $transcripts_by_id->{$transcript->stable_id} = $transcript;
    my $source_transcript = $source_transcript_id_hash->{$transcript->stable_id};

    my ($mapped_coverage,$mapped_percent_id,$aligned_source_seq,$aligned_target_seq) = align_nucleotide_seqs($source_transcript->seq->seq(),$transcript->seq->seq());
    $transcript->{'cov'} = $mapped_coverage;
    $transcript->{'perc_id'} = $mapped_percent_id;
    $transcript->{'aligned_source_seq'} = $aligned_source_seq;
    $transcript->{'aligned_target_seq'} = $aligned_target_seq;
    say "Mapped transcript (".$source_transcript->stable_id()."): Coverage: ".$transcript->{'cov'}.", Percent id: ".$transcript->{'perc_id'};
  }
  return($transcripts_by_id);
}


sub map_gene_exonerate {
  my ($self,$source_transcripts,$target_genomic_start,$target_region_slice,$target_strand,
      $target_genome_file,$source_transcript_id_hash,$max_intron_size,$target_adaptor,$target_slice_adaptor, $best_transcripts_by_id) = @_;

  my $source_transcripts_to_map = $self->filter_transcripts_to_map($source_transcripts,$best_transcripts_by_id);

  say "Processing a total of ".scalar(@$source_transcripts_to_map)." source transcripts using Exonerate";

  my $exonerate_transcripts = $self->generate_exonerate_transcripts($source_transcripts_to_map,$source_transcript_id_hash,$target_region_slice,$target_slice_adaptor,$max_intron_size);

  my $transcripts_by_id = {};
  foreach my $transcript (@$exonerate_transcripts) {
    $transcripts_by_id->{$transcript->stable_id} = $transcript;
  }

  return($transcripts_by_id);
}


sub update_best_transcripts {
  my ($self,$best_transcripts_by_id,$new_transcripts_by_id,$coverage_threshold,$perc_id_threshold) = @_;

  my @ids = keys(%{$new_transcripts_by_id});
  foreach my $id (@ids) {
    unless($best_transcripts_by_id->{$id}) {
      $best_transcripts_by_id->{$id} = $new_transcripts_by_id->{$id};
    } else {
      my $best_coverage = $best_transcripts_by_id->{$id}->{'cov'};
      my $best_perc_id = $best_transcripts_by_id->{$id}->{'perc_id'};
      my $best_total = $best_coverage + $best_perc_id;
      my $transcript_coverage = $new_transcripts_by_id->{$id}->{'cov'};
      my $transcript_perc_id = $new_transcripts_by_id->{$id}->{'perc_id'};
      my $transcript_total = $transcript_coverage + $transcript_perc_id;

      if(($coverage_threshold and $perc_id_threshold) and ($transcript_coverage < $coverage_threshold or $transcript_perc_id < $perc_id_threshold)) {
        return;
      }

      if($transcript_total > $best_total) {
        # If a coverage and perc_id are specified, then we will not replace the current best model if it passes the thresholds
        # The use case is to not replace a model placed via the 2-pass approach with a globally aligned model unless the 2-pass
        # model fails the threshold. This is unlikely, but in the cases of close paralogues, a global incorrectly placed model
        # could score better than a correctly placed 2-pass model and this is slightly gatekeeping that
        if(($coverage_threshold and $perc_id_threshold) and ($best_coverage >= $coverage_threshold and $best_perc_id >= $perc_id_threshold)) {
          return;
        }
        $best_transcripts_by_id->{$id} = $new_transcripts_by_id->{$id};
      }
    }
  }
}


sub filter_transcripts_to_map {
  my ($self,$source_transcripts,$best_transcripts_by_id) = @_;

  my $coverage_cutoff = 98;
  my $identity_cutoff = 98;

  my $filtered_transcripts = [];
  foreach my $source_transcript (@$source_transcripts) {
    my $source_transcript_id = $source_transcript->dbID();
    unless($best_transcripts_by_id->{$source_transcript_id}) {
      push(@$filtered_transcripts,$source_transcript);
      next;
    }
    my $best_coverage = $best_transcripts_by_id->{$source_transcript_id}->{'cov'};
    my $best_perc_id = $best_transcripts_by_id->{$source_transcript_id}->{'perc_id'};
    unless($best_coverage >= $coverage_cutoff and $best_perc_id >= $identity_cutoff) {
      push(@$filtered_transcripts,$source_transcript);
    }
  }
  return($filtered_transcripts);
}


sub project_gene_coords {
  my ($self,$gene,$source_transcripts,$target_genomic_start,$target_region_slice,$target_strand,$gene_genomic_seqs_hash) = @_;

  my $transcripts_by_id = {};

  if($self->no_projection()) {
    return($transcripts_by_id);
  }

  my $source_genomic_seq_info = $gene_genomic_seqs_hash->{$gene->stable_id};

  unless($source_genomic_seq_info) {
    $self->throw("Could not find the genomic seq info for source gene with dbID: ".$gene->dbID());
  }

  my $source_region_start = ${$source_genomic_seq_info}[0];
  my $source_region_end = ${$source_genomic_seq_info}[1];
  my $source_genome_seq = ${$source_genomic_seq_info}[2];

  my $exons = $gene->get_all_Exons();
  my $target_genome_seq = $target_region_slice->seq();

  # Put back onto forward strand for simplicity
#  if($gene->strand != 1) {
#    $source_genome_seq = $self->revcomp($source_genome_seq);
#  }

  if($target_strand != 1) {
    $target_genome_seq = $self->revcomp($target_genome_seq);
  }

  my $projected_exons_by_id = {};
  # Sometimes issues with the MySQL server disconnecting on long alignments
  $self->source_adaptor->dbc->disconnect_when_inactive(1);
  $self->target_adaptor->dbc->disconnect_when_inactive(1);

  my $coverage = 0;
  my $percent_id = 0;
  my $aligned_source_seq;
  my $aligned_target_seq;
  eval {
    ($coverage,$percent_id,$aligned_source_seq,$aligned_target_seq) = align_nucleotide_seqs($source_genome_seq,$target_genome_seq);
  };
  if ($@) {
    $self->warning("Issue with running MAFFT on target region");
  } else {
    say "Aligned source and target regions with MAFFT: Coverage: ".$coverage.", Percent id: ".$percent_id;
  }


  unless($coverage and $percent_id) {
    say "No coverage/percent id calculated therefore not proceeding with projection";
    return($transcripts_by_id);
  }

  foreach my $exon (@$exons) {
    my $exon_region_start = $exon->seq_region_start();
    my $exon_region_end = $exon->seq_region_end();
    say "Source region start/end: ".$source_region_start."/".$source_region_end;
    say "Source exon region start/end: ".$exon_region_start."/".$exon_region_end;
    say "Source exon strand: ".$exon->strand();
    say "Target strand: ".$target_strand;

    my $projected_exon = $self->project_feature(undef,$exon,$source_region_start,$exon_region_start,$exon_region_end,$aligned_source_seq,$aligned_target_seq,$target_region_slice,$target_strand);

    if($projected_exon) {
      my ($proj_coverage,$proj_percent_id,$aligned_source_seq,$aligned_target_seq) = align_nucleotide_seqs($exon->seq->seq(),$projected_exon->seq->seq());
      say "Projected exon alignment scores: Coverage: ".$proj_coverage.", Perc identity: ".$proj_percent_id;
      $projected_exon->{'cov'} = $proj_coverage;
      $projected_exon->{'perc_id'} = $proj_percent_id;
      $projected_exon->{'source_stable_id'} = $exon->stable_id();
      $projected_exon->{'source_length'} = $exon->length();
      $projected_exons_by_id->{$projected_exon->{'source_stable_id'}} = $projected_exon;
    } else {
      say "Failed to project exon (".$projected_exon->{'source_stable_id'}.")";
    }
  }

  foreach my $source_transcript (@$source_transcripts) {
    my $projected_transcript = $self->reconstruct_transcript($source_transcript,$projected_exons_by_id);
    if($projected_transcript) {
      $projected_transcript->{'annotation_method'} = 'alignment_projection';
      $transcripts_by_id->{$projected_transcript->stable_id()} = $projected_transcript;
    }
  }
  return($transcripts_by_id);
}


sub reconstruct_transcript {
  my ($self,$source_transcript,$projected_exons_by_id) = @_;

  my $source_exons = $source_transcript->get_all_Exons();

  my $projected_exons = [];
  foreach my $source_exon (@$source_exons) {
    my $projected_exon = $projected_exons_by_id->{$source_exon->stable_id};
    if($projected_exon) {
      push(@$projected_exons,$projected_exon);
    }
  }

  unless(scalar(@$projected_exons)) {
    return;
  }

  my $projected_transcript = Bio::EnsEMBL::Transcript->new(-EXONS => $projected_exons);
  $projected_transcript->slice(${$projected_exons}[0]->slice());
  $projected_transcript->analysis($self->analysis());
  $projected_transcript->biotype($source_transcript->biotype());
  $projected_transcript->stable_id($source_transcript->dbID());
  $projected_transcript->version($source_transcript->version());
  $projected_transcript->{'source_stable_id'} = $source_transcript->stable_id();
  $projected_transcript->{'source_biotype_group'} = $source_transcript->get_Biotype->biotype_group();
  $projected_transcript->{'source_length'} = $source_transcript->length();

  my ($proj_coverage,$proj_percent_id,$aligned_source_seq,$aligned_target_seq) = align_nucleotide_seqs($source_transcript->seq->seq(),$projected_transcript->seq->seq());
  $projected_transcript->{'cov'} = $proj_coverage;
  $projected_transcript->{'perc_id'} = $proj_percent_id;
  $projected_transcript->{'aligned_source_seq'} = $aligned_source_seq;
  $projected_transcript->{'aligned_target_seq'} = $aligned_target_seq;
  say "Projected transcript (".$projected_transcript->{'source_stable_id'}.") ".$projected_transcript->seq_region_name." ".$projected_transcript->seq_region_start."/".
      $projected_transcript->seq_region_end." ".$projected_transcript->strand.": Coverage: ".$projected_transcript->{'cov'}.", Percent id: ".$projected_transcript->{'perc_id'};
  say "Alignment:\n".$aligned_source_seq."\n".$aligned_target_seq;

  return($projected_transcript);
}


sub project_feature {
  my ($self,$transcript,$exon,$source_region_start,$feature_start,$feature_end,$aligned_source_seq,$aligned_target_seq,$target_region_slice,$target_strand) = @_;

  # At this point we have the aligned seqs and many coords
  # The source region start/feature start/feature end are used to calculate the offset of the feature start/end in the aligned source seq
  # Once they are located, then the equivalent positions (if they exist) can be calculated in the target seq
  # After they've been located, we can then calculate the coords of the feature in the target and build it
  # There are various issues here. If the positions are at gaps in the alignment, then what to do? Most straightfoward thing might be to
  # scan and include all aligned bases between the source start/end and fill in with equivalent number of missing bases
  # Maybe look for the closest non-gap position to the coord of the start end that's within the genomic region of the source feature and then
  # calculate the base offset from there and include the equivalent number of missing bases from the target seq
  # Actually the above is probably just overcomplicated, just take all the bases aligned to positions within the feature in the source
  # then when you calculate coverage it will help sort out bad ones versus good ones
  # Also need to do something in terms of if there's a cds, since this is likely to cover IG genes with weird cds features
  # Could decide to drop the UTR in these cases (if there is UTR, since that's very unlikely), then that would make it more
  # straightforward in terms of just making the whole feature coding
#  say "Aligned seqs:";
#  say $aligned_source_seq;
#  say $aligned_target_seq;

  my $source_seq = $aligned_source_seq;
  $source_seq =~ s/\-//g;
  my $target_seq = $aligned_target_seq;
  $target_seq =~ s/\-//g;

  open(OUT,">tmp.seq");
  say OUT ">source\n".$source_seq;
  say OUT ">target\n".$target_seq;
  close OUT;

  my @source_align_array = split('',$aligned_source_seq);
  my @target_align_array = split('',$aligned_target_seq);
  my $source_seq_pos = 0;
  my $source_align_seq_pos = 0;
  my $target_seq_pos = 0;
  my $target_align_seq_pos = 0;

  # Seen to have some issue in terms of getting the real start/end for some features. Was using +1, but seems off
  my $source_feature_seq_start =  $feature_start - $source_region_start;
  my $source_feature_seq_end = $feature_end - $source_region_start;
  say "Source feature seq start: ".$source_feature_seq_start;
  say "Source feature seq end: ".$source_feature_seq_end;
  say "Source region start: ".$source_region_start;
  say "Feature start: ".$feature_start;
  say "Feature end: ".$feature_end;

  my $source_seq_start_index;
  my $source_seq_end_index;
  my $target_seq_start_index;
  my $target_seq_end_index;
  my $in_feature_alignment = 0;
  my $out_of_feature_alignment = 0;
  for(my $i=0; $i < scalar(@source_align_array); $i++) {
    my $source_value = $source_align_array[$i];
    my $target_value = $target_align_array[$i];
    if($source_value ne '-') {
      $source_seq_pos++;
    }

    if($target_value ne '-') {
      $target_seq_pos++;
    }

    if($source_seq_pos == $source_feature_seq_start) {
      $source_seq_start_index = $source_seq_pos;
      say "Index of the feature start in source seq: ".$source_seq_start_index;
      $in_feature_alignment = 1;
    }

    if($in_feature_alignment and $target_value ne '-' and !(defined($target_seq_start_index))) {
      $target_seq_start_index = $target_seq_pos;
    }

    if($source_seq_pos == $source_feature_seq_end) {
      $source_seq_end_index = $source_seq_pos;
      $target_seq_end_index = $target_seq_pos;
      say "Index of the feature end in source seq: ".$source_seq_end_index;
      $in_feature_alignment = 0;
    }
  }

  my $source_feature_length = $source_seq_end_index - $source_seq_start_index + 1;
  my $target_feature_length = $target_seq_end_index - $target_seq_start_index + 1;
  my $recovered_source_feature_seq = substr($source_seq,$source_seq_start_index,$source_feature_length);
  if($exon->strand != 1) {
    $recovered_source_feature_seq = $self->revcomp($recovered_source_feature_seq);
  }

  unless(defined($target_seq_start_index) and defined($target_seq_end_index)) {
    $self->warning("Issue with recovering start/end of the exon feature in target alignment sequence, not building exon");
    return;
  }

  my $recovered_target_feature_seq = substr($target_seq,$target_seq_start_index,$target_feature_length);
  if($target_strand != $exon->strand()) {
    $recovered_target_feature_seq = $self->revcomp($recovered_target_feature_seq);
  }

  say "Source seq start index/end index/length: ".$source_seq_start_index.":".$source_seq_end_index.":".$source_feature_length;
  say "Target seq start index/end index/length: ".$target_seq_start_index.":".$target_seq_end_index.":".$target_feature_length;
  say "Recovered feature source seq:";
  say $recovered_source_feature_seq;
  say "Recovered feature target seq:";
  say $recovered_target_feature_seq;

  my $projected_exon = $self->build_projected_exon($transcript,$exon,$target_seq_start_index,$target_seq_end_index,$target_region_slice,$target_strand);
  return($projected_exon);
}


sub build_projected_exon {
  my ($self,$transcript,$exon,$seq_start_index,$seq_end_index,$region_slice,$target_strand) = @_;

  say "Region slice: ".$region_slice->name();
  my $region_start = $region_slice->seq_region_start();
  my $region_end = $region_slice->seq_region_end();
  say "Region start: ".$region_start;
  say "Region end: ".$region_end;

  my $parent_slice = $region_slice->seq_region_Slice();
  my $exon_start;
  my $exon_end;
  my $exon_strand = 1;
  say "Start/End index: ".$seq_start_index."/".$seq_end_index;
  if($target_strand == 1) {
    $exon_start = $region_start + $seq_start_index;
    $exon_end = $region_start + $seq_end_index;
    $exon_strand = $exon->strand();
  } else {
    # In this case we need to reverse the coords
    $exon_end = $region_end - $seq_start_index;
    $exon_start = $exon_end - ($seq_end_index - $seq_start_index);
    if($exon->strand() == 1) {
       $exon_strand = -1;
    } else {
      $exon_strand = 1;
    }
  }

  my $phase = -1;
  my $end_phase = -1;

  say "Projected exon start/end slice coords: ".$exon_start."/".$exon_end;
  say "Parent slice stard/end genomic coords: ".$parent_slice->seq_region_start."/".$parent_slice->seq_region_end;
  my $projected_exon = Bio::EnsEMBL::Exon->new(-start     => $exon_start,
                                               -end       => $exon_end,
                                               -strand    => $exon_strand,
                                               -phase     => $phase,
                                               -end_phase => $end_phase,
                                               -analysis  => $self->analysis,
                                               -slice     => $parent_slice);

  if($transcript and $exon->is_coding($transcript)) {
    $projected_exon->phase($exon->phase());
    $projected_exon->end_phase($exon->end_phase());
  }

  if($exon_start > $exon_end) {
    $self->throw("Created an exon where the start > than the end, this shouldn't be possible: ".$parent_slice->name." ".$exon->start."..".$exon->end." ".$target_strand);
  }

  say "New exon seq:";
  say $projected_exon->seq->seq();
  say "Original exon seq:";
  say $exon->seq->seq();

  return($projected_exon);
}

sub build_projected_exon_orig {
  my ($self,$transcript,$exon,$seq_start_index,$seq_end_index,$region_slice,$target_strand) = @_;

  say "Region slice: ".$region_slice->name();
  my $region_start = $region_slice->seq_region_start();
  my $region_end = $region_slice->seq_region_end();
  say "Region start: ".$region_start;
  say "Region end: ".$region_end;

  my $parent_slice = $region_slice->seq_region_Slice();
#  say "Parent slice: ".$parent_slice->name();

  my $exon_start;
  my $exon_end;
  my $exon_strand = 1;
  say "Start/End index: ".$seq_start_index."/".$seq_end_index;
  if($target_strand == $exon->strand) {
    $exon_start = $region_start + $seq_start_index;
    $exon_end = $region_start + $seq_end_index;
    $exon_strand = $target_strand;
  } else {
    # In this case we need to reverse the coords
    $exon_end = $region_end - $seq_start_index;
    $exon_start = $exon_end - ($seq_end_index - $seq_start_index);
  }


  my $phase = -1;
  my $end_phase = -1;

  say "Projected exon start/end slice coords: ".$exon_start."/".$exon_end;
  say "Parent slice stard/end genomic coords: ".$parent_slice->seq_region_start."/".$parent_slice->seq_region_end;
  my $projected_exon = Bio::EnsEMBL::Exon->new(-start     => $exon_start,
                                               -end       => $exon_end,
                                               -strand    => $target_strand,
                                               -phase     => $phase,
                                               -end_phase => $end_phase,
                                               -analysis  => $self->analysis,
                                               -slice     => $parent_slice);

  if($transcript and $exon->is_coding($transcript)) {
    $projected_exon->phase($exon->phase());
    $projected_exon->end_phase($exon->end_phase());
  }

  if($exon_start > $exon_end) {
    $self->throw("Created an exon where the start > than the end, this shouldn't be possible: ".$parent_slice->name." ".$exon->start."..".$exon->end." ".$target_strand);
  }

  say "New exon seq:";
  say $projected_exon->seq->seq();
  say "Original exon seq:";
  say $exon->seq->seq();

  return($projected_exon);
}


sub set_complete_transcript_cds {
  my ($self,$transcript) = @_;

  # This will take a transcript and assume it is a completely coding sequence, so will just apply a translation across the whole thing
  # This is mostly to just replicate the cds for the small, coding, single exon genes that are projected at the moment
  my $exons = $transcript->get_all_Exons();
  my $start_exon = ${$exons}[0];
  my $end_exon = ${$exons}[scalar(@$exons)-1];
  my $translation = Bio::EnsEMBL::Translation->new();
  $translation->start_Exon($start_exon);
  $translation->start(1);
  $translation->end_Exon($end_exon);
  $translation->end($end_exon->length());
  $transcript->translation($translation);
}


sub generate_minimap_transcripts {
  my ($self,$source_transcript_fasta_seqs,$target_genome_index,$target_adaptor,$target_genomic_start,$max_intron_size) = @_;

  # This will take in the target genomic region (via the index)
  my $coverage_cutoff = 80;
  my $perc_id_cutoff = 80;
  my $max_stops = 999;
  my $minimap_transcripts = [];
  my $analysis = $self->analysis();
  my $program = $self->program();
  my $paftools = $self->paftools_path();
  my $source_input_file = $self->write_input_file($source_transcript_fasta_seqs);
  my $runnable = Bio::EnsEMBL::Analysis::Runnable::Minimap2->new(
       -analysis                 => $analysis,
       -program                  => $program,
       -paftools_path            => $paftools,
       -genome_index             => $target_genome_index,
       -input_file               => $source_input_file,
       -database_adaptor         => $target_adaptor,
       -skip_introns_check       => 1,
       -add_offset               => $target_genomic_start - 1,
       -skip_compute_translation => 1,
       -max_intron_size          => $max_intron_size,
       -perc_id                  => $perc_id_cutoff,
       -coverage                 => $coverage_cutoff,
  );

  $runnable->run();

  my $output_genes = $runnable->output();
  foreach my $gene (@$output_genes) {
    my $transcripts = $gene->get_all_Transcripts();
    foreach my $transcript (@$transcripts) {
      $transcript->{'annotation_method'} = 'minimap_local';
      push(@$minimap_transcripts,$transcript);
    }
  }

  return($minimap_transcripts);
}


sub generate_exonerate_transcripts {
  my ($self,$transcripts_to_map,$source_transcript_id_hash,$target_region_slice,$target_slice_adaptor,$max_intron_size) = @_;

  my $output_transcripts = [];

  foreach my $transcript_to_map (@$transcripts_to_map) {
    my $source_transcript = $source_transcript_id_hash->{$transcript_to_map->dbID()};
    unless($source_transcript) {
      $self->throw("Couldn't find the dbID of the transcript in the source transcript hash when attempting to run exonerate");
    }

    my $exonerate_transcripts = $self->run_exonerate($source_transcript,$target_region_slice,$target_slice_adaptor,$max_intron_size);
    say "Got ".scalar(@$exonerate_transcripts)." from Exonerate";
    foreach my $transcript (@$exonerate_transcripts) {

      my ($mapped_coverage,$mapped_percent_id,$aligned_source_seq,$aligned_target_seq) = align_nucleotide_seqs($source_transcript->seq->seq(),$transcript->seq->seq());
      $transcript->{'cov'} = $mapped_coverage;
      $transcript->{'perc_id'} = $mapped_percent_id;
      $transcript->{'aligned_source_seq'} = $aligned_source_seq;
      $transcript->{'aligned_target_seq'} = $aligned_target_seq;
      $transcript->{'annotation_method'} = 'exonerate_local';
      say "Mapped transcript (".$source_transcript->stable_id()."): Coverage: ".$transcript->{'cov'}.", Percent id: ".$transcript->{'perc_id'};
      push(@$output_transcripts,$transcript);
    }
  }
  return($output_transcripts);
}


sub run_exonerate {
  my ($self,$source_transcript,$target_region_slice,$target_slice_adaptor,$max_intron_size) = @_;

  my $output_transcripts = [];
  my $exonerate_length_cutoff = 15000;
  my $max_stops = 999;
  if($source_transcript->length() > $exonerate_length_cutoff) {
    say "Not running exonerate on trascript ".$source_transcript->stable_id()." as length (".$source_transcript->length().") is greater than length cut-off (".$exonerate_length_cutoff.")";
    return($output_transcripts);
  }

  say "Running Exonerate on ".$source_transcript->stable_id();
  my $annotation_features;
  my $non_coding_transcript = 0;
  if($source_transcript->translation()) {
    $annotation_features = $self->create_annotation_features($source_transcript);
  } else {
    $non_coding_transcript = 1;
  }

  my $source_transcript_header = $source_transcript->stable_id.'.'.$source_transcript->version;
  my $source_transcript_seq_object = Bio::Seq->new(-display_id => $source_transcript_header, -seq => $source_transcript->seq->seq());


  my %parameters = ();
  $parameters{-options} = "--model cdna2genome --forwardcoordinates FALSE --softmasktarget TRUE --exhaustive FALSE --score 500 ".
                          "--saturatethreshold 100 --dnawordlen 15 --codonwordlen 15 --dnahspthreshold 60 --bestn 1 --maxintron ".$max_intron_size;
  $parameters{-coverage_by_aligned} = 1;

  my $runnable = Bio::EnsEMBL::Analysis::Runnable::ExonerateTranscript->new(
                    -program  => '/hps/software/users/ensembl/ensw/C8-MAR21-sandybridge/linuxbrew/opt/exonerate22/bin/exonerate',
                    -analysis => $self->analysis(),
                    -query_type     => "dna",
                    -calculate_coverage_and_pid => 1,
                    -annotation_features => $annotation_features,
                    -non_coding_transcript => $non_coding_transcript,
                     %parameters,
                 );

  $runnable->target_seqs([$target_region_slice]);
  $runnable->query_seqs([$source_transcript_seq_object]);
  $runnable->run();
  if (scalar(@{$runnable->output()})) {
    my $initial_output_transcript = ${$runnable->output()}[0];
    my $output_transcript = $self->update_exonerate_transcript_coords($initial_output_transcript,$target_slice_adaptor);
    if ($source_transcript->translation() and $output_transcript->translation()) {
      $self->check_exonerate_translation($source_transcript,$output_transcript);
    }

    $output_transcript->stable_id($source_transcript->dbID());
    push(@$output_transcripts,$output_transcript);
  }

  return($output_transcripts);
}


sub check_exonerate_translation {
  my ($self,$source_transcript,$output_transcript) = @_;

  my $source_se = $source_transcript->translation->start_Exon();
  my $source_ee = $source_transcript->translation->end_Exon();

  my $output_se = $output_transcript->translation->start_Exon();
  my $output_ee = $output_transcript->translation->end_Exon();

  # This will sort an incomplete start codon out. Exonerate will always make a CDS that's a multiple
  # of three even if the annotation features is not a multiple of three. So this code will cut the
  # equivalent amount off the end of the CDS. Note that at the moment there's no code to deal with
  # edge cases like if this moved the cds into another exon (start would be < 1)
  if($source_se->phase()) {
    my $translation = $output_transcript->translation();
    $output_se->phase($source_se->phase());
    my $end_offset = $translation->end() - $source_se->phase();
    $translation->end($end_offset);
    $output_transcript->translation($translation);
  }

  # Need some code to sort out the situation where the cds end is wrong because exonerate won't make a
  # complete cds. This can happen if the end codon of the original cds is not complete. Exonerate will
  # just truncate it to the closest codon
  my $translation_offset = length($output_transcript->translateable_seq()) % 3;
  if($translation_offset) {
    my $translation = $output_transcript->translation();
    my $end_offset = $translation->end() - $translation_offset;
    $translation->end($end_offset);
    $output_transcript->translation($translation)
  }
}

sub update_exonerate_transcript_coords {
  my ($self,$transcript,$target_slice_adaptor) = @_;

  $transcript->flush_supporting_features();
  my $slice_id = $transcript->start_Exon->seqname;

  $slice_id =~ /[^\:]+\:[^\:]+\:([^\:]+)\:([^\:]+)\:([^\:]+)\:[^\:]+$/;
  my $region_name = $1;
  my $start_offset = $2 - 1;
  my $slice = $target_slice_adaptor->fetch_by_region('toplevel',$region_name);

  my $exons = $transcript->get_all_Exons();
  foreach my $exon (@$exons) {
    $exon->start($exon->start() + $start_offset);
    $exon->end($exon->end() + $start_offset);
  }

  $transcript->start($transcript->start() + $start_offset);
  $transcript->end($transcript->end() + $start_offset);
  attach_Slice_to_Transcript($transcript,$slice);
  attach_Analysis_to_Transcript($transcript,$self->analysis());

  return($transcript);
}


sub check_mapping_quality {
  my ($self,$target_transcripts,$source_transcript_id_hash,$good_transcripts) = @_;
  my $bad_transcripts = [];
  my $coverage_cutoff_groups = {'coding' => 95,
                                'pseudogene' => 80,
                                'snoncoding' => 90,
                                'mnoncoding' => 80,
                                'lnoncoding' => 80,
                                'undefined'  => 50};

  my $percent_identity_groups = {'coding' => 95,
                                 'pseudogene' => 80,
                                 'snoncoding' => 80,
                                 'mnoncoding' => 80,
                                 'lnoncoding' => 80,
                                 'undefined'  => 50};

  my $cds_length_diff_cutoff = 0.05;
  my $genomic_span_diff_cutoff = 0.80;
  my $exonerate_length_cutoff = 15000;

  my $processed_transcripts = {};

  foreach my $transcript (@$target_transcripts) {
    say "Checking mapping quality for mapped transcript with original dbID: ".$transcript->stable_id();
    my $source_transcript = $source_transcript_id_hash->{$transcript->stable_id()};
    unless($source_transcript) {
      $self->throw("Issue with fetching source transcript for target transcript with dbID: ".$transcript->stable_id());
    }

    my $source_genomic_span = $source_transcript->seq_region_end() - $source_transcript->seq_region_start() + 1;
    my $target_genomic_span = $transcript->seq_region_end() - $transcript->seq_region_start() + 1;
    my $source_transcript_seq;
    my $transcript_seq;
    my $cds_length_diff = 0;

    # Set the description now on the minor chance the transcript doesn't have a cds that can be calculated
    my $transcript_description = "Parent: ".$source_transcript->stable_id().".".$source_transcript->version();
    $transcript->description($transcript_description);
    if($source_transcript->translation()) {
      $source_transcript_seq = $source_transcript->translateable_seq();
      $transcript_seq = $transcript->translateable_seq();

      unless($transcript_seq) {
        compute_best_translation($transcript);
        $transcript_seq = $transcript->translateable_seq();
      }

      unless($transcript_seq) {
        $self->warning("Couldn't find an ORF in transcript mapped from ".$source_transcript->stable_id().". Source transcript has an ORF");
        next;
      }

      # This is for cds seqs only, so this is only run if there's a translation. Meaning that cds_length_diff is 0 for all other transcripts, and thus
      # they automatically pass the length check. There isn't really a risk of a non-coding transcript being longer than expected, only shorter than
      # expected (and that's handled by coverage), whereas an ORF could be longer due to selecting an incorrect upstream methionine
      if(length($transcript_seq) > length($source_transcript_seq)) {
        $cds_length_diff = 1 - (length($source_transcript_seq)/length($transcript_seq));
      }
    } else {
      $source_transcript_seq = $source_transcript->seq->seq();
      $transcript_seq = $transcript->seq->seq();
    }

    my ($coverage,$percent_id,$aligned_source_seq,$aligned_target_seq) = align_nucleotide_seqs($source_transcript_seq,$transcript_seq);
    $transcript->{'cov'} = $coverage;
    $transcript->{'perc_id'} = $percent_id;
    $transcript->{'cds_length_diff'} = $cds_length_diff;
    $transcript->{'source_stable_id'} = $source_transcript->stable_id();
    $transcript->{'source_biotype_group'} = $source_transcript->get_Biotype->biotype_group();
    $transcript->{'source_length'} = $source_transcript->length();
    say "FERGAL SOURCE SPAN: ".$source_genomic_span;
    say "FERGAL TARGET SPAN: ".$target_genomic_span;
    my $transcript_genomic_span_diff = $target_genomic_span/$source_genomic_span;
    $transcript_genomic_span_diff = sprintf("%.2f", $transcript_genomic_span_diff);
    $transcript->{'transcript_genomic_span_diff'} = $transcript_genomic_span_diff;

    $transcript_description .= ", Coverage: ".$coverage.", Perc id: ".$percent_id;
    $transcript->description($transcript_description);

    # I added this in because even when minimap is explicitly told not to output secondary alignments, it very occasionally does
    # The example case was ENST00000624628, which is a large lncRNA (24kb) and for some reason it seems to split into one large
    # alignment and one small one and outputs both
    if($processed_transcripts->{$transcript->stable_id()}) {
      if(($transcript->{'cov'} + $transcript->{'perc_id'}) > ($processed_transcripts->{$transcript->stable_id()}->{'cov'} + $processed_transcripts->{$transcript->stable_id()}->{'perc_id'})) {
        say "Found two transcripts for the same dbID. Selecting transcript with highest combined coverage and identity: ".$transcript->{'cov'}." cov, ".$transcript->{'perc_id'}." perc_id";
        $processed_transcripts->{$transcript->stable_id()} = $transcript;
      }
    } else {
      $processed_transcripts->{$transcript->stable_id()} = $transcript;
    }
  }

  foreach my $transcript_id (keys(%{$processed_transcripts})) {
    my $transcript = $processed_transcripts->{$transcript_id};
    my $biotype_group = $transcript->{'source_biotype_group'};
    my $coverage_cutoff = $coverage_cutoff_groups->{$biotype_group};
    my $perc_id_cutoff = $percent_identity_groups->{$biotype_group};

    unless($coverage_cutoff and $perc_id_cutoff) {
      $self->throw("Issue fetching coverage and percent id cutoffs for the biotype group of the parent transcript. Biotype group: ".$biotype_group);
    }

    if($transcript->{'cov'} >= $coverage_cutoff and $transcript->{'perc_id'} >= $perc_id_cutoff and
       $transcript->{'cds_length_diff'} <= $cds_length_diff_cutoff and $transcript->{'transcript_genomic_span_diff'} >= $genomic_span_diff_cutoff) {
      say "Transcript ".$transcript->{'source_stable_id'}." (".$transcript->stable_id().", ".$biotype_group.") passed check: ".$transcript->{'cov'}." cov, ".
          $transcript->{'perc_id'}." perc_id, ".$transcript->{'cds_length_diff'}." length diff, ".$transcript->{'transcript_genomic_span_diff'}." genomic span diff";
      push(@$good_transcripts,$transcript);
    } else {
      say "Transcript ".$transcript->{'source_stable_id'}." (".$transcript->stable_id().", ".$biotype_group.") failed check: ".$transcript->{'cov'}." cov, ".
          $transcript->{'perc_id'}." perc_id, ".$transcript->{'cds_length_diff'}." length diff, ".$transcript->{'transcript_genomic_span_diff'}." genomic span diff";
      push(@$bad_transcripts,$transcript);
    }
  }

  # Add any missing transcripts to the bad pile also


  return($bad_transcripts);
}


sub select_best_transcripts {
  my ($self,$bad_minimap_transcripts_hash,$bad_exonerate_transcripts_hash) = @_;

  # This will take two hashes of transcripts and check the keys, which are dbIDs to see which
  # hash has the highest combined coverage and perc identity in cases where there's a dbID across both
  # There probably shouldn't be dbIDs unique to each, but to make the code more robust it will handle
  # those cases too

  my $processed_ids_hash = {};
  my $selected_transcripts = [];

  foreach my $db_id (keys(%{$bad_minimap_transcripts_hash})) {
    my $minimap_transcript = $bad_minimap_transcripts_hash->{$db_id};
    my $exonerate_transcript = $bad_exonerate_transcripts_hash->{$db_id};

    # If there's no exonerate transcript just move on
    unless($exonerate_transcript) {
      push(@$selected_transcripts,$minimap_transcript);
      next;
    }

    # Just take whatever has the best combined perc id/cov for now
    if(($minimap_transcript->{'cov'} + $minimap_transcript->{'perc_id'}) > ($exonerate_transcript->{'cov'} + $exonerate_transcript->{'perc_id'})) {
      push(@$selected_transcripts,$minimap_transcript);
    } else {
      push(@$selected_transcripts,$exonerate_transcript);
    }

    $processed_ids_hash->{$db_id} = 1;
  }

  # Find and deal with any unique dbIDs in the exonerate hash
  foreach my $db_id (keys(%{$bad_exonerate_transcripts_hash})) {
    if($processed_ids_hash->{$db_id}) {
      next;
    }

    # In this scenario the only possiblity is that the transcript isn't in the minimap hash, so include it in the selected transcripts array
    my $exonerate_transcript = $bad_exonerate_transcripts_hash->{$db_id};
    push(@$selected_transcripts,$exonerate_transcript);
  }

  return($selected_transcripts);
}


sub list_missing_transcripts {
  my ($self,$transcripts_by_id,$source_transcripts) = @_;

  # This just gets the dbIDs from both hashes and then looks at the dbIDs of the source transcripts to see any ones that are not present
  my $missing_transcripts = [];

  my $db_id_hash = {};
  foreach my $db_id (keys(%{$transcripts_by_id})) {
    $db_id_hash->{$db_id} = 1;
  }

  foreach my $source_transcript (@$source_transcripts) {
    my $db_id = $source_transcript->dbID();
    unless($db_id_hash->{$db_id}) {
      say "Add source transcript ".$source_transcript->stable_id()." to missing transcripts list";
      push(@$missing_transcripts,$source_transcript);
    }
  }
  return($missing_transcripts);
}


sub label_transcript_status {
  my ($self,$transcripts_by_id,$status) = @_;

  my $coverage_threshold = 95;
  my $percent_id_threshold = 95;
  my $labelled_transcripts = [];
  # This labels a set of transcripts to help with deciding what to do when examining clusters
  foreach my $id (keys(%{$transcripts_by_id})) {
    my $transcript = $transcripts_by_id->{$id};
    my $transcript_coverage = $transcript->{'cov'};
    my $transcript_perc_id = $transcript->{'perc_id'};
    if ($transcript_coverage >= $coverage_threshold and $transcript_perc_id >= $percent_id_threshold) {
      $transcript->{'status'} = 'good';
    } else {
      $transcript->{'status'} = 'bad';
    }
    push(@$labelled_transcripts,$transcript);
  }

  return($labelled_transcripts);
}


sub generate_biotypes_hash {
  my ($self,$transcripts) = @_;

  my $unique_biotypes;
  my $biotypes_array = [];
  my $biotypes_hash = {};
  # This labels a set of transcripts to help with deciding what to do when examining clusters
  foreach my $transcript (@$transcripts) {
    unless($unique_biotypes->{$transcript->biotype()}) {
      push(@$biotypes_array,$transcript->biotype());
      $unique_biotypes->{$transcript->biotype()} = 1;
    }
  }

  $biotypes_hash->{'genes'} = $biotypes_array;
  return($biotypes_hash);
}


sub generate_single_transcript_genes {
  my ($self,$transcripts) = @_;

  my $single_transcript_genes = [];
  foreach my $transcript (@$transcripts) {
    my $gene = Bio::EnsEMBL::Gene->new(-analysis => $self->analysis);
    $gene->add_Transcript($transcript);
    $gene->biotype($transcript->biotype());
    $gene->stable_id($transcript->stable_id());
    $gene->{'status'} = $transcript->{'status'};
    $gene->{'cov'} = $transcript->{'cov'};
    $gene->{'perc_id'} = $transcript->{'perc_id'};
    $gene->slice($transcript->slice());
    push(@$single_transcript_genes,$gene);
  }

  return($single_transcript_genes);
}


sub check_cluster_status {
  my ($self,$cluster) = @_;

  my $genes = $cluster->get_Genes();
  $cluster->{'status'} = 'bad';
  foreach my $gene (@$genes) {
    if($gene->{'status'} eq 'good') {
      $cluster->{'status'} = 'good';
    }
  }
}


sub create_gene_from_cluster {
  my ($self,$cluster,$parent_gene_ids,$source_transcript_id_hash) = @_;

  my $cluster_genes = $cluster->get_Genes();
  my $processed_transcript_ids = {};
  my $selected_transcripts = {};

  # Loop through the transcripts, if there's any transcript that occurs twice, pick the one with the best combined coverage and percent id
  foreach my $cluster_gene (@$cluster_genes) {
    my $transcripts = $cluster_gene->get_all_Transcripts();
    my $transcript = ${$transcripts}[0];
    if($selected_transcripts->{$transcript->stable_id()}) {
      my $current_selected_transcript = $selected_transcripts->{$transcript->stable_id()};
      if(($transcript->{'cov'} + $transcript->{'perc_id'}) > ($current_selected_transcript->{'cov'} + $current_selected_transcript->{'perc_id'})) {
        $selected_transcripts->{$transcript->stable_id()} = $transcript;
      }
    } else {
      $selected_transcripts->{$transcript->stable_id()} = $transcript;
    }
  } # End foreach my $cluster_gene

  my $final_transcripts = [];
  foreach my $transcript_id (keys(%{$selected_transcripts})) {
    my $transcript = $selected_transcripts->{$transcript_id};
    push(@$final_transcripts,$transcript);
  }

  my $gene = Bio::EnsEMBL::Gene->new(-analysis => $self->analysis);
  my $transcript_id = ${$final_transcripts}[0]->stable_id();
  my $parent_gene_id = $parent_gene_ids->{$transcript_id}->{'gene_id'};
  my $parent_gene_stable_id = $parent_gene_ids->{$transcript_id}->{'gene_stable_id'};
  my $parent_gene_version = $parent_gene_ids->{$transcript_id}->{'gene_version'};
  my $parent_gene_biotype = $parent_gene_ids->{$transcript_id}->{'gene_biotype'};

  foreach my $transcript (@$final_transcripts) {
    my $source_transcript = $source_transcript_id_hash->{$transcript->stable_id()};
    unless($source_transcript) {
      $self->throw("Issue with finding source transcript. The following dbID was not found in the source transcript id hash: ".$transcript->stable_id());
    }

    my $parent_transcript_stable_id = $parent_gene_ids->{$transcript->stable_id()}->{'transcript_stable_id'};
    my $parent_transcript_version = $parent_gene_ids->{$transcript->stable_id()}->{'transcript_version'};
    my $parent_gene_id = $parent_gene_ids->{$transcript->stable_id()}->{'gene_id'};
    my $is_canonical = $parent_gene_ids->{$transcript->stable_id()}->{'is_canonical'};
    my $source = $parent_gene_ids->{$transcript->stable_id()}->{'source'};

    $transcript->biotype($source_transcript->biotype());
    $transcript->stable_id($parent_transcript_stable_id);
    $transcript->version($parent_transcript_version);

    if($is_canonical) {
      $transcript->is_canonical(1);
    }


    $transcript->source($source);
#    my $cov_string = "cov: ".$transcript->{'cov'}." perc_id: ".$transcript->{'perc_id'};
#    $transcript->description($cov_string);
    $gene->add_Transcript($transcript);
  }

  $gene->{'parent_gene_id'} = $parent_gene_id;
  $gene->stable_id($parent_gene_stable_id);
  $gene->version($parent_gene_version);
  $gene->biotype($parent_gene_biotype);
  my $gene_description = "Parent: ".$parent_gene_stable_id.".".$parent_gene_version.", Type: Primary mapping";
  $gene->description($gene_description);

  return($gene);
}


sub access_transcripts_for_recovery {
  my ($self,$bad_transcripts,$source_transcript_id_hash,$good_transcripts,$target_parent_slice,$target_slice_adaptor,$target_sequence_adaptor,$target_genomic_name) = @_;

  # This will look at the bad transcripts and decide if there are any good transcripts from the same gene
  # If there are it will determine whether the bad transcript is contained within the boundaries covered
  # by the good transcript in the origninal source gene. If it is then the implication is that the region
  # if likely correct and there's just some fundamental issue with the transcript, so nothing can be done
  # If the transcript only partially overlapped with the good transcripts in the source gene, there's the
  # possibility that the target region was truncated and thus the transcript could only partially align to
  # it. If this is the case, then we want to attempt to create a new extended target region and try again

  my ($good_transcripts_start,$good_transcripts_end) = $self->get_transcript_boundaries($good_transcripts,$source_transcript_id_hash);
  my ($bad_transcripts_start,$bad_transcripts_end) = $self->get_transcript_boundaries($bad_transcripts,$source_transcript_id_hash);

  # Check if the bad transcript boundaries lie outside the good transcript boundaries in the source gene
  my $start_offset = 0;
  my $end_offset = 0;
  my $offset_buffer = 1000;
  if($bad_transcripts_start < $good_transcripts_start) {
    $start_offset = $good_transcripts_start - $bad_transcripts_start;
  }

  if($bad_transcripts_end > $good_transcripts_end) {
    $end_offset = $bad_transcripts_end - $good_transcripts_end;
  }

  my $target_transcripts_start;
  my $target_transcripts_end;
  foreach my $good_transcript (@$good_transcripts) {
    if(!$target_transcripts_start or $good_transcript->seq_region_start() < $target_transcripts_start) {
      $target_transcripts_start = $good_transcript->seq_region_start();
    }

    if(!$target_transcripts_end or $good_transcript->seq_region_end() > $target_transcripts_end) {
      $target_transcripts_end = $good_transcript->seq_region_end();
    }
  } # End foreach my $good_transcript

  $target_transcripts_start -= $start_offset - $offset_buffer;
  $target_transcripts_end += $end_offset + $offset_buffer;
  if($target_transcripts_start < 1) {
    $target_transcripts_start = 1;
  }


  my $target_strand = 1;
  my $target_genomic_seq = ${ $target_sequence_adaptor->fetch_by_Slice_start_end_strand($target_parent_slice, $target_transcripts_start, $target_transcripts_end, $target_strand) };
  my $target_region_slice = $target_slice_adaptor->fetch_by_region('toplevel', $target_genomic_name, $target_transcripts_start, $target_transcripts_end, $target_strand);
  my $target_genomic_fasta = ">".$target_genomic_name."\n".$target_genomic_seq;
  my $target_genome_file = $self->write_input_file([$target_genomic_fasta]);
  my $target_genome_index = $target_genome_file.".mmi";
  my $target_index_command = $self->program()." -d ".$target_genome_index." ".$target_genome_file;
  my $index_result = system($target_index_command);
  if($index_result) {
    $self->throw('The minimap2 index command returned a non-zero exit code. Commandline used:\n'.$target_index_command);
  }
}


sub calculate_max_intron_size {
  my ($self,$transcripts) = @_;

  my $scaling_factor = 1.5;
  my $max_intron_size = 100000;
  foreach my $transcript (@$transcripts) {
    my $introns = $transcript->get_all_Introns();
    foreach my $intron (@$introns) {
      my $scaled_intron_length = $scaling_factor * $intron->length();
      if($scaled_intron_length > $max_intron_size) {
        $max_intron_size = $scaled_intron_length;
      }
    }
  }

  return($max_intron_size);
}


sub get_transcript_boundaries {
  my ($self,$transcripts,$source_transcript_id_hash) = @_;

  my $transcripts_start;
  my $transcripts_end;

  foreach my $transcript (@$transcripts) {
    my $source_transcript = $source_transcript_id_hash->{$transcript->stable_id()};
    if(!$transcripts_start or $source_transcript->seq_region_start() < $transcripts_start) {
      $transcripts_start = $source_transcript->seq_region_start();
    }

    if(!$transcripts_end or $source_transcript->seq_region_end() > $transcripts_end) {
      $transcripts_end = $source_transcript->seq_region_end();
    }
  } # End foreach my $good_transcript

  return($transcripts_start,$transcripts_end);
}


sub create_annotation_features {
  my ($self,$transcript) = @_;

  my $cds_start  = $transcript->cdna_coding_start;
  my $cds_end    = $transcript->cdna_coding_end;
  my $stable_id  = $transcript->stable_id.".".$transcript->version;


  my $start_phase = $transcript->translation->start_Exon->phase();
  my $end_phase = $transcript->translation->end_Exon->end_phase();

  my $annotation_feature = Bio::EnsEMBL::Feature->new(-seqname => $stable_id,
                                                      -strand  => 1,
                                                      -start   => $cds_start,
                                                      -end     => $cds_end);

 my $annotation_features->{$stable_id} = $annotation_feature;
 return($annotation_features);
}


sub create_filename{
  my ($self, $stem, $ext, $dir, $no_clean) = @_;
  return create_file_name($stem, $ext, $dir, $no_clean);
}



sub genome_index {
  my ($self, $val) = @_;

  if ($val) {
    $self->{_genome_index} = $val;
  }

  return $self->{_genome_index};
}


sub genes_to_process {
  my ($self, $val) = @_;

  if ($val) {
    $self->{_genes_to_process} = $val;
  }

  return $self->{_genes_to_process};
}


sub input_file {
  my ($self, $val) = @_;

  if ($val) {
    $self->{_input_file} = $val;
  }

  return $self->{_input_file};
}


sub paftools_path {
  my ($self, $val) = @_;

  if ($val) {
    $self->{_paftools_path} = $val;
  }

  return $self->{_paftools_path};
}


sub source_adaptor {
  my ($self, $val) = @_;

  if (defined $val) {
    throw(ref($val).' is not a Bio::EnsEMBL::DBSQL::DBAdaptor')
      unless ($val->isa('Bio::EnsEMBL::DBSQL::DBAdaptor'));
    $self->{_source_adaptor} = $val;
  }

  return $self->{_source_adaptor};
}


sub target_adaptor {
  my ($self, $val) = @_;

  if (defined $val) {
    throw(ref($val).' is not a Bio::EnsEMBL::DBSQL::DBAdaptor')
      unless ($val->isa('Bio::EnsEMBL::DBSQL::DBAdaptor'));
    $self->{_target_adaptor} = $val;
  }

  return $self->{_target_adaptor};
}


sub delete_input_file {
  my ($self, $val) = @_;

  if ($val) {
    $self->{_delete_input_file} = $val;
  }

  return $self->{_delete_input_file};
}


sub parent_gene_ids {
  my ($self, $val) = @_;

  if ($val) {
    $self->{_parent_gene_ids} = $val;
  }

  return $self->{_parent_gene_ids};
}


sub gene_synteny_hash {
  my ($self, $val) = @_;

  if ($val) {
    $self->{_gene_synteny_hash} = $val;
  }

  return $self->{_gene_synteny_hash};
}


sub gene_genomic_seqs_hash {
  my ($self, $val) = @_;

  if ($val) {
    $self->{_gene_genomic_seqs_hash} = $val;
  }

  return $self->{_gene_genomic_seqs_hash};
}


sub no_projection {
  my ($self, $val) = @_;

  if ($val) {
    $self->{_no_projection} = $val;
  }

  return $self->{_no_projection};
}


=head2 exon_rank
  Arg [1]    : Bio::EnsEMBL::Exon to get the rank from
  Arg [2]    : Bio::EnsEMBL::Transcript where the exon in Arg [1] is found
  Description: It searches for the Arg [1] exon in the Arg [2] transcript exon array by using the exon coordinates.
               Note it is assumed that a transcript cannot have overlapping exons nor exons having the same coordinates.
  Returntype : int
               It returns the index (1 <= index <= number_of_exons) of the Arg [1] exon in the Arg [2] transcript exon array.
  Exceptions : It throws if the Arg [1] exon cannot be found in the Arg [2] transcript.
=cut

sub exon_rank {
  my ($self,$exon,$transcript) = @_;

  my $rank = 0;
  foreach my $t_exon (@{$transcript->get_all_Exons()}) {
    $rank++;
    if ($t_exon->seq_region_start() == $exon->seq_region_start() and
        $t_exon->seq_region_end() == $exon->seq_region_end() and
        $t_exon->seq_region_strand() == $exon->seq_region_strand()) {
      last;
    }
  }

  if ($rank) {
    return $rank;
  } else {
    $self->throw("Exon(seq_region_start,seq_region_end,seq_region_strand) ".$exon->seq_region_start()." ".$exon->seq_region_end()." ".$exon->seq_region_strand()." does not belong to transcript(seq_region_start,seq_region_end,seq_region_strand) ".$transcript->seq_region_start()." ".$transcript->seq_region_end()." ".$transcript->seq_region_strand());
  }
}

=head2 check_and_fix_translation_boundaries
  Arg [1]    : Bio::EnsEMBL::Transcript whose translation needs to be fixed
  Description: Fix the end of the translation if it's set to be beyond the end of the end exon
               or if it's set to be before the start of the end exon.
  Returntype : N/A
  Exceptions : N/A
=cut

sub check_and_fix_translation_boundaries {
  my ($self,$transcript) = @_;

  my $translation = $transcript->translation();
  my $end_exon = $translation->end_Exon(); # 'end_exon_id' exon in 'translation' table
  my $end_exon_length = $end_exon->length();

  if ($translation->end() > $end_exon_length) {
    print STDERR "Fixing the end of the translation (seq_start,seq_end,start_Exon->seq_region_start,end_Exon->seq_region_end) - (".$translation->start().",".$translation->end().",".$translation->start_Exon()->seq_region_start().",".$translation->end_Exon()->seq_region_end()." from ".$translation->end()." to ".$end_exon_length." because it is beyond the end of the end exon. Setting it to the maximum length of the end exon.\n";
    $translation->end($end_exon_length);
    $transcript->translation($translation);
  }

  $translation = $transcript->translation();
  my $end_exon_rank = $self->exon_rank($end_exon,$transcript);
  if ($translation->end() <= 0) {
    print STDERR "Transcript(seq_region_start,seq_region_end) ".$transcript->seq_region_start().",".$transcript->seq_region_end()." has translation end <= 0, number of exons = ".scalar(@{$transcript->get_all_Exons()}."\n"),
    print STDERR "Fixing the end of the translation (seq_start,seq_end,start_Exon->seq_region_start,end_Exon->seq_region_end) - (".$translation->start().",".$translation->end().",".$translation->start_Exon()->seq_region_start().",".$translation->end_Exon()->seq_region_end()." because it is set to 0. Set it to the end of the previous exon. End exon rank = ".$end_exon_rank."\n";
    foreach my $exon (@{$transcript->get_all_Exons()}) {
      my $exon_rank = $self->exon_rank($exon,$transcript);
      print STDERR "Translation end <= 0, foreach my exon (seq_region_start,seq_region_end,seq_region_strand,rank): ".$exon->seq_region_start().",".$exon->seq_region_end().",".$exon->seq_region_strand().",".$exon_rank."\n";
      if ($exon_rank == $end_exon_rank-1) {
        print STDERR "end_exon_rank-1 found.\n";
        $translation->end_Exon($exon);
        $translation->end($exon->length());
        print STDERR "End of the previous exon is ".$exon->length()."\n";
        $transcript->translation($translation);
        last;
      }
    }
  }
}

sub revcomp {
  my ($self,$seq) = @_;
  my $revcomp = reverse $seq;
  $revcomp =~ tr/ATGCatgc/TACGtacg/;
  return($revcomp);
}

1;
