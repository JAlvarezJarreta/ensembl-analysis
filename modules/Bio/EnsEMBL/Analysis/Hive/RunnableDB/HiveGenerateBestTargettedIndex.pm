=head1 LICENSE

Copyright [1999-2015] Wellcome Trust Sanger Institute and the EMBL-European Bioinformatics Institute
Copyright [2016-2017] EMBL-European Bioinformatics Institute

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

Bio::EnsEMBL::Analysis::Hive::RunnableDB::HiveGenerateBestTargettedIndex

=head1 SYNOPSIS


=head1 DESCRIPTION


=cut

package Bio::EnsEMBL::Analysis::Hive::RunnableDB::HiveGenerateBestTargettedIndex;

use strict;
use warnings;

use Bio::EnsEMBL::IO::Parser::Genbank;
use Bio::EnsEMBL::Analysis::Tools::SeqFetcher::OBDAIndexSeqFetcher;
use Bio::Seq;
use Bio::SeqIO;

use LWP::UserAgent;

use parent qw(Bio::EnsEMBL::Analysis::Hive::RunnableDB::HiveBaseRunnableDB);


sub fetch_input {
  my ($self) = @_;

  my $genbank_parser = Bio::EnsEMBL::IO::Parser::Genbank->open($self->param_required('genbank_file'));
  $self->param('seqfetcher', Bio::EnsEMBL::Analysis::Tools::SeqFetcher::OBDAIndexSeqFetcher->new( -db => $self->param_required('seqfetcher_index')));
  $self->param_required('fasta_filename');
  my $dba = $self->get_database_by_name('source_db');
  my $adaptor = $dba->get_DnaAlignFeatureAdaptor;
  my %accessions;
  foreach my $f (@{$adaptor->fetch_all}) {
    next if (exists $accessions{$f->hseqname});
    $accessions{$f->hseqname} = 1;
  }
  my @seqs;
  while($genbank_parser->next) {
    my $cdna_accession = $genbank_parser->get_sequence_name;
    next unless (exists $accessions{$cdna_accession});
    foreach my $feature (@{$genbank_parser->get_features}) {
      if ($feature->{header} eq 'CDS' and exists $feature->{translation}) {
        push(@seqs, Bio::Seq->new(-id => $cdna_accession, -desc => $feature->{protein_id}->[0], -seq => join('', @{$feature->{translation}})));
        last;
      }
    }
  }
  $genbank_parser->close;
  $self->output(\@seqs);
}


sub run {
  my ($self) = @_;

  my $seqfetcher = $self->param('seqfetcher');
  my @embl_ids;
  my @refseq_ids;
  foreach my $sequence (@{$self->output}) {
    my $protein_accession = $sequence->desc;
    my $seq = $seqfetcher->get_entry_by_acc($protein_accession);
    if (!$seq) {
      if ($sequence->desc =~ /NP_/) {
        push(@refseq_ids, $sequence);
      }
      else {
        push(@embl_ids, $sequence);
      }
    }
  }
  my $params = {
    to => 'ACC',
    format => 'tab',
    columns => 'id,version(sequence)',
  };
  if (@embl_ids) {
    $params->{from} = 'EMBL';
    $self->_get_uniprot_accession($params, \@embl_ids);
  }
  if (@refseq_ids) {
    $params->{from} = 'P_REFSEQ_AC';
    $self->_get_uniprot_accession($params, \@refseq_ids);
  }
}


sub _get_uniprot_accession {
  my ($self, $params, $seqs) = @_;

  $params->{query} = join(' ', map {$_->desc} @$seqs);
  my $query_url = 'http://www.uniprot.org/uploadlists/';
  my $ua = LWP::UserAgent->new(agent => 'libwwww-perl '.$self->param('email'));
  $ua->env_proxy();
  push(@{$ua->requests_redirectable}, 'POST');
  my %missing;
  my $response = $ua->post($query_url, $params);
  while (my $wait = $response->header('Retry-After')) {
    sleep $wait;
    $response = $ua->get($response->base);
  }
  if ($response->is_success) {
    my $result = $response->content;
    while($result =~ /(\w+)\s+(\d+)\s+(\S+)/mgc) {
     $missing{$3} = "$1.$2";
    }
  }
  else {
    $self->throw($response->status_line.' for '.$response->request->uri);
  }
  foreach my $seq (@$seqs) {
    $seq->desc($missing{$seq->desc}) if (exists $missing{$seq->desc});
  }
}


sub write_output {
  my ($self) = @_;

  my $fasta_file = Bio::SeqIO->new(-format => 'fasta', -file => '>'.$self->param('fasta_filename'));
  foreach my $seq (@{$self->output}) {
    $fasta_file->write_seq($seq);
  }
  $fasta_file->close;
}

1;