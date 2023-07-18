=head1 LICENSE

Copyright [2021] EMBL-European Bioinformatics Institute

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

     http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

=cut

package EnsemblAnnoBraker_conf;

use strict;
use warnings;
use File::Spec::Functions;

use Bio::EnsEMBL::ApiVersion qw/software_version/;
use Bio::EnsEMBL::Analysis::Tools::Utilities qw(get_analysis_settings);
use Bio::EnsEMBL::Hive::PipeConfig::HiveGeneric_conf;
use base ('Bio::EnsEMBL::Analysis::Hive::Config::HiveBaseConfig_conf');

sub default_options {
  my ($self) = @_;
  return {
    # inherit other stuff from the base class
    %{ $self->SUPER::default_options() },
    #BRAKER parameters
    'augustus_config_path'     => '/nfs/production/flicek/ensembl/genebuild/genebuild_virtual_user/augustus_config/config',
    'augustus_species_path'    => '/nfs/production/flicek/ensembl/genebuild/genebuild_virtual_user/augustus_config/config/species/',
    'braker_singularity_image' => '/hps/software/users/ensembl/genebuild/genebuild_virtual_user/singularity/test-braker2_es_ep_etp.simg',
    'agat_singularity_image'   => '/hps/software/users/ensembl/genebuild/genebuild_virtual_user/singularity/test-agat.simg',
    'busco_singularity_image'  => '/hps/software/users/ensembl/genebuild/genebuild_virtual_user/singularity/busco-v5.1.2_cv1.simg',
    'busco_download_path'      => '/nfs/production/flicek/ensembl/genebuild/genebuild_virtual_user/data/busco_data/data',

    'current_genebuild'            => 0,
    'cores'                        => 30,
    'num_threads'                  => 20,
    'dbowner'                      => '' || $ENV{EHIVE_USER} || $ENV{USER},
    'base_output_dir'              => '',
    'init_config'               => '', #path for configuration file (custom loading)
    'override_clade'               => '', #optional, already defined in ProcessGCA
    'protein_file'                 => '', #optional, already defined in ProcessGCA
    'busco_protein_file'           => '', #optional, already defined in ProcessGCA
    'rfam_accessions_file'         => '', #optional, already defined in ProcessGCA
    'use_existing_short_read_dir'  => '', #path for esisting short read data
    'registry_file'                => catfile( $self->o('enscode_root_dir'),'ensembl-analysis/scripts/genebuild/gbiab/support_files/Databases.pm' ), # This should be the path to the pipeline's copy of the Databases.pm registry file, core adaptors will be written to it
    'generic_registry_file'        => '',                                                                                                                # Could use this to hold the path to ensembl-analysis/scripts/genebuild/gbiab/support_files/Databases.pm to copy as a generic registry
    'diamond_validation_db'        => '/hps/nobackup/flicek/ensembl/genebuild/blastdb/uniprot_euk_diamond/uniprot_euk.fa.dmnd',
    'validation_type'              => 'moderate',
    'release_number'               => '' || $self->o('ensembl_release'),
    'production_name'              => '' || $self->o('species_name'),
    'pipeline_name'                => '' || $self->o('production_name') . $self->o('production_name_modifier'),
    'user_r'                       => '',                                                                                                                # read only db user
    'user'                         => '',                                                                                                                # write db user
    'password'                     => '',                                                                                                                # password for write db user
    'server_set'                   => '',                                                                                                                # What server set to user, e.g. set1
    'busco_input_file_stid'        => 'stable_id_to_dump.txt',
    'species_name'                 => '', #optional, already defined in ProcessGCA e.g. mus_musculus
    'taxon_id'                     => '', #optional, already defined in ProcessGCA, should be in the assembly report file
    'species_taxon_id'             => '' || $self->o('taxon_id'),                                                                                        # Species level id, could be different to taxon_id if we have a subspecies, used to get species level RNA-seq CSV data
    'genus_taxon_id'               => '' || $self->o('taxon_id'),                                                                                        # Genus level taxon id, used to get a genus level csv file in case there is not enough species level transcriptomic data
    'uniprot_set'                  => '', #optional, already defined in ProcessGCA e.g. mammals_basic, check UniProtCladeDownloadStatic.pm module in hive config dir for suitable set,
    'output_path'                  => '', #optional, already defined in ProcessGCA
    'assembly_name'                => '', #optional aleady defined in the registry
    'assembly_accession'           => '', #the pipeline is initialed via standalone job  # Versioned GCA assembly accession, e.g. GCA_001857705.1
    'stable_id_prefix'             => '', #optional, already defined in ProcessGCA
    'use_genome_flatfile'          => '1',# This will read sequence where possible from a dumped flatfile instead of the core db
    'species_url'                  => '' || $self->o('production_name') . $self->o('production_name_modifier'),                                          # sets species.url meta key
    'species_division'             => '', #optional, already defined in ProcessGCA # sets species.division meta key
    'stable_id_start'              => '', #optional, already defined in ProcessGCA When mapping is not required this is usually set to 0
    'mapping_required'             => '0',# If set to 1 this will run stable_id mapping sometime in the future. At the moment it does nothing
    'uniprot_version'              => 'uniprot_2021_04',                                                                                                 # What UniProt data dir to use for various analyses
    'production_name_modifier'     => '',                                                                                                                # Do not set unless working with non-reference strains, breeds etc. Must include _ in modifier, e.g. _hni for medaka strain HNI

    # Keys for custom loading, only set/modify if that's what you're doing
    'load_toplevel_only'        => '1',                                                                                                                  # This will not load the assembly info and will instead take any chromosomes, unplaced and unlocalised scaffolds directly in the DNA table
    'custom_toplevel_file_path' => '',                                                                                                                   # Only set this if you are loading a custom toplevel, requires load_toplevel_only to also be set to 2
    'repeatmodeler_library'     => '', #no needed, it can be an option for the anno command This should be the path to a custom repeat library, leave blank if none exists
    'base_blast_db_path'    => $ENV{BLASTDB_DIR},
    'protein_entry_loc'         => catfile( $self->o('base_blast_db_path'), 'uniprot', $self->o('uniprot_version'), 'entry_loc' ),                       # Used by genscan blasts and optimise daf/paf. Don't change unless you know what you're doing

    'softmask_logic_names' => [],



########################
# Pipe and ref db info
########################


    'provider_name' => 'Ensembl',
    'provider_url'  => 'www.ensembl.org',

    'pipe_db_name' => $self->o('dbowner') . '_' . $self->o('pipeline_name') . '_pipe_' . $self->o('release_number'),
    #'pipe_db_name'                  => $self->o('pipeline_name') . 'f_pipe_' . '105',
    'dna_db_name' => $self->o('dbowner') . '_' . $self->o('production_name') . $self->o('production_name_modifier') . '_core_' . $self->o('release_number'),


    # This is used for the ensembl_production and the ncbi_taxonomy databases
    'ensembl_release'      => $ENV{ENSEMBL_RELEASE},     # this is the current release version on staging to be able to get the correct database
    'production_db_server' => 'mysql-ens-meta-prod-1',
    'production_db_port'   => '4483',


    ensembl_analysis_script           => catdir( $self->o('enscode_root_dir'), 'ensembl-analysis', 'scripts' ),
    load_optimise_script              => catfile( $self->o('ensembl_analysis_script'), 'genebuild', 'load_external_db_ids_and_optimize_af.pl' ),
    remove_duplicates_script          => catfile( $self->o('ensembl_analysis_script'), 'find_and_remove_duplicates.pl' ),
    ensembl_misc_script               => catdir( $self->o('enscode_root_dir'),        'ensembl',   'misc-scripts' ),
    meta_coord_script                 => catfile( $self->o('ensembl_misc_script'),     'meta_coord', 'update_meta_coord.pl' ),
    meta_levels_script                => catfile( $self->o('ensembl_misc_script'),     'meta_levels.pl' ),
    frameshift_attrib_script          => catfile( $self->o('ensembl_misc_script'),     'frameshift_transcript_attribs.pl' ),
    select_canonical_script           => catfile( $self->o('ensembl_misc_script'),     'canonical_transcripts', 'select_canonical_transcripts.pl' ),
    print_protein_script_path         => catfile( $self->o('ensembl_analysis_script'), 'genebuild', 'print_translations.pl' ),

    registry_status_update_script => catfile( $self->o('ensembl_analysis_script'), 'update_assembly_registry.pl' ),

########################
# Extra db settings
########################

    'num_tokens'       => 10,

########################
# Executable paths
########################

    samtools_path            => catfile( $self->o('binary_base'),        'samtools' ),                                                    #You may need to specify the full path to the samtools binary

    'uniprot_table_name'          => 'uniprot_sequences',


# Best targetted stuff
    cdna_table_name                             => 'cdna_sequences',


# RNA-seq pipeline stuff
    # You have the choice between:
    #  * using a csv file you already created
    #  * using a study_accession like PRJEB19386
    #  * using the taxon_id of your species
    # 'rnaseq_summary_file' should always be set. If 'taxon_id' or 'study_accession' are not undef
    # they will be used to retrieve the information from ENA and to create the csv file. In this case,
    # 'file_columns' and 'summary_file_delimiter' should not be changed unless you know what you are doing
    'summary_csv_table'      => 'csv_data',
    'read_length_table'      => 'read_length',
    'rnaseq_data_provider'   => 'ENA',           #It will be set during the pipeline or it will use this value

    'rnaseq_dir'  => catdir( $self->o('output_path'), 'rnaseq' ),
    'input_dir'   => catdir( $self->o('rnaseq_dir'),  'input' ),

    'rnaseq_ftp_base' => 'ftp://ftp.sra.ebi.ac.uk/vol1/fastq/',

    'rnaseq_summary_file'          => '' || catfile( $self->o('rnaseq_dir'),    $self->o('species_name') . '.csv' ),                                     # Set this if you have a pre-existing cvs file with the expected columns
    'rnaseq_summary_file_genus'    => '' || catfile( $self->o('rnaseq_dir'),    $self->o('species_name') . '_gen.csv' ),                                 # Set this if you have a pre-existing genus level cvs file with the expected columns
    'long_read_dir'       => catdir( $self->o('output_path'),   'long_read' ),
    'long_read_summary_file'       => '' || catfile( $self->o('long_read_dir'), $self->o('species_name') . '_long_read.csv' ),                           # csv file for minimap2, should have 2 columns tab separated cols: sample_name\tfile_name
    'long_read_summary_file_genus' => '' || catfile( $self->o('long_read_dir'), $self->o('species_name') . '_long_read_gen.csv' ),                       # csv file for minimap2, should have 2 columns tab separated cols: sample_name\tfile_name
    'long_read_fastq_dir'          => '' || catdir( $self->o('long_read_dir'), 'input' ),


    # Please assign some or all columns from the summary file to the
    # some or all of the following categories.  Multiple values can be
    # separted with commas. ID, SM, DS, CN, is_paired, filename, read_length, is_13plus,
    # is_mate_1 are required. If pairing_regex can work for you, set is_mate_1 to -1.
    # You can use any other tag specified in the SAM specification:
    # http://samtools.github.io/hts-specs/SAMv1.pdf

    ####################################################################
    # This is just an example based on the file snippet shown below.  It
    # will vary depending on how your data looks.
    ####################################################################
    file_columns      => [ 'SM',     'ID', 'is_paired', 'filename', 'is_mate_1', 'read_length', 'is_13plus', 'CN', 'PL', 'DS' ],
    long_read_columns => [ 'sample', 'filename' ],

########################
# Interproscan
########################
    'realign_table_name'               => 'projection_source_sequences',

# !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
# No option below this mark should be modified
# !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
#
########################################################
# URLs for retrieving the INSDC contigs and RefSeq files
########################################################
    'ncbi_base_ftp'          => 'ftp://ftp.ncbi.nlm.nih.gov/genomes/all',
    'insdc_base_ftp'         => $self->o('ncbi_base_ftp') . '/#expr(substr(#assembly_accession#, 0, 3))expr#/#expr(substr(#assembly_accession#, 4, 3))expr#/#expr(substr(#assembly_accession#, 7, 3))expr#/#expr(substr(#assembly_accession#, 10, 3))expr#/#assembly_accession#_#assembly_name#',
    'assembly_ftp_path'      => $self->o('insdc_base_ftp'),

########################
# db info
########################
    'pipe_db_server'               => $ENV{GBS7},                                                                                                        # host for pipe db
    'dna_db_server'                => $ENV{GBS6},                                                                                                        # host for dna db
    'pipe_db_port'                 => $ENV{GBP7},                                                                                                        # port for pipeline host
    'dna_db_port'                  => $ENV{GBP6},                                                                                                        # port for dna db host
    'registry_db_server'           => $ENV{GBS1},                                                                                                        # host for registry db
    'registry_db_port'             => $ENV{GBP1},                                                                                                        # port for registry db
    'registry_db_name'             => 'gb_assembly_registry', 

    otherfeatures_db_host => $self->o('dna_db_server'),
    otherfeatures_db_port => $self->o('dna_db_port'),
    otherfeatures_db_name => $self->o('dbowner') . '_' . $self->o('production_name') . '_otherfeatures_' . $self->o('release_number'),



    'core_db' => {
      -dbname => $self->o('dna_db_name'),
      -host   => $self->o('dna_db_server'),
      -port   => $self->o('dna_db_port'),
      -user   => $self->o('user'),
      -pass   => $self->o('password'),
      -driver => $self->o('hive_driver'),
    },

    'production_db' => {
      -host   => $self->o('production_db_server'),
      -port   => $self->o('production_db_port'),
      -user   => $self->o('user_r'),
      -pass   => $self->o('password_r'),
      -dbname => 'ensembl_production',
      -driver => $self->o('hive_driver'),
    },

    'taxonomy_db' => {
      -host   => $self->o('production_db_server'),
      -port   => $self->o('production_db_port'),
      -user   => $self->o('user_r'),
      -pass   => $self->o('password_r'),
      -dbname => 'ncbi_taxonomy',
      -driver => $self->o('hive_driver'),
    },

    'registry_db' => {
      -host   => $self->o('registry_db_server'),
      -port   => $self->o('registry_db_port'),
      -user   => $self->o('user'),
      -pass   => $self->o('password'),
      -dbname => $self->o('registry_db_name'),
      -driver => $self->o('hive_driver'),
    },


    'pipe_db' => {
      -dbname => $self->o('pipe_db_name'),
      -host   => $self->o('pipe_db_server'),
      -port   => $self->o('pipe_db_port'),
      -user   => $self->o('user'),
      -pass   => $self->o('password'),
      -driver => $self->o('hive_driver'),
    },
    'otherfeatures_db' => {
      -dbname => $self->o('otherfeatures_db_name'),
      -host   => $self->o('otherfeatures_db_host'),
      -port   => $self->o('otherfeatures_db_port'),
      -user   => $self->o('user'),
      -pass   => $self->o('password'),
      -driver => $self->o('hive_driver'),
    },

    #######################
    # Extra db settings
    ########################
    num_tokens => 10,

  };
}

