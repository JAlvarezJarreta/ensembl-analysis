#!/usr/bin/env python3

# See the NOTICE file distributed with this work for additional information
# regarding copyright ownership.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
"""
Create a config file to fit a given database.
Example:
    $ python create_config.py -b <basedir> -s <species> 
"""

from argparse import ArgumentParser
from pathlib import Path

# inport the variables
parser = ArgumentParser()
parser.add_argument("-b", "--basedir", required=True,
        help="path to the working directory")
parser.add_argument("-s", "--species", required=True,
        help="binomial name separated by an underscore (_), e.g. Homo_sapiens")
parser.add_argument("-t", "--srchost", required=True,
        help="mysql server for the old database (to map from)")
parser.add_argument("-p", "--srcport", required=True,
        help="mysql port for the old database (to map from)")
parser.add_argument("-n", "--srcname", required=True,
        help="name of the old database (to map from)")
parser.add_argument("-T", "--trghost", required=True,
        help="mysql server for the new database (to map to)")
parser.add_argument("-P", "--trgport", required=True,
        help="mysql port for the new database (to map to)")
parser.add_argument("-N", "--trgname", required=True,
        help="name of the new database (to map to)")

args = parser.parse_args()

# read the template
with open("template.pm") as file :
    configuration = file.read()

# update values
    configuration = configuration.replace("__BASEDIR__", args.basedir)
    configuration = configuration.replace("__SPECIES__", args.species)
    configuration = configuration.replace("__SRCHOST__", args.srchost)
    configuration = configuration.replace("__SRCPORT__", args.srcport)
    configuration = configuration.replace("__SRCNAME__", args.srcname)
    configuration = configuration.replace("__TRGHOST__", args.trghost)
    configuration = configuration.replace("__TRGPORT__", args.trgport)
    configuration = configuration.replace("__TRGNAME__", args.trgname)

# write the configuration file
outpath = Path(args.basedir)
filename = args.species+'_mapping.conf'
outfile = outpath / filename
with open(outfile, "w") as file:
    file.write(configuration)
