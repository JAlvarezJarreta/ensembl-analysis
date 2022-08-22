// Declare syntax version
nextflow.enable.dsl=2
// Script parameters
params.dbname = "jose_testing_to_be_dropped"
params.dbhost = "mysql-ens-genebuild-prod-6"
params.dbport = "4532"

process check_db {
	output:
	stdout

	"""
	mysql -h ${params.dbhost} -P ${params.dbport} -u ensro ${params.dbname} -e "select * from testudines where test_id = 2"
	mysql -h ${params.dbhost} -P ${params.dbport} -u ensadmin -pensembl ${params.dbname} -e "update testudines set land = 'no' where name = 'painted'"
	echo "editing..."
	mysql -h ${params.dbhost} -P ${params.dbport} -u ensro ${params.dbname} -e "select * from testudines where test_id = 2"
	"""
}

process check_db_2 {	
	output:
	stdout

	"""
	mysql -h ${params.dbhost} -P ${params.dbport} -u ensro ${params.dbname} -e "select * from testudines where test_id = 2"
	"""
}

process edit_db {
	"""
	mysql -h ${params.dbhost} -P ${params.dbport} -u ensadmin -pensembl ${params.dbname} -e "update testudines set land = 'yes' where name = 'painted'"
	"""
}

workflow {
	check_db() | view
}
