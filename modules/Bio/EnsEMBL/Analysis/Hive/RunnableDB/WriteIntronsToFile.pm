=head1 LICENSE

 Copyright [2019] EMBL-European Bioinformatics Institute

 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at

      http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.

=head1 NAME

Bio::EnsEMBL::Analysis::Hive::RunnableDB::WriteIntronsToFile

=head1 SYNOPSIS

my $runnableDB =  Bio::EnsEMBL::Analysis::Hive::RunnableDB::WriteIntronsToFile->new( );

$runnableDB->fetch_input();
$runnableDB->run();

=head1 DESCRIPTION

This module dumps intron data from Ensembl dbs to file

=head1 CONTACT

 Please email comments or questions to the public Ensembl
 developers list at <http://lists.ensembl.org/mailman/listinfo/dev>.

 Questions may also be sent to the Ensembl help desk at
 <http://www.ensembl.org/Help/Contact>.

=head1 APPENDIX

=cut

package Bio::EnsEMBL::Analysis::Hive::RunnableDB::WriteIntronsToFile;

use warnings;
use strict;
use feature 'say';

use Bio::EnsEMBL::Analysis::Tools::Utilities qw(create_file_name is_canonical_splice);
use Bio::EnsEMBL::Variation::Utils::FastaSequence qw(setup_fasta);

use parent ('Bio::EnsEMBL::Analysis::Hive::RunnableDB::HiveBaseRunnableDB');

sub param_defaults {
  my ($self) = @_;

  return {
    %{$self->SUPER::param_defaults},
    _branch_to_flow_to => 1,
    small_intron_size  => 75,
    use_generic_output_type => 0,
    generic_output_type => 'intron',
  }
}

=head2 fetch_input

 Arg [1]    : None
 Description: Fetch parameters for intron dumping
 Returntype : None

=cut

sub fetch_input {
  my ($self) = @_;

  say "Fetching input";
  # For the combine files option we don't actually need to do anything in fetch input
  unless($self->param_required('dump_type') eq 'combine_files') {
    my $target_dba = $self->hrdb_get_dba($self->param('target_db'));

    if($self->param_required('dump_type') eq 'gene') {
      my $dna_dba;
      if($self->param('use_genome_flatfile')) {
        unless($self->param_required('genome_file') && -e $self->param('genome_file')) {
          $self->throw("You selected to use a flatfile to fetch the genome seq, but did not find the flatfile. Path provided:\n".$self->param('genome_file'));
        }
        setup_fasta(
                     -FASTA => $self->param_required('genome_file'),
                   );
      } else {
        $dna_dba = $self->hrdb_get_dba($self->param('dna_db'));
        $target_dba->dnadb($dna_dba);
      }

      # If we are dumping introns from genes the get the genes
      my $gene_adaptor = $target_dba->get_GeneAdaptor();
      my $gene_ids = $self->input_id();
      my $genes = [];
      foreach my $gene_id (@$gene_ids) {
        push(@$genes,$gene_adaptor->fetch_by_dbID($gene_id));
      }
      $self->param('input_genes',$genes);

##############
#    say "DEBUG";
#    foreach my $gene_id (@$gene_ids) {
#    my $gene = $gene_adaptor->fetch_by_dbID($gene_id);
#    my $transcripts = $gene->get_all_Transcripts();
#    foreach my $transcript (@$transcripts) {
#      say "Transcript: ".$transcript->dbID;
#      my $introns = $transcript->get_all_Introns();
#      foreach my $intron (@$introns) {
#        my ($donor, $acceptor) = @{$intron->splice_seq};
#        my $intron_string = $intron->start.":".$intron->end.":".$strand;
#        say "IS: ".$intron_string." ".$donor.":".$acceptor;
#        my $intron_start = $intron->start();
#        my $intron_end = $intron->end();
#        my $intron_strand = $intron->strand;
#        my ($old_canon,$d,$e) = is_canonical_splice($intron,$target_dba->get_SliceAdaptor(),$gene->slice);
#        say "Old canon: ".$old_canon." ".$d."..".$e;
#        if($intron->is_splice_canonical) {
#          say "Intron: canonical ".$intron_start."..".$intron_end.":".$intron_strand." ".$donor."..".$acceptor;
#        } else {
#          say "Intron: non-canonical ".$intron_start."..".$intron_end.":".$intron_strand." ".$donor."..".$acceptor;
#        }
#      }
#    }
#  }
#  say "END DEBUG";

##############


    } # End if($self->param_required('dump_type') eq 'gene')

    $self->hrdb_set_con($target_dba,'target_db');
  } # End unless
}


