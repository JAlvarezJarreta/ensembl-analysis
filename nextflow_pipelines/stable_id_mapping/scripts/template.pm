;; for dry runs, no data is written to the database
dry_run = 0

;; log level, useful values are 'INFO' or 'DEBUG'
loglevel = DEBUG

;; paths
basedir = __BASEDIR__

;; URL prefix for navigation
urlprefix   = http://www.ensembl.org/__SPECIES__/Gene/Summary?g=

;; old/source database settings
sourcehost                  = __SRCHOST__
sourceport                  = __SRCPORT__
sourceuser                  = ensro
sourcedbname                = __SRCNAME__

;; new/target database settings
targethost                  = __TRGHOST__
targetport                  = __TRGPORT__
targetuser                  = ensadmin
targetpass                  = ensembl
targetdbname                = __TRGNAME__

;; the production database
productionhost                  = mysql-ens-sta-1.ebi.ac.uk
productionport                  = 4519
productionuser                  = ensro
productiondbname                = ensembl_production

;; caching
;cache_method                = build_cache_all
build_cache_auto_threshold  = 2000
build_cache_concurrent_jobs = 25

;; include only some biotypes
;biotypes_include=protein_coding,pseudogene,retrotransposed
;; alternatively, exclude some biotypes
;biotypes_exclude=protein_coding,pseudogene,retrotransposed

;; LSF parameters
lsf_opt_run_small           = "-q production "
lsf_opt_run                 = "-q production -We 90 -M12000 -R 'select[mem>12000]' -R  'rusage[mem=12000]'"
lsf_opt_dump_cache          = "-q production -We 5 -M4000 -R 'select[mem>4000]'  -R 'rusage[mem=4000]'"

transcript_score_threshold  = 0.25
gene_score_threshold        = 0.125

;; Exonerate
min_exon_length             = 15
exonerate_path              = /hps/software/users/ensembl/ensw/C8-MAR21-sandybridge/linuxbrew/bin/exonerate
exonerate_bytes_per_job     = 2500000
exonerate_concurrent_jobs   = 200
exonerate_threshold         = 0.5
exonerate_extra_params      = '--bestn 100'
lsf_opt_exonerate           = "-q production -We 10 -M8000 -R 'select[mem>8000]' -R 'rusage[mem=8000]'"

synteny_rescore_jobs        = 20
lsf_opt_synteny_rescore     = "-q production -We 10 -M8000 -R 'select[mem>8000]' -R  'rusage[mem=8000]'"

;; StableIdMapper
mapping_types               = gene,transcript,translation,exon

;; upload results into db
upload_events               = 1
upload_stable_ids           = 1
upload_archive              = 1
