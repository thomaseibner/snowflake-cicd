# snowflake-cicd

## Overview

Sample code for generating delta sql that can be used with a CI/CD pipeline in Snowflake. 

## Table of Contents

1. [Overview](#overview)
1. [Description](#description)
   1. [Input from GIT](#input-from-git)
   1. [Sample Code](#sample-code)
   1. [Other features in the Perl Module](#other-features-in-the-perl-module)
   1. [Configuration](#configuration)
   1. [Dependencies](#dependencies)
1. [Author](#author)
1. [License](#license)

## Description 

The sample code and perl module is a simple example of how you can turn a
declarative-style repository of individual objects under git source control into a
delta pipeline of changes as required by tools such as
[schemachange](https://github.com/Snowflake-Labs/schemachange)/Formerly Snowchange:
[Snowchange](https://jeremiahhansen.medium.com/snowchange-a-database-change-management-tool-b9f0b786a7da)

### Input from GIT

The module and sample script takes an input file of the changes from GIT as well as a
`git archive` tar.gz file from the current version and prior version to facilitate fully
reloading objects like stored procedures and functions where the parameters could have
changed. The same way you can generate the update pipeline to deploy it can also produce
files for rolling back changes. 

Included in the sample code is a Makefile which will create a sample repository with change
files that creates sample input files through a git [post-merge-hook](git-post-merge-hook).

### Sample Code

```

#!/usr/bin/perl

use lib '.';
use SnowflakeCICD;
use Data::Dumper;

my $git_output_file = shift || die "Need to provide a git metadata file";

my $cicd = SnowflakeCICD->new($git_output_file);
# Parses the output of the git file and loads an Archive::Tar
# object for each of the files in the current branch (update) and
# previous version of the branch (rollback)
foreach my $file ($cicd->changed_files()) {
    # Handle each file separately
    print $file, "\n";
}
foreach my $path ($cicd->changed_paths()) {
    # Or handle each file by path
    # Write $path metadata for your output file
    foreach my $file ($cicd->changed_files_by_path($path)) {
	print $file, "\n";
	# Now process each diff
    }
}
```
### Other features in the Perl Module

Along with parsing the `git` archives the Perl Module also offers a some handy regular expressions to extract
the object types, names, column types, etc with.

```
$cicd->ddl->name_pat can be used directly to extract a valid name per the Snowflake documentation
$cicd->ddl->type_pat


```

### Configuration

To easily change the configuration of which branches to use for your sample code edit the top of the `Makefile`:

```
LOCALBRANCH := local-dev
BRANCHES := dev tst
MASTERBRANCH := prd
```

Alternatively you can provide the options on the `make` command line.

### Dependencies

Perl 5.6+ with Archive::Tar module

Included sample git-repo processing has a dependency on git >= 2.28 for `git init -b master`

To install on your variety of Linux:

sudo add-apt-repository -y ppa:git-core/ppa

sudo apt update

sudo apt install git -y

## Author

Thomas Eibner (@thomaseibner) [twitter](http://twitter.com/thomaseibner) [LinkedIn](https://www.linkedin.com/in/thomaseibner/)

## License

Licensed under the Apache License, Version 2.0 (the "License"); you may not use this tool except in compliance with the License. You may obtain a copy of the License at: http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and limitations under the License.