sub run {
  my ($self) = @_;

  if($self->param_required('dump_type') eq 'gene') {
    say "Dumping introns to file from genes";
    my $genes = $self->param('input_genes');
    $self->dump_genes($genes);
  } elsif($self->param('dump_type') eq 'intron_table') {
    say "Dumping intron table to file from db";
    $self->dump_intron_table();
  } elsif($self->param('dump_type') eq 'combine_files') {
    $self->combine_files();
  } else {
    $self->throw("Dump type not recognised. Dump type: ".$self->param('dump_type'));
  }

}


=head2 write_output

 Arg [1]    : None
 Description: Dataflow the name of the resulting BAM file on branch 1 via 'filename'
 Returntype : None
 Exceptions : None

=cut

sub write_output {
  my ($self) = @_;

  unless($self->param('dump_type') eq 'combine_files') {
    my $output_file = $self->param('_output_file');
    my $accu_entry = "introns_file";
    $self->dataflow_output_id({$accu_entry => $output_file}, $self->param('_branch_to_flow_to'));
  }
}


sub dump_genes {
  my ($self,$genes) = @_;

  my $slice_adaptor = $self->hrdb_get_con('target_db')->get_SliceAdaptor;
  my $output_dir  = $self->param_required('introns_dir');
  my $output_file = $self->create_filename(undef,'int',$output_dir,1);
  my $temp_name = "$output_file";
  say "Creating output file: ".$output_file;
  my $input_type  = $self->param_required('input_type');
  my $small_intron_size = $self->param_required('small_intron_size');
  my $intron_string_hash = {};
  open(OUT,">".$output_file);
  foreach my $gene (@$genes) {
    my $strand = $gene->strand;
    say "Gene: ".$gene->dbID.":".$gene->strand;
    my $transcripts = $gene->get_all_Transcripts;
    my $seq_region_name = $gene->seq_region_name;
    foreach my $transcript (@$transcripts) {
      my $introns = $transcript->get_all_Introns();
      unless(scalar(@$introns)) {
	next;
      }

      foreach my $intron (@$introns) {
        my ($is_canonical,$donor,$acceptor) = is_canonical_splice($intron,$slice_adaptor,$gene->slice);
        my $intron_string = $intron->start.":".$intron->end.":".$strand;
#        say "IS: ".$intron_string." ".$donor.":".$acceptor;

#        unless($intron->is_splice_canonical) { # && $intron->length >= $small_intron_size) {
        unless($is_canonical && $intron->length >= $small_intron_size) {
#          say "Splice not canonical";
          next;
	}
        if($intron_string_hash->{$seq_region_name}->{$intron_string}) {
          $intron_string_hash->{$seq_region_name}->{$intron_string} += 1;
        } else {
          $intron_string_hash->{$seq_region_name}->{$intron_string} = 1;
        }
      } # end foreach my $intron (@$introns)
    } # end foreach my $transcript (@$transcripts)
  } # foreach my $gene (@$genes)

  foreach my $seq_region (keys(%$intron_string_hash)) {
    my $out_line = $seq_region.":".$input_type.",";
    my $introns = $intron_string_hash->{$seq_region};
    foreach my $intron (keys(%$introns)) {
      my $count = $introns->{$intron};
      $out_line .= $intron.":".$count.",";
    }
    say OUT $out_line;
  }
  close OUT;

  $self->param('_output_file',$temp_name);
}