sub pipeline_create_commands {
  my ($self) = @_;

  my $tables;
  my %small_columns = (
    paired      => 1,
    read_length => 1,
    is_13plus   => 1,
    is_mate_1   => 1,
  );
  # We need to store the values of the csv file to easily process it. It will be used at different stages
  foreach my $key ( @{ $self->default_options->{'file_columns'} } ) {
    if ( exists $small_columns{$key} ) {
      $tables .= $key . ' SMALLINT UNSIGNED NOT NULL,';
    }
    elsif ( $key eq 'DS' ) {
      $tables .= $key . ' VARCHAR(255) NOT NULL,';
    }
    else {
      $tables .= $key . ' VARCHAR(50) NOT NULL,';
    }
  }
  $tables .= ' KEY(SM), KEY(ID)';


################
# LastZ
################

  my $second_pass = exists $self->{'_is_second_pass'};
  $self->{'_is_second_pass'} = $second_pass;
  return $self->SUPER::pipeline_create_commands if $self->can('no_compara_schema');
  my $pipeline_url = $self->pipeline_url();
  my $parsed_url   = $second_pass && Bio::EnsEMBL::Hive::Utils::URL::parse($pipeline_url);
  my $driver       = $second_pass ? $parsed_url->{'driver'} : '';

################
# /LastZ
################

  return [
    # inheriting database and hive tables' creation
    @{ $self->SUPER::pipeline_create_commands },

    $self->hive_data_table( 'protein', $self->o('uniprot_table_name') ),

    $self->hive_data_table( 'refseq', $self->o('cdna_table_name') ),

    $self->db_cmd( 'CREATE TABLE ' . $self->o('realign_table_name') . ' (' .
        'accession varchar(50) NOT NULL,' .
        'seq text NOT NULL,' .
        'PRIMARY KEY (accession))' ),

    $self->db_cmd( 'CREATE TABLE ' . $self->o('summary_csv_table') . " ($tables)" ),

    $self->db_cmd( 'CREATE TABLE ' . $self->o('read_length_table') . ' (' .
        'fastq varchar(50) NOT NULL,' .
        'read_length int(50) NOT NULL,' .
        'PRIMARY KEY (fastq))' ),

  ];
}


sub pipeline_wide_parameters {
  my ($self) = @_;

  return {
    %{ $self->SUPER::pipeline_wide_parameters },
    wide_ensembl_release => $self->o('ensembl_release'),
    load_toplevel_only => $self->o('load_toplevel_only'),
  };
}

