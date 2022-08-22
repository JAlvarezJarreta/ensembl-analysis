#!/usr/bin/env nextflow
/* See the NOTICE file distributed with this work for additional information
 * regarding copyright ownership.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

dbhost.str = 'mysql-ens-genebuild-prod-1'
dbport.str = '4527'
sthost.str = ''
stport.str = 

process ids_to_null {
  	input:
  	  	//

  	output:
  	 	stdout

  	"""
  	mysql -h ${dbhost.str} -P ${dbport.str} -u ensadmin -pensembl ${dbname} -e "UPDATE gene_stable_id SET stable_id=NULL;"
  	mysql -h ${dbhost.str} -P ${dbport.str} -u ensadmin -pensembl ${dbname} -e "UPDATE transcript_stable_id SET stable_id=NULL;"
  	mysql -h ${dbhost.str} -P ${dbport.str} -u ensadmin -pensembl ${dbname} -e "UPDATE translation_stable_id SET stable_id=NULL;"
  	mysql -h ${dbhost.str} -P ${dbport.str} -u ensadmin -pensembl ${dbname} -e "UPDATE exon_stable_id SET stable_id=NULL;"
  	"""
}

process create_config{
  	input:
  	  	//

  	output:
  	  	//

  	"""
  	//
  	"""
}

process run_config{
	input:
		//

	output:
		//


	"""
	//
	"""
}

workflow {
	ids_to_null($dbname) | view
	*add stopper
	create_config | run_config
}
