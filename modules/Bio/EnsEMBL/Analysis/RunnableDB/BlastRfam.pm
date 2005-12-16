# Ensembl module for Bio::EnsEMBL::Analysis::RunnableDB::Blast
#
# Copyright (c) 2004 Ensembl
#

=head1 NAME

  Bio::EnsEMBL::Analysis::RunnableDB::BlastRfam

=head1 SYNOPSIS

  my $blast = Bio::EnsEMBL::Analysis::RunnableDB::BlastRfam->
  new(
      -analysis => $analysis,
      -db => $db,
      -input_id => 'contig::AL1347153.1.3517:1:3571:1'
     );
  $blast->fetch_input;
  $blast->run;
  my @output =@{$blast->output};

=head1 DESCRIPTION

Modified blast runnable for specific use with RFAMSEQ.
Use for running BLASTN of genomic vs RFAMSEQ prior to 
ncRNA analysis using Infernal.
Slice size seems best around 200k

=head1 CONTACT

Post questions to the Ensembl development list: ensembl-dev@ebi.ac.uk

=cut

package Bio::EnsEMBL::Analysis::RunnableDB::BlastRfam;

use strict;
use warnings;

use Bio::EnsEMBL::Analysis::RunnableDB::Blast;
use Bio::EnsEMBL::Analysis::Runnable::BlastRfam;
use Bio::EnsEMBL::Utils::Exception qw(throw warning);
use Bio::EnsEMBL::Analysis::Config::General;
use Bio::EnsEMBL::Analysis::Config::Blast;
use Bio::EnsEMBL::Analysis::Config::Databases;
use vars qw(@ISA);

@ISA = qw(Bio::EnsEMBL::Analysis::RunnableDB::Blast);


=head2 fetch_input

  Arg [1]   : Bio::EnsEMBL::Analysis::RunnableDB::Blast
  Function  : fetch sequence out of database, instantiate the filter, 
  parser and finally the blast runnable
  Returntype: 1
  Exceptions: none
  Example   : 

=cut



sub fetch_input{
  my ($self) = @_;
  # dna database
  my $dna_db = new Bio::EnsEMBL::DBSQL::DBAdaptor
    (
     '-host'   => $GB_DBHOST,
     '-user'   => $GB_DBUSER,
     '-dbname' => $GB_DBNAME,
     '-pass'   => $GB_DBPASS,
     '-port'   => $GB_DBPORT,
    );
  #add dna_db
  $self->db->dnadb($dna_db);
  my $slice = $self->fetch_sequence($self->input_id, $self->db,'');
  $self->query($slice);
  my %blast = %{$self->BLAST_PARAMS};
   my $parser = $self->make_parser;
  my $filter;
  if($self->BLAST_FILTER){
    $filter = $self->make_filter;
  }
  my $seq = $self->query;
  my $runnable = Bio::EnsEMBL::Analysis::Runnable::BlastRfam->new
    (
     -query    => $seq,
     -program  => $self->analysis->program_file,
     -parser   => $parser,
     -filter   => $filter,
     -database => $self->analysis->db_file,
     -analysis => $self->analysis,
     -params   => \%blast,
    );
  $self->runnable($runnable);
  return 1;
}