=head2 create_header_line

 Arg [1]    : Arrayref String, it will contains the values of 'file_columns'
 Example    : create_header_line($self->o('file_columns');
 Description: It will create a RG line using only the keys present in your csv file
 Returntype : String representing the RG line in a BAM file
 Exceptions : None


=cut

sub create_header_line {
  my ($items) = shift;

  my @read_tags = qw(ID SM DS CN DT FO KS LB PG PI PL PM PU);
  my $read_line = '@RG';
  foreach my $rt (@read_tags) {
    $read_line .= "\t$rt:#$rt#" if ( grep( $rt eq $_, @$items ) );
  }
  return $read_line . "\n";
}

## See diagram for pipeline structure
sub pipeline_analyses {
  my ($self) = @_;

  my %genblast_params = (
    wu              => '-P wublast -gff -e #blast_eval# -c #blast_cov#',
    ncbi            => '-P blast -gff -e #blast_eval# -c #blast_cov# -W 3 -softmask -scodon 50 -i 30 -x 10 -n 30 -d 200000 -g T',
    wu_genome       => '-P wublast -gff -e #blast_eval# -c #blast_cov#',
    ncbi_genome     => '-P blast -gff -e #blast_eval# -c #blast_cov# -W 3 -softmask -scodon 50 -i 30 -x 10 -n 30 -d 200000 -g T',
    wu_projection   => '-P wublast -gff -e #blast_eval# -c #blast_cov# -n 100 -x 5 ',
    ncbi_projection => '-P blast -gff -e #blast_eval# -c #blast_cov# -W 3 -scodon 50 -i 30 -x 10 -n 30 -d 200000 -g T',
  );
  my %commandline_params = (
    'ncbi'        => '-num_threads 3 -window_size 40',
    'wu'          => '-cpus 3 -hitdist 40',
    'legacy_ncbi' => '-a 3 -A 40',
  );
  my $header_line = create_header_line( $self->default_options->{'file_columns'} );

  return [


###############################################################################
#
# ASSEMBLY LOADING ANALYSES
#
###############################################################################
# 1) Process GCA - works out settings, flows them down the pipeline -> this should be seeded by another analysis later
# 2) Standard create core, populate tables, download data etc
# 3) Either run gbiab or setup gbiab
# 4) Finalise steps


    {
      # Creates a reference db for each species
      -logic_name => 'process_gca',
      -module     => 'Bio::EnsEMBL::Analysis::Hive::RunnableDB::ProcessGCA',
      -parameters => {
        'num_threads'                 => $self->o('num_threads'),
        'dbowner'                     => $self->o('dbowner'),
        'core_db'                     => $self->o('core_db'),
        'otherfeatures_db'            => $self->o('otherfeatures_db'),
        'ensembl_release'             => $self->o('ensembl_release'),
        'base_output_dir'             => $self->o('base_output_dir'),
        'registry_db'                 => $self->o('registry_db'),
        'enscode_root_dir'            => $self->o('enscode_root_dir'),
        'registry_file'               => $self->o('registry_file'),
        'diamond_validation_db'       => $self->o('diamond_validation_db'),
        'validation_type'             => $self->o('validation_type'),
        'use_existing_short_read_dir' => $self->o('use_existing_short_read_dir'),
        'override_clade'              => $self->o('override_clade'),
        'pipe_db'                     => $self->o('pipe_db'),
        'current_genebuild'           => $self->o('current_genebuild'),
	'init_config'     =>$self->o('init_config'),
        'assembly_accession'     =>$self->o('assembly_accession'),
   	'repeatmodeler_library' =>$self->o('repeatmodeler_library'),
   },
      -rc_name => 'default',

      -flow_into => {
        1 => ['download_rnaseq_csv'],
      },
      -analysis_capacity => 1,
      -input_ids         => [
        #{'assembly_accession' => 'GCA_910591885.1'},
        #	{'assembly_accession' => 'GCA_905333015.1'},
      ],
    },


    {
      -logic_name => 'download_rnaseq_csv',
      -module     => 'Bio::EnsEMBL::Hive::RunnableDB::SystemCmd',
      -rc_name    => '1GB',
      -parameters => {
        cmd => 'python ' . catfile( $self->o('enscode_root_dir'), 'ensembl-genes', 'scripts','transcriptomic_data','get_transcriptomic_data.py' ) . ' -t #species_taxon_id# ' .'-f #rnaseq_summary_file# --read_type short' ,
        # This is specifically for gbiab, as taxon_id is populated in the input id with
        # the actual taxon, had to add some code override. Definitely better solutions available,
        # one might be to just branch this off and then only pass the genus taxon id
        #override_taxon_id => 1,
        #taxon_id          => '#genus_taxon_id#',
        #inputfile         => '#rnaseq_summary_file#',
        #input_dir         => $self->o('use_existing_short_read_dir'),
      },

      -flow_into => {
        '1->A' => { 'fan_short_read_download' => { 'inputfile' => '#rnaseq_summary_file#', 'input_dir' => '#short_read_dir#' } },
        'A->1' => ['download_long_read_csv'],
      },
    },


    {
      -logic_name => 'fan_short_read_download',
      -module     => 'Bio::EnsEMBL::Hive::RunnableDB::SystemCmd',
      -parameters => {
        cmd                     => 'if [ -e "#inputfile#" ]; then exit 0; else exit 42;fi',
        return_codes_2_branches => { '42' => 2 },
      },
      -rc_name   => 'default',
      -flow_into => {
        1 => { 'create_sr_fastq_download_jobs' => { 'inputfile' => '#inputfile#', 'input_dir' => '#input_dir#' } },
      },
    },


    {
      -logic_name => 'create_sr_fastq_download_jobs',
      -module     => 'Bio::EnsEMBL::Hive::RunnableDB::JobFactory',
      -parameters => {
        column_names => $self->o('file_columns'),
        delimiter    => '\t',
      },
      -flow_into => {
        2 => { 'download_short_read_fastqs' => { 'iid' => '#filename#', 'input_dir' => '#input_dir#' } },
      },
    },


    {
      -logic_name => 'download_short_read_fastqs',
      -module     => 'Bio::EnsEMBL::Analysis::Hive::RunnableDB::HiveDownloadRNASeqFastqs',
      -parameters => {
        ftp_base_url => $self->o('rnaseq_ftp_base'),
        input_dir    => $self->o('input_dir'),
      },
      -analysis_capacity => 50,
    },


    {
      -logic_name => 'download_long_read_csv',
      -module     => 'Bio::EnsEMBL::Hive::RunnableDB::SystemCmd',
      -rc_name    => '1GB',
      -parameters => {
        cmd => 'python ' . catfile( $self->o('enscode_root_dir'), 'ensembl-genes', 'scripts','transcriptomic_data','get_transcriptomic_data.py' ) . ' -t #species_taxon_id# ' .'-f #long_read_summary_file# --read_type long' ,
        # This is specifically for gbiab, as taxon_id is populated in the input id with
        # the actual taxon, had to add some code override. Definitely better solutions available,
        # one might be to just branch this off and then only pass the genus taxon id
        #override_taxon_id => 1,
        #taxon_id          => '#genus_taxon_id#',
        #read_type         => 'isoseq',
        #inputfile         => '#long_read_summary_file#',
      },

      -flow_into => {
        '1->A' => { 'fan_long_read_download' => { 'inputfile' => '#long_read_summary_file#', 'input_dir' => '#long_read_dir#' } },
        'A->1' => ['create_core_db'],
      },
    },

    {
      -logic_name => 'fan_long_read_download',
      -module     => 'Bio::EnsEMBL::Hive::RunnableDB::SystemCmd',
      -parameters => {
        cmd                     => 'if [ -e "#inputfile#" ]; then exit 0; else exit 42;fi',
        return_codes_2_branches => { '42' => 2 },
      },
      -flow_into => {
        1 => ['create_lr_fastq_download_jobs'],
      },
      -rc_name => 'default',
    },


    {
      -logic_name => 'create_lr_fastq_download_jobs',
      -module     => 'Bio::EnsEMBL::Hive::RunnableDB::JobFactory',
      -parameters => {
        column_names => $self->o('long_read_columns'),
        delimiter    => '\t',
      },
      -flow_into => {
        2 => { 'download_long_read_fastq' => { 'iid' => '#filename#', 'input_dir' => '#input_dir#' } },
      },
    },


    {
      -logic_name => 'download_long_read_fastq',
      -module     => 'Bio::EnsEMBL::Analysis::Hive::RunnableDB::HiveDownloadRNASeqFastqs',
      -parameters => {
        ftp_base_url  => $self->o('rnaseq_ftp_base'),
        input_dir     => $self->o('long_read_fastq_dir'),
        samtools_path => $self->o('samtools_path'),
        decompress    => 1,
        create_faidx  => 1,
      },
      -rc_name           => '1GB',
      -analysis_capacity => 50,
    },

    {
      # Creates a reference db for each species
      -logic_name => 'create_core_db',
      -module     => 'Bio::EnsEMBL::Analysis::Hive::RunnableDB::HiveCreateDatabase',
      -parameters => {
        'target_db'        => '#core_db#',
        'enscode_root_dir' => $self->o('enscode_root_dir'),
        'create_type'      => 'core_only',
      },
      -rc_name => 'default',

      -flow_into => {
        1 => ['populate_production_tables'],
      },
    },


    {
      # Load production tables into each reference
      -logic_name => 'populate_production_tables',
      -module     => 'Bio::EnsEMBL::Analysis::Hive::RunnableDB::HiveAssemblyLoading::HivePopulateProductionTables',
      -parameters => {
        'target_db'        => '#core_db#',
        'output_path'      => '#output_path#',
        'enscode_root_dir' => $self->o('enscode_root_dir'),
        'production_db'    => $self->o('production_db'),
      },
      -rc_name => 'default',

      -flow_into => {
	      # 1 => ['process_assembly_info'],
	      1 => WHEN ('#load_toplevel_only# == 1' => ['process_assembly_info'],
                        '#load_toplevel_only# == 2' => ['custom_load_toplevel']),
      },
    },
    ####
    # Loading custom assembly where the user provide a FASTA file, probably a repeat library
    ####
    {
      -logic_name => 'custom_load_toplevel',
      -module => 'Bio::EnsEMBL::Hive::RunnableDB::SystemCmd',
      -parameters => {
        cmd => 'perl '.catfile($self->o('enscode_root_dir'), 'ensembl-analysis', 'scripts', 'assembly_loading', 'load_seq_region.pl').
          ' -dbhost '.$self->o('dna_db_server').
          ' -dbuser '.$self->o('user').
          ' -dbpass '.$self->o('password').
          ' -dbport '.$self->o('dna_db_port').
          ' -dbname '.'#core_dbname#'.
          ' -coord_system_version '.$self->o('assembly_name').
          ' -default_version'.
          ' -coord_system_name primary_assembly'.
          ' -rank 1'.
          ' -fasta_file '. $self->o('custom_toplevel_file_path').
          ' -sequence_level'.
          ' -noverbose',
      },
      -rc_name => '4GB',
      -flow_into => {
        1 => ['custom_set_toplevel'],
      },
    },

    {
      -logic_name => 'custom_set_toplevel',
      -module => 'Bio::EnsEMBL::Hive::RunnableDB::SystemCmd',
      -parameters => {
        cmd => 'perl '.catfile($self->o('enscode_root_dir'), 'ensembl-analysis', 'scripts', 'assembly_loading', 'set_toplevel.pl').
          ' -dbhost '.$self->o('dna_db_server').
          ' -dbuser '.$self->o('user').
          ' -dbpass '.$self->o('password').
          ' -dbport '.$self->o('dna_db_port').
          ' -dbname '.'#core_dbname#',
      },
      -rc_name => 'default',
      -flow_into  => {
        1 => ['custom_add_meta_keys'],
      },
    },

    {
      -logic_name => 'custom_add_meta_keys',
      -module     => 'Bio::EnsEMBL::Hive::RunnableDB::SqlCmd',
      -parameters => {
        db_conn => '#core_db#',
        sql => [
          'INSERT INTO meta (species_id,meta_key,meta_value) VALUES (1,"assembly.default","'.$self->o('assembly_name').'")',
          'INSERT INTO meta (species_id,meta_key,meta_value) VALUES (1,"assembly.name","'.$self->o('assembly_name').'")',
          'INSERT INTO meta (species_id,meta_key,meta_value) VALUES (1,"species.taxonomy_id","'.$self->o('taxon_id').'")',
        ],
      },
      -rc_name    => 'default',
      -flow_into => {
        1 => ['anno_load_meta_info'],
      },
    },


    {
      # Download the files and dir structure from the NCBI ftp site. Uses the link to a species in the ftp_link_file
      -logic_name => 'process_assembly_info',
      -module     => 'Bio::EnsEMBL::Analysis::Hive::RunnableDB::HiveProcessAssemblyReport',
      -parameters => {
        full_ftp_path => $self->o('assembly_ftp_path'),
        output_path   => '#output_path#',
        target_db     => '#core_db#',
      },
      -rc_name         => '8GB',
      -max_retry_count => 3,
      -flow_into       => {
        1 => ['check_load_meta_info'],
      },
    },
    {
      -logic_name => 'check_load_meta_info',
      -module     => 'Bio::EnsEMBL::Hive::RunnableDB::SystemCmd',
      -parameters => {
        cmd                     => 'if [ -e "#rnaseq_summary_file#" ] || [ -e "#long_read_summary_file#" ]; then exit 0; else  exit 42;fi',
        return_codes_2_branches => { '42' => 2 },
      },
      -flow_into => {
        1 => ['anno_load_meta_info'],
        2 => ['braker_load_meta_info'],
      },
      -rc_name => 'default',
    },
    {
      # Load some meta info and seq_region_synonyms
      -logic_name => 'anno_load_meta_info',
      -module     => 'Bio::EnsEMBL::Hive::RunnableDB::SqlCmd',
      -parameters => {
        db_conn => '#core_db#',
        sql     => [
          'DELETE FROM meta WHERE meta_key="species.display_name"',
          'INSERT IGNORE INTO meta (species_id, meta_key, meta_value) VALUES ' .
            '(1, "annotation.provider_name", "Ensembl"),' .
            '(1, "annotation.provider_url", "www.ensembl.org"),' .
            '(1, "assembly.coverage_depth", "high"),' .
            '(1, "assembly.provider_name", NULL),' .
            '(1, "assembly.provider_url", NULL),' .
            '(1, "assembly.ucsc_alias", NULL),' .
            '(1, "species.stable_id_prefix", "#stable_id_prefix#"),' .
            '(1, "species.url", "#species_url#"),' .
            '(1, "species.display_name", "#species_display_name#"),' .
            '(1, "species.division", "#species_division#"),' .
            '(1, "species.strain", "#species_strain#"),' .
            '(1, "species.production_name", "#production_name#"),' .
            '(1, "strain.type", "#strain_type#"),' .
            '(1, "repeat.analysis", "repeatdetector"),' .
            '(1, "repeat.analysis", "dust"),' .
            '(1, "repeat.analysis", "trf"),' .
            '(1, "genebuild.initial_release_date", NULL),' .
            '(1, "genebuild.id", ' . $self->o('genebuilder_id') . '),' .
            '(1, "genebuild.method", "anno"),'.
	    '(1, "genebuild.method_display", "Ensembl Genebuild"),'.
        '(1, "species.annotation_source", "ensembl")'
        ],
      },
      -max_retry_count => 0,
      -rc_name         => 'default',
      -flow_into       => {
        1 => ['load_taxonomy_info'],
      },
    },
    {
      # Load some meta info and seq_region_synonyms
      -logic_name => 'braker_load_meta_info',
      -module     => 'Bio::EnsEMBL::Hive::RunnableDB::SqlCmd',
      -parameters => {
        db_conn => '#core_db#',
        sql     => [
          'DELETE FROM meta WHERE meta_key="species.display_name"',
          'INSERT IGNORE INTO meta (species_id, meta_key, meta_value) VALUES ' .
            '(1, "annotation.provider_name", "Ensembl"),' .
            '(1, "annotation.provider_url", "www.ensembl.org"),' .
            '(1, "assembly.coverage_depth", "high"),' .
            '(1, "assembly.provider_name", NULL),' .
            '(1, "assembly.provider_url", NULL),' .
            '(1, "assembly.ucsc_alias", NULL),' .
            '(1, "species.stable_id_prefix", "BRAKER#species_prefix#"),' .
            '(1, "species.url", "#species_url#"),' .
            '(1, "species.display_name", "#species_display_name#"),' .
            '(1, "species.division", "#species_division#"),' .
            '(1, "species.strain", "#species_strain#"),' .
            '(1, "species.production_name", "#production_name#"),' .
            '(1, "strain.type", "#strain_type#"),' .
            '(1, "repeat.analysis", "repeatdetector"),' .
            '(1, "repeat.analysis", "dust"),' .
            '(1, "repeat.analysis", "trf"),' .
            '(1, "genebuild.initial_release_date", NULL),' .
            '(1, "genebuild.id", ' . $self->o('genebuilder_id') . '),' .
            '(1, "genebuild.method", "braker"),'.
	    '(1, "genebuild.method_display", "BRAKER2"),'.
	    '(1, "species.annotation_source", "braker")'
        ],
      },
      -max_retry_count => 0,
      -rc_name         => 'default',
      -flow_into       => {
        1 => ['load_taxonomy_info'],
      },
    },

    {
      -logic_name => 'load_taxonomy_info',
      -module     => 'Bio::EnsEMBL::Analysis::Hive::RunnableDB::HiveAssemblyLoading::HiveLoadTaxonomyInfo',
      -parameters => {
        'target_db'   => '#core_db#',
        'taxonomy_db' => $self->o('taxonomy_db'),
      },
      -rc_name => 'default',

      -flow_into => {
        1 => ['dump_toplevel_file'],    #['load_windowmasker_repeats'],# 'fan_refseq_import'],
      },
    },


    {
      -logic_name => 'dump_toplevel_file',
      -module     => 'Bio::EnsEMBL::Analysis::Hive::RunnableDB::HiveDumpGenome',
      -parameters => {
        'coord_system_name'  => 'toplevel',
        'target_db'          => '#core_db#',
        'output_path'        => '#output_path#',
        'enscode_root_dir'   => $self->o('enscode_root_dir'),
        'species_name'       => '#species_name#',
        'repeat_logic_names' => $self->o('softmask_logic_names'),    # This is emtpy as we just use masking present in downloaded file
      },
      -flow_into => {
        1 => ['reheader_toplevel_file'],
      },
      -rc_name => '3GB',
    },


    {
      -logic_name => 'reheader_toplevel_file',
      -module     => 'Bio::EnsEMBL::Hive::RunnableDB::SystemCmd',
      -parameters => {
        cmd => 'perl ' . catfile( $self->o('enscode_root_dir'), 'ensembl-analysis', 'scripts', 'genebuild', 'convert_genome_dump.pl' ) .
          ' -conversion_type slice_name_to_seq_region_name' .
          ' -input_file #toplevel_genome_file#' .
          ' -output_file #reheadered_toplevel_genome_file#',
      },
      -rc_name   => 'default',
      -flow_into => {
        1 => ['check_transcriptomic_data'],
      },
    },
    {
      -logic_name => 'check_transcriptomic_data',
      -module     => 'Bio::EnsEMBL::Hive::RunnableDB::SystemCmd',
      -parameters => {
        cmd                     => 'if [ -e "#rnaseq_summary_file#" ] || [ -e "#long_read_summary_file#" ]; then exit 0; else exit 42;fi',
        return_codes_2_branches => { '42' => 2 },
      },
      -flow_into => {
        1 => ['run_anno'],
        2 => ['run_anno_softmasking'],
      },
      -rc_name => 'default',
    },

    {
      -logic_name => 'run_anno',
      -module     => 'Bio::EnsEMBL::Hive::RunnableDB::SystemCmd',
      -parameters => {
         cmd => 'python ' . catfile( $self->o('enscode_root_dir'), 'ensembl-anno', 'ensembl_anno.py' ) . ' #anno_commandline#',
      },
      -rc_name         => 'anno',
      -max_retry_count => 0,
      -flow_into       => {
        1 => ['update_biotypes_and_analyses']
      },
    },
    {
      -logic_name => 'run_anno_softmasking',
      -module     => 'Bio::EnsEMBL::Hive::RunnableDB::SystemCmd',
      -parameters => {
        cmd => 'python ' . catfile( $self->o('enscode_root_dir'), 'ensembl-anno', 'ensembl_anno.py' ) . ' #anno_red_commandline#;' .
          'cp #output_path#/red_output/mask_output/#species_name#_reheadered_toplevel.msk #output_path#/#species_name#_softmasked_toplevel.fa',
      },
      -rc_name         => 'anno',
      -max_retry_count => 0,
      -flow_into       => {
        1 => ['run_braker_ep_mode'],
      },
    },
    {
      -logic_name => 'run_braker_ep_mode',
      -module     => 'Bio::EnsEMBL::Hive::RunnableDB::SystemCmd',
      -parameters => {
        cmd => 'mkdir #output_path#/prothint;' .
          'cd #output_path#/prothint;' .
          'singularity exec -H /hps/software/users/ensembl/genebuild/genebuild_virtual_user/singularity/data:/home --bind #output_path#/prothint/:/data:rw  ' . $self->o('braker_singularity_image') . ' prothint.py #output_path#/#species_name#_softmasked_toplevel.fa #protein_file# ;' .
          'cd #output_path#/;' .
      'sudo -u genebuild rm -rf ' . $self->o('augustus_config_path') . '/species/#assembly_accession#_#species_name#;' .
          'sudo -u genebuild singularity exec -H /hps/software/users/ensembl/genebuild/genebuild_virtual_user/singularity/data:/home --bind #output_path#/:/data:rw  ' . $self->o('braker_singularity_image') . ' braker.pl --genome=#species_name#_softmasked_toplevel.fa --softmasking  --hints=/data/prothint/prothint_augustus.gff --prothints=/data/prothint/prothint.gff --evidence=/data/prothint/evidence.gff --epmode --species=#assembly_accession#_#species_name# --AUGUSTUS_CONFIG_PATH=' . $self->o('augustus_config_path') . ' --cores ' . $self->o('cores') . ';' .
      'rm -rf #output_path#/prothint/diamond;' .
          'rm -rf #output_path#/prothint/GeneMark_ES;' .
          'rm -rf #output_path#/prothint/Spaln;' .
          'sudo -u genebuild rm -rf #output_path#/braker/GeneMark-EP;' ,
      },
      -rc_name         => '32GB',
      -max_retry_count => 0,
      -flow_into       => {
        1 => ['load_gtf_file'],
      },
    },
    {		   
      -logic_name => 'load_gtf_file',
      -module     => 'Bio::EnsEMBL::Hive::RunnableDB::SystemCmd',
      -parameters => {
        cmd => 'perl ' . catfile( $self->o('enscode_root_dir'), 'ensembl-analysis', 'scripts', 'genebuild', 'braker', 'parse_gtf.pl' ) .
          ' -dnahost ' . $self->o('dna_db_server') .
          ' -dnauser ' . $self->o('user_r') .
          ' -dnaport ' . $self->o('dna_db_port') .
          ' -dnadbname #core_dbname#' .
          ' -host ' . $self->o('dna_db_server') .
          ' -user ' . $self->o('user') .
          ' -pass ' . $self->o('password') .
          ' -port ' . $self->o('dna_db_port') .
          ' -dbname #core_dbname#' .
          ' -write' .
          ' -file #output_path#/braker/braker.gtf',
      },
      -rc_name         => 'default',
      -max_retry_count => 0,
      -flow_into       => {
        1 => ['update_biotypes_and_analyses'],
      },
    },
    {
      -logic_name => 'update_biotypes_and_analyses',
      -module     => 'Bio::EnsEMBL::Hive::RunnableDB::SqlCmd',
      -parameters => {
        db_conn => '#core_db#',
        sql     => [
          'UPDATE analysis SET module=NULL',
          'UPDATE gene SET biotype = "protein_coding" WHERE biotype = "anno_protein_coding"',
          'UPDATE gene SET biotype = "lncRNA" WHERE biotype = "anno_lncRNA"',
          'UPDATE transcript JOIN gene USING(gene_id) SET transcript.biotype = gene.biotype',
          'UPDATE transcript JOIN gene USING(gene_id) SET transcript.analysis_id = gene.analysis_id',
          'UPDATE repeat_feature SET repeat_start = 1 WHERE repeat_start < 1',
          'UPDATE repeat_feature SET repeat_end = 1 WHERE repeat_end < 1',
          'UPDATE repeat_feature JOIN seq_region USING(seq_region_id) SET seq_region_end = length WHERE seq_region_end > length',
          'UPDATE gene SET display_xref_id=NULL',
          'UPDATE transcript SET display_xref_id=NULL',
        ],
      },
      -rc_name   => 'default',
      -flow_into => {
        1 => ['delete_duplicate_genes'],
      },
    },

    {
      -logic_name => 'delete_duplicate_genes',
      -module     => 'Bio::EnsEMBL::Hive::RunnableDB::SystemCmd',
      -parameters => {
        cmd => 'perl ' . $self->o('remove_duplicates_script') .
          ' -dbuser ' . $self->o('user') .
          ' -dbpass ' . $self->o('password') .
          ' -dbhost ' . $self->o( 'core_db', '-host' ) .
          ' -dbport ' . $self->o( 'core_db', '-port' ) .
          ' -dbname ' . '#core_dbname#'
      },
      -rc_name   => '5GB',
      -flow_into => {
        1 => ['set_meta_coords'],
      },
    },

    {
      -logic_name => 'set_meta_coords',
      -module     => 'Bio::EnsEMBL::Hive::RunnableDB::SystemCmd',
      -parameters => {
        cmd => 'perl ' . $self->o('meta_coord_script') .
          ' -user ' . $self->o('user') .
          ' -pass ' . $self->o('password') .
          ' -host ' . $self->o( 'core_db', '-host' ) .
          ' -port ' . $self->o( 'core_db', '-port' ) .
          ' -dbpattern ' . '#core_dbname#'
      },
      -rc_name   => 'default',
      -flow_into => {
        1 => ['set_meta_levels'],
      },
    },

    {
      -logic_name => 'set_meta_levels',
      -module     => 'Bio::EnsEMBL::Hive::RunnableDB::SystemCmd',
      -parameters => {
        cmd => 'perl ' . $self->o('meta_levels_script') .
          ' -user ' . $self->o('user') .
          ' -pass ' . $self->o('password') .
          ' -host ' . $self->o( 'core_db', '-host' ) .
          ' -port ' . $self->o( 'core_db', '-port' ) .
          ' -dbname ' . '#core_dbname#'
      },
      -rc_name   => 'default',
      -flow_into => { 1 => ['set_frameshift_introns'] },
    },

    {
      -logic_name => 'set_frameshift_introns',
      -module     => 'Bio::EnsEMBL::Hive::RunnableDB::SystemCmd',
      -parameters => {
        cmd => 'perl ' . $self->o('frameshift_attrib_script') .
          ' -user ' . $self->o('user') .
          ' -pass ' . $self->o('password') .
          ' -host ' . $self->o( 'core_db', '-host' ) .
          ' -port ' . $self->o( 'core_db', '-port' ) .
          ' -dbpattern ' . '#core_dbname#'
      },
      -rc_name   => '10GB',
      -flow_into => { 1 => ['set_canonical_transcripts'] },
    },

    {
      -logic_name => 'set_canonical_transcripts',
      -module     => 'Bio::EnsEMBL::Hive::RunnableDB::SystemCmd',
      -parameters => {
        cmd => 'perl ' . $self->o('select_canonical_script') .
          ' -dbuser ' . $self->o('user') .
          ' -dbpass ' . $self->o('password') .
          ' -dbhost ' . $self->o( 'core_db', '-host' ) .
          ' -dbport ' . $self->o( 'core_db', '-port' ) .
          ' -dbname ' . '#core_dbname#' .
          ' -coord toplevel -write'
      },
      -rc_name   => '10GB',
      -flow_into => { 1 => ['null_columns'] },
    },

    {
      -logic_name => 'null_columns',
      -module     => 'Bio::EnsEMBL::Hive::RunnableDB::SqlCmd',
      -parameters => {
        db_conn => '#core_db#',
        sql     => [
          'UPDATE gene SET stable_id = NULL',
          'UPDATE transcript SET stable_id = NULL',
          'UPDATE translation SET stable_id = NULL',
          'UPDATE exon SET stable_id = NULL',
          'UPDATE protein_align_feature set external_db_id = NULL',
          'UPDATE dna_align_feature set external_db_id = NULL',
        ],
      },
      -rc_name   => 'default',
      -flow_into => {
        1 => ['check_run_stable_ids'],
      },
    },

    {
      -logic_name => 'check_run_stable_ids',
      -module     => 'Bio::EnsEMBL::Hive::RunnableDB::SystemCmd',
      -parameters => {
        cmd                     => 'if [ -e "#rnaseq_summary_file#" ] || [ -e "#long_read_summary_file#" ]; then exit 0; else  exit 42;fi',
        return_codes_2_branches => { '42' => 2 },
      },
      -flow_into => {
        1 => ['anno_run_stable_ids'],
        2 => ['braker_run_stable_ids'],
      },
      -rc_name => 'default',
    },
    {
      -logic_name => 'anno_run_stable_ids',
      -module     => 'Bio::EnsEMBL::Analysis::Hive::RunnableDB::SetStableIDs',
      -parameters => {
        enscode_root_dir => $self->o('enscode_root_dir'),
        mapping_required => 0,
        target_db        => '#core_db#',
        id_start         => '#stable_id_prefix#' . '#stable_id_start#',
        output_path      => '#output_path#',
      },
      -rc_name   => 'default',
      -flow_into => {
        1 => ['final_meta_updates'],
      },
    },
    {
      -logic_name => 'braker_run_stable_ids',
      -module     => 'Bio::EnsEMBL::Analysis::Hive::RunnableDB::SetStableIDs',
      -parameters => {
        enscode_root_dir => $self->o('enscode_root_dir'),
        mapping_required => 0,
        target_db        => '#core_db#',
        id_start         => 'BRAKER#species_prefix#' . '#stable_id_start#',
        output_path      => '#output_path#',
      },
      -rc_name   => 'default',
      -flow_into => {
        1 => ['final_meta_updates'],
      },
    },

    {
      -logic_name => 'final_meta_updates',
      -module     => 'Bio::EnsEMBL::Hive::RunnableDB::SqlCmd',
      -parameters => {
        db_conn => '#core_db#',
        sql     => [
          'INSERT IGNORE INTO meta (species_id, meta_key, meta_value) VALUES ' .
            '(1, "genebuild.last_geneset_update", (SELECT CONCAT((EXTRACT(YEAR FROM now())),"-",(LPAD(EXTRACT(MONTH FROM now()),2,"0")))))'
        ],
      },
      -rc_name   => 'default',
      -flow_into => {
        1 => ['final_cleaning'],
      },
    },

    {
      -logic_name => 'final_cleaning',
      -module     => 'Bio::EnsEMBL::Hive::RunnableDB::SqlCmd',
      -parameters => {
        db_conn => '#core_db#',
        sql     => [
          'TRUNCATE associated_xref',
          'TRUNCATE dependent_xref',
          'TRUNCATE identity_xref',
          'TRUNCATE object_xref',
          'TRUNCATE ontology_xref',
          'TRUNCATE xref',
	  'DELETE from meta where meta_key="species.strain_group"',
          'DELETE exon FROM exon LEFT JOIN exon_transcript ON exon.exon_id = exon_transcript.exon_id WHERE exon_transcript.exon_id IS NULL',
          'DELETE supporting_feature FROM supporting_feature LEFT JOIN exon ON supporting_feature.exon_id = exon.exon_id WHERE exon.exon_id IS NULL',
          'DELETE supporting_feature FROM supporting_feature LEFT JOIN dna_align_feature ON feature_id = dna_align_feature_id WHERE feature_type="dna_align_feature" AND dna_align_feature_id IS NULL',
          'DELETE supporting_feature FROM supporting_feature LEFT JOIN protein_align_feature ON feature_id = protein_align_feature_id WHERE feature_type="protein_align_feature" AND protein_align_feature_id IS NULL',
          'DELETE transcript_supporting_feature FROM transcript_supporting_feature LEFT JOIN dna_align_feature ON feature_id = dna_align_feature_id WHERE feature_type="dna_align_feature" AND dna_align_feature_id IS NULL',
          'DELETE transcript_supporting_feature FROM transcript_supporting_feature LEFT JOIN protein_align_feature ON feature_id = protein_align_feature_id WHERE feature_type="protein_align_feature" AND protein_align_feature_id IS NULL',
        ],
      },
      -rc_name   => 'default',
      -flow_into => {
        1 => ['add_placeholder_sample_location'],
      },

    },

    {
      -logic_name => 'add_placeholder_sample_location',
      -module     => 'Bio::EnsEMBL::Analysis::Hive::RunnableDB::HiveAddPlaceholderLocation',
      -parameters => {
        input_db => '#core_db#',
      },
      -rc_name   => 'default',
      -flow_into => {
        1 => ['populate_analysis_descriptions'],
      },
    },

    {
      -logic_name => 'populate_analysis_descriptions',
      -module     => 'Bio::EnsEMBL::Production::Pipeline::ProductionDBSync::PopulateAnalysisDescription',
      -parameters => {
        species => '#production_name#',
        group   => 'core',
      },
      -flow_into => {
        1 => ['run_busco_core_genome_mode'],
      },
      -rc_name => 'default_registry',
    },
    {
      -logic_name => 'run_busco_core_genome_mode',
      -module     => 'Bio::EnsEMBL::Hive::RunnableDB::SystemCmd',
      -parameters => {
        cmd => 'cd #output_path#; ' .
          'singularity exec ' . $self->o('busco_singularity_image') . ' busco -f -i #output_path#/#species_name#_reheadered_toplevel.fa  -m genome -l #busco_group# -c ' . $self->o('cores') . ' -o busco_core_genome_mode_output --offline --download_path ' . $self->o('busco_download_path') . ' ; ' .
          'rm -rf  #output_path#/busco_core_genome_mode_output/logs;' .
          'rm -rf  #output_path#/busco_core_genome_mode_output/busco_downloads;' .
          'rm -rf  #output_path#/busco_core_genome_mode_output/run*;' .
          'sed  -i "/genebuild/d"  #output_path#/busco_core_genome_mode_output/*.txt;' .
          'mv #output_path#/busco_core_genome_mode_output/*.txt #output_path#/busco_core_genome_mode_output/#species_strain_group#_genome_busco_short_summary.txt',
      },
      -rc_name   => '32GB',
      -flow_into => { 1 => ['fan_busco_output'] },
    },
    {
      -logic_name => 'fan_busco_output',
      -module     => 'Bio::EnsEMBL::Hive::RunnableDB::SystemCmd',
      -parameters => {
        #cmd                     => 'if '.$self->o('run_braker').'==1] ; then exit 0; else exit 42;fi',
        cmd                     => 'if [ -e "#rnaseq_summary_file#" ] || [ -e "#long_read_summary_file#" ]; then exit 0; else  exit 42;fi',
        return_codes_2_branches => { '42' => 2 },
      },
      -rc_name   => 'default',
      -flow_into => {
        1 => ['create_busco_dirs'],
        2 => ['run_agat_protein_file'],
      },
    },
    {
      -logic_name => 'run_agat_protein_file',
      -module     => 'Bio::EnsEMBL::Hive::RunnableDB::SystemCmd',

      -parameters => {
        cmd => 'sudo -u genebuild singularity exec --bind #output_path#/:/data:rw  ' . $self->o('agat_singularity_image') . ' agat_sp_extract_sequences.pl --gff /data/braker/braker.gtf -f  #output_path#/#species_name#_softmasked_toplevel.fa -p  -o  #output_path#/braker/braker_proteins.fa;',
      },
      -rc_name         => '32GB',
      -max_retry_count => 0,
      -flow_into       => {
        1 => ['run_busco_braker'],
      },
    },
    {
      -logic_name => 'run_busco_braker',
      -module     => 'Bio::EnsEMBL::Hive::RunnableDB::SystemCmd',

      -parameters => {
        cmd => 'cd #output_path#/;' .
          'singularity exec ' . $self->o('busco_singularity_image') . ' busco -f -i #output_path#/braker/braker_proteins.fa  -m prot -l #busco_group# -c ' . $self->o('cores') . ' -o busco_core_protein_mode_output --offline --download_path ' . $self->o('busco_download_path') . ' ; ' .
	  'rm -rf  #output_path#/busco_core_protein_mode_output/logs;' .
	  'rm -rf  #output_path#/busco_core_protein_mode_output/busco_downloads;' .
	  'rm -rf  #output_path#/busco_core_protein_mode_output/run*;' .
	  'sed  -i "/genebuild/d"  #output_path#/busco_core_protein_mode_output/*.txt;' .
	  'mv #output_path#/busco_core_protein_mode_output/*.txt #output_path#/busco_core_protein_mode_output/#species_strain_group#_busco_short_summary.txt;',
      },
      -rc_name   => '32GB',
      -flow_into => {
        1 => ['update_assembly_registry_status'],
      },
    },
    {
      -logic_name => 'create_busco_dirs',
      -module     => 'Bio::EnsEMBL::Hive::RunnableDB::SystemCmd',
      -parameters => {
        cmd => 'mkdir -p #output_path#' . '/busco_score_data',
      },
      -rc_name   => 'default',
      -flow_into => {
        1 => ['dump_canonical_stable_ids'],
      },
    },

    {
      -logic_name => 'dump_canonical_stable_ids',
      -module     => 'Bio::EnsEMBL::Hive::RunnableDB::DbCmd',
      -parameters => {
        db_conn     => '#core_db#',
        input_query => 'SELECT transcript.stable_id from gene, transcript ' .
          ' WHERE gene.gene_id = transcript.gene_id ' .
          ' AND gene.canonical_transcript_id = transcript.transcript_id ' .
          ' AND transcript.biotype = "protein_coding" ',
        command_out        => q( grep 'ENS' > #busco_input_file_m#),
        busco_input_file_m => catfile( '#output_path#', '/busco_score_data/', $self->o('busco_input_file_stid') ),
        prepend            => [ '-NB', '-q' ],
      },
      -rc_name   => '2GB',
      -flow_into => {
        1 => ['print_translations'],
      },
    },

    {
      -logic_name => 'print_translations',
      -module     => 'Bio::EnsEMBL::Hive::RunnableDB::SystemCmd',
      -parameters => {
        cmd => 'perl ' . $self->o('print_protein_script_path') .
          ' --user=' . $self->o('user_r') .
          ' --host=' . $self->o( 'core_db', '-host' ) .
          ' --port=' . $self->o( 'core_db', '-port' ) .
          ' --dbname=' . '#core_dbname#' .
          ' --id_file=' . catfile( '#output_path#', '/busco_score_data/', $self->o('busco_input_file_stid') ) .
          ' --output_file=' . catfile( '#output_path#', '/busco_score_data/', 'canonical_proteins.fa' ),
      },
      -rc_name   => 'default',
      -flow_into => { 1 => ['run_busco_anno'] },
    },

    {
      -logic_name => 'run_busco_anno',
      -module     => 'Bio::EnsEMBL::Hive::RunnableDB::SystemCmd',
      -parameters => {
        cmd => 'cd #output_path#; ' .
	  'singularity exec ' . $self->o('busco_singularity_image') . ' busco -f -i #output_path#/busco_score_data/canonical_proteins.fa  -m prot -l #busco_group# -c ' . $self->o('cores') . ' -o busco_core_protein_mode_output --offline --download_path ' . $self->o('busco_download_path') . ' ; ' .
	  'rm -rf  #output_path#/busco_core_protein_mode_output/logs;' .
          'rm -rf  #output_path#/busco_core_protein_mode_output/busco_downloads;' .
          'rm -rf  #output_path#/busco_core_protein_mode_output/run*;' .
          'sed  -i "/genebuild/d"  #output_path#/busco_core_protein_mode_output/*.txt;' .
	  'mv #output_path#/busco_core_protein_mode_output/*.txt #output_path#/busco_core_protein_mode_output/#species_strain_group#_busco_short_summary.txt',
      },
      -rc_name   => '32GB',
      -flow_into => { 1 => ['fan_otherfeatures_db'] },
    },
    {
      -logic_name => 'fan_otherfeatures_db',
      -module     => 'Bio::EnsEMBL::Hive::RunnableDB::SystemCmd',
      -parameters => {
        cmd                     => 'if [ -e "#rnaseq_summary_file#" ] || [ -e "#long_read_summary_file#" ]; then exit 0; else  exit 42;fi',
        return_codes_2_branches => { '42' => 2 },
      },
      -flow_into => {
        1 => ['create_otherfeatures_db'],

        2 => ['update_assembly_registry_status'],
      },
      -rc_name => 'default',
    },
    {
      # Creates a reference db for each species
      -logic_name => 'create_otherfeatures_db',
      -module     => 'Bio::EnsEMBL::Analysis::Hive::RunnableDB::HiveCreateDatabase',
      -parameters => {
        'source_db'        => '#core_db#',
        'target_db'        => '#otherfeatures_db#',
        'enscode_root_dir' => $self->o('enscode_root_dir'),
        'create_type'      => 'clone',
      },
      -rc_name => 'default',

      -flow_into => {
        1 => ['update_otherfeatures_db'],
      },
    },
        {
      -logic_name => 'update_otherfeatures_db',
      -module     => 'Bio::EnsEMBL::Hive::RunnableDB::SqlCmd',
      -parameters => {
        db_conn => '#otherfeatures_db#',
        sql     => [
                #          'DELETE FROM analysis_description WHERE analysis_id IN (SELECT analysis_id FROM analysis WHERE logic_name IN' .
                # ' ("dust","repeatdetector","trf","cpg","eponine"))',
                #'DELETE FROM analysis WHERE logic_name IN' .
                # ' ("dust","repeatdetector","trf","cpg","eponine")',
          'TRUNCATE analysis',
          'TRUNCATE analysis_description',
          'DELETE FROM meta WHERE meta_key LIKE "%.level"',
          'DELETE FROM meta WHERE meta_key LIKE "sample.%"',
          'DELETE FROM meta WHERE meta_key LIKE "assembly.web_accession%"',
          'DELETE FROM meta WHERE meta_key LIKE "removed_evidence_flag.%"',
          'DELETE FROM meta WHERE meta_key LIKE "marker.%"',
          'DELETE FROM meta WHERE meta_key LIKE "genebuild.method_display"',
          'DELETE FROM meta WHERE meta_key IN' .
            ' ("repeat.analysis","genebuild.method","genebuild.last_geneset_update","genebuild.projection_source_db","genebuild.start_date","species.strain_group")',
          'INSERT INTO meta (species_id,meta_key,meta_value) VALUES (1,"genebuild.last_otherfeatures_update",NOW())',
          'UPDATE meta set meta_value="#stable_id_prefix#" where meta_key="species.stable_id_prefix"',
          'UPDATE transcript JOIN transcript_supporting_feature USING(transcript_id)'.
              ' JOIN dna_align_feature ON feature_id = dna_align_feature_id SET stable_id = hit_name',
      ],
      },
      -rc_name   => 'default',
      -flow_into => {
        1 => ['populate_production_tables_otherfeatures'],
      },
    },
    {
      # Load production tables into each reference
      -logic_name => 'populate_production_tables_otherfeatures',
      -module     => 'Bio::EnsEMBL::Analysis::Hive::RunnableDB::HiveAssemblyLoading::HivePopulateProductionTables',
      -parameters => {
        'target_db'        => '#otherfeatures_db#',
        'output_path'      => '#output_path#',
        'enscode_root_dir' => $self->o('enscode_root_dir'),
        'production_db'    => $self->o('production_db'),
      },
      -rc_name => 'default',

      -flow_into => {
        1 => ['run_braker_ep_mode_otherfeatures'],
      },
    },
    {
      -logic_name => 'run_braker_ep_mode_otherfeatures',
      -module     => 'Bio::EnsEMBL::Hive::RunnableDB::SystemCmd',

      -parameters => {
        cmd => 'cp #output_path#/red_output/mask_output/#species_name#_reheadered_toplevel.msk #output_path#/#species_name#_softmasked_toplevel.fa;' .
          'mkdir #output_path#/prothint;' .
          'cd #output_path#/prothint;' .
          'singularity exec -H /hps/software/users/ensembl/genebuild/genebuild_virtual_user/singularity/data:/home --bind #output_path#/prothint/:/data:rw  ' . $self->o('braker_singularity_image') . ' prothint.py #output_path#/#species_name#_softmasked_toplevel.fa #protein_file# ;' .
          'cd #output_path#/;' .
	  'sudo -u genebuild rm -rf ' . $self->o('augustus_config_path') . '/species/#assembly_accession#_#species_name#;' .
          'sudo -u genebuild singularity exec -H /hps/software/users/ensembl/genebuild/genebuild_virtual_user/singularity/data:/home --bind #output_path#/:/data:rw  ' . $self->o('braker_singularity_image') . ' braker.pl --genome=#species_name#_softmasked_toplevel.fa --softmasking  --hints=/data/prothint/prothint_augustus.gff --prothints=/data/prothint/prothint.gff --evidence=/data/prothint/evidence.gff --epmode --species=#assembly_accession#_#species_name# --AUGUSTUS_CONFIG_PATH=' . $self->o('augustus_config_path') . ' --cores ' . $self->o('cores') . ';' .
	  'rm -rf #output_path#/prothint/diamond;' .
	  'rm -rf #output_path#/prothint/GeneMark_ES;' .
	  'rm -rf #output_path#/prothint/Spaln;' .
	  'sudo -u genebuild rm -rf #output_path#/braker/GeneMark-EP;' ,
      },
      -rc_name         => '32GB',
      -max_retry_count => 0,
      -flow_into       => {
        1 => ['load_gtf_file_in_otherfeatures_db'],
      },
    },
    {
      -logic_name => 'load_gtf_file_in_otherfeatures_db',
      -module     => 'Bio::EnsEMBL::Hive::RunnableDB::SystemCmd',

      -parameters => {
        cmd => 'perl ' . catfile( $self->o('enscode_root_dir'), 'ensembl-analysis', 'scripts', 'genebuild', 'braker', 'parse_gtf.pl' ) .
          ' -dnahost ' . $self->o('otherfeatures_db_host') .
          ' -dnauser ' . $self->o('user_r') .
          ' -dnaport ' . $self->o('otherfeatures_db_port') .
          ' -dnadbname #otherfeatures_dbname#' .
          ' -host ' . $self->o('otherfeatures_db_host') .
          ' -user ' . $self->o('user') .
          ' -pass ' . $self->o('password') .
          ' -port ' . $self->o('otherfeatures_db_port') .
          ' -dbname #otherfeatures_dbname#' .
          ' -write' .
          ' -file #output_path#/braker/braker.gtf',
      },
      -rc_name         => 'default',
      -max_retry_count => 0,
      -flow_into       => {
        1 => ['otherfeatures_set_meta_coords'],
      },
    },
    {
      -logic_name => 'otherfeatures_set_meta_coords',
      -module     => 'Bio::EnsEMBL::Hive::RunnableDB::SystemCmd',
      -parameters => {
        cmd => 'perl ' . $self->o('meta_coord_script') .
          ' -user ' . $self->o('user') .
          ' -pass ' . $self->o('password') .
          ' -host ' . $self->o( 'otherfeatures_db', '-host' ) .
          ' -port ' . $self->o( 'otherfeatures_db', '-port' ) .
          ' -dbpattern ' . '#otherfeatures_dbname#'
      },
      -rc_name   => 'default',
      -flow_into => {
        1 => ['otherfeatures_set_meta_levels'],
      },
    },

    {
      -logic_name => 'otherfeatures_set_meta_levels',
      -module     => 'Bio::EnsEMBL::Hive::RunnableDB::SystemCmd',
      -parameters => {
        cmd => 'perl ' . $self->o('meta_levels_script') .
          ' -user ' . $self->o('user') .
          ' -pass ' . $self->o('password') .
          ' -host ' . $self->o( 'otherfeatures_db', '-host' ) .
          ' -port ' . $self->o( 'otherfeatures_db', '-port' ) .
          ' -dbname ' . '#otherfeatures_dbname#'
      },
      -rc_name   => 'default',
      -flow_into => { 1 => ['otherfeatures_set_frameshift_introns'] },
    },

    {
      -logic_name => 'otherfeatures_set_frameshift_introns',
      -module     => 'Bio::EnsEMBL::Hive::RunnableDB::SystemCmd',
      -parameters => {
        cmd => 'perl ' . $self->o('frameshift_attrib_script') .
          ' -user ' . $self->o('user') .
          ' -pass ' . $self->o('password') .
          ' -host ' . $self->o( 'otherfeatures_db', '-host' ) .
          ' -port ' . $self->o( 'otherfeatures_db', '-port' ) .
          ' -dbpattern ' . '#otherfeatures_dbname#'
      },
      -rc_name   => '10GB',
      -flow_into => { 1 => ['otherfeatures_set_canonical_transcripts'] },
    },
    {
      -logic_name => 'otherfeatures_set_canonical_transcripts',
      -module     => 'Bio::EnsEMBL::Hive::RunnableDB::SystemCmd',
      -parameters => {
        cmd => 'perl ' . $self->o('select_canonical_script') .
          ' -dbuser ' . $self->o('user') .
          ' -dbpass ' . $self->o('password') .
          ' -dbhost ' . $self->o( 'otherfeatures_db', '-host' ) .
          ' -dbport ' . $self->o( 'otherfeatures_db', '-port' ) .
          ' -dbname ' . '#otherfeatures_dbname#' .
          ' -dnadbuser ' . $self->o('user_r') .
          ' -dnadbhost ' . $self->o( 'core_db', '-host' ) .
          ' -dnadbport ' . $self->o( 'core_db', '-port' ) .
          ' -dnadbname ' . '#core_dbname#' .
          ' -coord toplevel -write'
      },
      -rc_name   => '10GB',
      -flow_into => { 1 => ['otherfeatures_null_columns'] },
    },

    {
      -logic_name => 'otherfeatures_null_columns',
      -module     => 'Bio::EnsEMBL::Hive::RunnableDB::SqlCmd',
      -parameters => {
        db_conn => '#otherfeatures_db#',
        sql     => [
		'UPDATE gene SET stable_id = NULL',
		'UPDATE transcript SET stable_id = NULL',
		'UPDATE translation SET stable_id = NULL',
		'UPDATE exon SET stable_id = NULL',
		'UPDATE protein_align_feature set external_db_id = NULL',
          'UPDATE dna_align_feature set external_db_id = NULL',
        ],
      },
      -rc_name   => 'default',
      -flow_into => {
        1 => ['otherfeatures_braker_run_stable_ids'],
      },
    },

    {
      -logic_name => 'otherfeatures_braker_run_stable_ids',
      -module     => 'Bio::EnsEMBL::Analysis::Hive::RunnableDB::SetStableIDs',
      -parameters => {
        enscode_root_dir => $self->o('enscode_root_dir'),
        mapping_required => 0,
        target_db        => '#otherfeatures_db#',
        id_start         => '#stable_id_prefix#' . '#stable_id_start#',
        output_path      => '#output_path#',
      },
      -rc_name   => 'default',
      -flow_into => {
        1 => ['load_external_db_ids_and_optimise_otherfeatures'],
      },
    },
    {
      -logic_name => 'load_external_db_ids_and_optimise_otherfeatures',
      -module     => 'Bio::EnsEMBL::Hive::RunnableDB::SystemCmd',
      -parameters => {
        cmd => 'perl ' . $self->o('load_optimise_script') .
          ' -output_path ' . catdir( '#output_path#', 'optimise_otherfeatures' ) .
          ' -uniprot_filename ' . $self->o('protein_entry_loc') .
          ' -dbuser ' . $self->o('user') .
          ' -dbpass ' . $self->o('password') .
          ' -dbport ' . $self->o( 'otherfeatures_db', '-port' ) .
          ' -dbhost ' . $self->o( 'otherfeatures_db', '-host' ) .
          ' -dbname ' . '#otherfeatures_dbname#' .
          ' -prod_dbuser ' . $self->o('user_r') .
          ' -prod_dbhost ' . $self->o( 'production_db', '-host' ) .
          ' -prod_dbname ' . $self->o( 'production_db', '-dbname' ) .
          ' -prod_dbport ' . $self->o( 'production_db', '-port' ) .
          ' -verbose'
      },
      -max_retry_count => 0,
      -rc_name         => '4GB',
      -flow_into       => {
        1 => ['otherfeatures_final_cleaning'],
      },
    },

    {
      -logic_name => 'otherfeatures_final_cleaning',
      -module     => 'Bio::EnsEMBL::Hive::RunnableDB::SqlCmd',
      -parameters => {
        db_conn => '#otherfeatures_db#',
        sql     => [
          'TRUNCATE associated_xref',
          'TRUNCATE dependent_xref',
          'TRUNCATE identity_xref',
          'TRUNCATE object_xref',
          'TRUNCATE ontology_xref',
          'TRUNCATE xref',
          'DELETE exon FROM exon LEFT JOIN exon_transcript ON exon.exon_id = exon_transcript.exon_id WHERE exon_transcript.exon_id IS NULL',
          'DELETE supporting_feature FROM supporting_feature LEFT JOIN exon ON supporting_feature.exon_id = exon.exon_id WHERE exon.exon_id IS NULL',
          'DELETE supporting_feature FROM supporting_feature LEFT JOIN dna_align_feature ON feature_id = dna_align_feature_id WHERE feature_type="dna_align_feature" AND dna_align_feature_id IS NULL',
          'DELETE supporting_feature FROM supporting_feature LEFT JOIN protein_align_feature ON feature_id = protein_align_feature_id WHERE feature_type="protein_align_feature" AND protein_align_feature_id IS NULL',
          'DELETE transcript_supporting_feature FROM transcript_supporting_feature LEFT JOIN dna_align_feature ON feature_id = dna_align_feature_id WHERE feature_type="dna_align_feature" AND dna_align_feature_id IS NULL',
          'DELETE transcript_supporting_feature FROM transcript_supporting_feature LEFT JOIN protein_align_feature ON feature_id = protein_align_feature_id WHERE feature_type="protein_align_feature" AND protein_align_feature_id IS NULL',
        ],
      },
      -rc_name   => 'default',
      -flow_into => {
        1 => ['otherfeatures_populate_analysis_descriptions'],
      },

    },

    {
      -logic_name => 'otherfeatures_populate_analysis_descriptions',
      -module     => 'Bio::EnsEMBL::Production::Pipeline::ProductionDBSync::PopulateAnalysisDescription',
      -parameters => {
        species => '#production_name#',
        group   => 'otherfeatures',
      },
      -flow_into => {
        1 => ['run_agat_protein_file_otherfeatures'],
      },
      -rc_name => 'default_registry',
    },
    {
      -logic_name => 'run_agat_protein_file_otherfeatures',
      -module     => 'Bio::EnsEMBL::Hive::RunnableDB::SystemCmd',

      -parameters => {
        cmd => 'sudo -u genebuild singularity exec --bind #output_path#/:/data:rw  ' . $self->o('agat_singularity_image') . ' agat_sp_extract_sequences.pl --gff /data/braker/braker.gtf -f  #output_path#/#species_name#_softmasked_toplevel.fa -p  -o  #output_path#/braker/braker_proteins.fa;',
      },
      -rc_name         => '32GB',
      -max_retry_count => 0,
      -flow_into       => {
        1 => ['run_busco_braker_otherfeatures'],
      },
    },
    {
      -logic_name => 'run_busco_braker_otherfeatures',
      -module     => 'Bio::EnsEMBL::Hive::RunnableDB::SystemCmd',

      -parameters => {
        cmd => 'cd #output_path#/;' .
          'singularity exec ' . $self->o('busco_singularity_image') . ' busco -f -i #output_path#/braker/braker_proteins.fa  -m prot -l #busco_group# -c ' . $self->o('cores') . ' -o busco_otherfeatures_protein_mode_output --offline --download_path ' . $self->o('busco_download_path') . ' ; ' .
	  'rm -rf  #output_path#/busco_otherfeatures_protein_mode_output/logs;' .
          'rm -rf  #output_path#/busco_otherfeatures_protein_mode_output/busco_downloads;' .
          'rm -rf  #output_path#/busco_otherfeatures_protein_mode_output/run*;' .
	  'sed  -i "/genebuild/d"  #output_path#/busco_otherfeatures_protein_mode_output/*.txt;' .
	  'mv #output_path#/busco_otherfeatures_protein_mode_output/*.txt #output_path#/busco_otherfeatures_protein_mode_output/#species_strain_group#_busco_short_summary.txt;',
      },
      -rc_name   => '32GB',
      -flow_into => {
        1 => ['otherfeatures_sanity_checks'],
      },
    },
    {
      -logic_name => 'otherfeatures_sanity_checks',
      -module     => 'Bio::EnsEMBL::Analysis::Hive::RunnableDB::HiveAnalysisSanityCheck',
      -parameters => {
        target_db                  => '#otherfeatures_db#',
        sanity_check_type          => 'gene_db_checks',
        min_allowed_feature_counts => get_analysis_settings( 'Bio::EnsEMBL::Analysis::Hive::Config::SanityChecksStatic',
          'gene_db_checks' )->{'otherfeatures'},
      },
      -rc_name   => '4GB',
      -flow_into => {
        1 => ['otherfeatures_healthchecks'],
      },
    },

    {
      -logic_name => 'otherfeatures_healthchecks',
      -module     => 'Bio::EnsEMBL::Analysis::Hive::RunnableDB::HiveHealthcheck',
      -parameters => {
        input_db => '#otherfeatures_db#',
        species  => '#species_name#',
        group    => 'otherfeatures_handover',
      },
      -max_retry_count => 0,
      -rc_name         => '4GB',
      -flow_into       => { 1 => ['update_assembly_registry_status'], },
    },
    {
      -logic_name => 'update_assembly_registry_status',
      -module     => 'Bio::EnsEMBL::Hive::RunnableDB::SystemCmd',
      -parameters => {
        cmd => 'perl ' . $self->o('registry_status_update_script') .
          ' -user ' . $self->o('user') .
          ' -pass ' . $self->o('password') .
          ' -assembly_accession ' . '#assembly_accession#' .
          ' -registry_host ' . $self->o('registry_db_server') .
          ' -registry_port ' . $self->o('registry_db_port') .
          ' -registry_db ' . $self->o('registry_db_name'),
      },
      -rc_name => 'default',
      -flow_into       => { 1 => ['delete_short_reads'], },

    },
     {
      -logic_name => 'delete_short_reads',
      -module => 'Bio::EnsEMBL::Hive::RunnableDB::SystemCmd',
      -parameters => {
        cmd => 'if [ -f ' . '#short_read_dir#' . '/*.gz ]; then rm ' . '#short_read_dir#' . '/*.gz; fi',
      },
      -rc_name => 'default',
      -flow_into       => { 1 => ['delete_long_reads'], },
      },
     {
      -logic_name => 'delete_long_reads',
       -module => 'Bio::EnsEMBL::Hive::RunnableDB::SystemCmd',
       -parameters => {
         cmd => 'if [ -f ' . '#long_read_dir#' . '/* ]; then rm ' . '#long_read_dir#' . '/*; fi',
       },
       -rc_name => 'default',
     },
  ];
}

sub resource_classes {
  my $self = shift;

  return {
    #inherit other stuff from the base class
     %{ $self->SUPER::resource_classes() },
     'anno'             => {
     LSF => $self->lsf_resource_builder( 'production', 50000, [ $self->default_options->{'pipe_db_server'}, $self->default_options->{'dna_db_server'} ], [ $self->default_options->{'num_tokens'} ], $self->default_options->{'num_threads'} ),
     SLURM =>  $self->slurm_resource_builder(50000, '7-00:00:00', $self->default_options->{'num_threads'} ),
     },
    '32GB'           => {
     LSF => $self->lsf_resource_builder( 'production', 32000, [ $self->default_options->{'pipe_db_server'}, $self->default_options->{'dna_db_server'} ], [ $self->default_options->{'num_tokens'} ], $self->default_options->{'cores'} ),
     SLURM =>  $self->slurm_resource_builder(32000, '7-00:00:00',  $self->default_options->{'cores'} ),
    },
    };
    }

sub hive_capacity_classes {
  my $self = shift;

  return {
    'hc_low'    => 200,
    'hc_medium' => 500,
    'hc_high'   => 1000,
  };
}

sub check_file_in_ensembl {
  my ( $self, $file_path ) = @_;
  push @{ $self->{'_ensembl_file_paths'} }, $file_path;
  return $self->o('enscode_root_dir') . '/' . $file_path;
}

1;