sub dump_intron_table {
  my ($self) = @_;

  my $input_type  = $self->param_required('input_type');
  my $output_file = $self->param_required('introns_dir')."/".$input_type.".int";
  say "Creating output file: ".$output_file;
  open(OUT,">".$output_file);

  my $small_intron_size = $self->param_required('small_intron_size');
  my $intron_string_hash = {};
  my $target_dba = $self->hrdb_get_con('target_db');
  my $query = "SELECT hit_name,score FROM intron_supporting_evidence";
  my $sth = $target_dba->dbc->prepare($query);
  $sth->execute();
  while (my ($hit,$depth) = $sth->fetchrow_array) {
    $depth = int($depth);
    my @hit_array = split(':',$hit);
    unless($hit_array[4] eq "canon") {
      next;
    }

    my $seq_region_name = $hit_array[0];
    $seq_region_name =~ s/\*/\./;
    my $intron_string = $hit_array[1].":".$hit_array[2].":".$hit_array[3];

    unless(($hit_array[2] - $hit_array[1] + 1) >= $small_intron_size) {
      next;
    }

    if($intron_string_hash->{$seq_region_name}->{$intron_string}) {
      $intron_string_hash->{$seq_region_name}->{$intron_string} += $depth;
    } else {
      $intron_string_hash->{$seq_region_name}->{$intron_string} = $depth;
    }
  }

  foreach my $seq_region (keys(%$intron_string_hash)) {
    my $out_line = $seq_region.":".$input_type.",";
    my $introns = $intron_string_hash->{$seq_region};
    foreach my $intron (keys(%$introns)) {
      my $count = $introns->{$intron};
      $out_line .= $intron.":".$count.",";
    }
    say OUT $out_line;
  }
  close OUT;
  $self->param('_output_file',$output_file);
}


sub combine_files {
  my ($self) = @_;

  my $full_intron_hash = {};
  my $initial_intron_files = $self->param_required('introns_file');
  foreach my $intron_file (@$initial_intron_files) {
    unless(open(IN,$intron_file)) {
      $self->throw("Could not open intron file: ".$intron_file);
    }
    while(<IN>) {
      chomp $_;
      my @line = split(',',$_);
      my $header = $line[0];
      my ($seq_region,$type) = split(':',$header);
      if($self->param('use_generic_output_type')) {
        $type = $self->param('generic_output_type');
      }

      foreach(my $i=1; $i<scalar(@line); $i++) {
        my $intron_string = $line[$i];
        my ($start,$end,$strand,$count) = split(':',$intron_string);
        my $intron = $start.':'.$end.':'.$strand;
        if($full_intron_hash->{$seq_region}->{$type}->{$intron}) {
          $full_intron_hash->{$seq_region}->{$type}->{$intron} += $count;
        } else {
          $full_intron_hash->{$seq_region}->{$type}->{$intron} = $count;
	}
      }
    }
    close IN;
  }

  open(OUT,">".$self->param_required('combined_intron_file'));
  foreach my $seq_region (keys(%$full_intron_hash)) {
    foreach my $type (keys(%{$full_intron_hash->{$seq_region}})) {
      my $line = $seq_region.":".$type.",";
      foreach my $intron (keys(%{$full_intron_hash->{$seq_region}->{$type}})) {
        my $count = $full_intron_hash->{$seq_region}->{$type}->{$intron};
        $line .= $intron.":".$count.",";
      }
      say OUT $line;
    }
  }
  close OUT;
}


sub create_filename {
  my ($self, $stem, $ext, $dir, $no_clean) = @_;
  return create_file_name($stem, $ext, $dir, $no_clean);
}


1;