package SnowflakeCICD;

use 5.006;
use strict;
use warnings;
use Data::Dumper;

our $VERSION = '0.01';

package SnowflakeCICD::GitParse;

use 5.006;
use strict;
use warnings;
use Data::Dumper;
use Archive::Tar;

our $VERSION = '0.01';

sub new {
    my $self = shift;
    my $file = shift;
    my $ref = bless { file => $file }, $self;
    $ref->_init();
    $ref->_read_diff();
    return $ref;
}

sub dump {
    my $self = shift;
    print STDERR Dumper($self);
}

sub update {
    my $self = shift;
    return $self->{tar_update};
}

sub rollback {
    my $self = shift;
    return $self->{tar_rollback};
}

sub _init {
    my $self = shift;
    my ($git_output_tar) = $self->{file} =~ /^(.*).diff/;
    my $git_output_rollbacktar = $git_output_tar . '-rollback.tar.gz';
    $git_output_tar = $git_output_tar . '-update.tar.gz';
    $self->{tar_update} = Archive::Tar->new();
    $self->{tar_update}->read($git_output_tar) || die "Error opening tar archive: $git_output_tar: $!";
    $self->{tar_rollback} = Archive::Tar->new();
    $self->{tar_rollback}->read($git_output_rollbacktar) || die "Error opening tar archive: $git_output_rollbacktar: $!";
}

sub _read_diff {
    my $self = shift;
    my $file = $self->{file};
    # do we need to worry about carriage returns on windows?
    # $/ = "\r\n"; # #$!@$ Windows
    my $fh;
    open($fh, $file) or die "Unable to open file: $!";
    my @file = <$fh>;
    close($fh);
    chomp(@file);
    my $header_branch = shift @file;
    my $header_id = shift @file;
    my ($cur_branch, $prev_branch) = $header_branch =~ /^Merged into (\S+) from (\S+)/;
    my ($git_id, $commit_message) = $header_id =~ /^([0-9a-f]+)\s*(.*)$/;
    #print "$cur_branch:$prev_branch:$git_id\n";
    $self->{_diff} = { cur_branch => $cur_branch,
		       prev_branch => $prev_branch,
		       git_id => $git_id,
		       commit_message => $commit_message,
		       header_branch => $header_branch,
		       header_id => $header_id
		   };
    # Now parse the changed files. If the git_id show up we are done.
    while (my $line = shift @file) {
	last if $line =~ /^$git_id/;
	my ($action, $chg_file) = $line =~ /^([ADM])\s+(\S+)/;
	my ($path, $file_nm) = $chg_file =~ /^(.*\/)([^\/]+)/;
	#print STDERR "$action:$path:$file_nm:$chg_file\n";
	$self->{changed_files}->{$chg_file} = { action => $action, path => $path, file_name => $file_nm };
    } # past the abbreviated version of which files changed A/M/D
    while (@file) {
	my $firstline = shift @file;
	my $secondline = shift @file;
	my $thirdline;
	my ($diff_file) = $firstline =~ /^diff --git a\/(\S+) b\//;
	if ($secondline !~ /^index [0-9a-f]+\.\.[0-9a-f]+/) {
	    $thirdline = shift @file;
	} else {
	    $thirdline = $secondline;
	    $secondline = '';
	}
	#print STDERR qq{$firstline:$secondline:$thirdline\n};
	my @header_data = ($firstline, $secondline, $thirdline);
	my @data = ();
	while (@file) {
	    last if $file[0] =~ /^diff --git a/;
	    push @data, shift @file;
	}
	# We should put the two --- and +++ lines in here too:
	if (scalar @data > 2) { push @header_data, shift @data; push @header_data, shift @data}
	$self->{changed_files}->{$diff_file}->{diff_header} = \@header_data;
	$self->{changed_files}->{$diff_file}->{diff_data} = \@data;
    }
}

sub changed_files {
    my $self = shift;
    return keys %{$self->{changed_files}};
}

sub changed_files_by_path {
    my $self = shift;
    my $path = shift;
    my %files_by_path = ();
    foreach my $file ($self->changed_files()) {
	my $tmp_path = $self->{changed_files}->{$file}->{path};
	push @{$files_by_path{$tmp_path}}, $file;
    }
    if (defined($files_by_path{$path})) {
	return @{$files_by_path{$path}};
    }
    return ();
}

sub changed_paths {
    my $self = shift;
    my %paths = ();
    foreach my $file ($self->changed_files()) {
	my $path = $self->{changed_files}->{$file}->{path};
	$paths{$path} = 1;
    }
    return sort keys %paths;
}

sub file_diff {
    my $self = shift;
    my $file = shift;
    return $self->{changed_files}->{$file}->{diff_data};
}

sub file_action {
    my $self = shift;
    my $file = shift;
    return $self->{changed_files}->{$file}->{action};
}

sub cur_branch {
    my $self = shift;
    return $self->{_diff}->{cur_branch};
}

sub prev_branch {
    my $self = shift;
    return $self->{_diff}->{prev_branch};
}

sub git_id {
    my $self = shift;
    return $self->{_diff}->{git_id};
}

package SnowflakeCICD::DDLParse;

sub new {
    my $self = shift;
    my $ref = bless {}, $self;
    $ref->_init();
    return $ref;
}

sub match {
    my $self = shift;
    my $ddl = shift;
    my $ref_obj_pat = $self->{ref_obj_pat};
    # return the correct matches
    # the first 3 scalars is the object type, so make them into 1
    # the fourth scalar is the name of the object
#    my @ret = $ddl =~ /$ref_obj_pat/;
#    return \@ret;
    my ($type1, $type2, $name, $params) = $ddl =~ /$ref_obj_pat/;
    my $type = defined($type1) ? $type1 : defined($type2) ? $type2 : '';
    $params = defined($params) ? $params : '';
    $name = defined($name) ? $name : '';
    #print STDERR $ddl, ":", uc($type), ":", $name, ":", $params,  "\n";

    # Non-successful match
    my $status = $name ne '' ? 1 : 0;
    return {statement=>$ddl, type=>uc($type), name=>$name, params=>$params, status => $status};
}

sub drop_stmnt {
    my $self = shift;
    my $ddl = shift;
    my $object_type_pat = $self->object_type_pat();
    my $ref = $self->match($ddl);
    my $name = $ref->{name};
    if (defined($ref->{type}) && $ref->{type} =~ /((?:FUNCTION)|(?:PROCEDURE))/i) {
	my $base_type = $1;
	my $type_pat = $self->type_pat();
	my $type = $ref->{type};
	my $params = $ref->{params};
        $params =~ s/\s*RETURNS.*//i;
	# now get the field types back - only field types matter, not what result it returns
	my @params = $params =~ /$type_pat/g;
	my $base_params = join ', ', @params;    
	return qq{DROP $base_type $name($base_params);};
    } elsif (defined($ref->{type}) && $ref->{type} =~ /($object_type_pat)/i) {
	my $object_type = $1;
	return qq{DROP $object_type $name;};
    } else {
	warn("Unknown object type: ", Dumper($ref));
    }
}

sub name_pat {
    my $self = shift;
    return $self->{name_pat};
}

sub type_pat {
    my $self = shift;
    return $self->{type_pat};
}

sub object_type_pat {
    my $self = shift;
    return $self->{object_type_pat};
}

sub debug {
    my $self = shift;
    # load Regexp::Debugger dynamically to debug parsing - fail gracefully if not present on system
    unless (eval "require Regex::Debugger") {
	warn "couldn't load Regexp::Debugger: $@";
    }
}

sub dump {
    my $self = shift;
    print STDERR Dumper($self);
}

sub _init {
    my $self = shift;

    # https://docs.snowflake.com/en/sql-reference/identifiers-syntax.html
    # Are there any reserved names it can't be?
    my $name_pat = qr/
# Unquoted name max length 255
(?:[A-Za-z\_]{1}[A-Za-z0-9\_\$]{0,254})
|
# Quoted name
# ASCII 32-126 (hex 20-7E) are valid characters in between quotes including quotes max length 255
(?:\"[\x20-\x7E]{1,253}\")
    /x;
    $self->{name_pat} = $name_pat;
    my $gen_pat = qr/
   # CREATE [ OR REPLACE ] API INTEGRATION [ IF NOT EXISTS ] <integration_name>
  API\s*INTEGRATION
  |# CREATE [ OR REPLACE ] EXTERNAL TABLE [IF NOT EXISTS]
  EXTERNAL\s*TABLE
  |# CREATE [ OR REPLACE ] STREAM [IF NOT EXISTS]
  STREAM
  |# CREATE [ OR REPLACE ] TASK [IF NOT EXISTS]
  TASK
  |# CREATE [ OR REPLACE ] TAG [ IF NOT EXISTS ]
  TAG
  |# CREATE [ OR REPLACE ] FILE FORMAT [ IF NOT EXISTS ]
  FILE\s*FORMAT
  |# CREATE [ OR REPLACE ] MASKING POLICY [ IF NOT EXISTS ]
  MASKING\s*POLICY
  |# CREATE [ OR REPLACE ] NOTIFICATION INTEGRATION [IF NOT EXISTS]
  NOTIFICATION\s*INTEGRATION
  |# CREATE [ OR REPLACE ] PIPE [ IF NOT EXISTS ]
  PIPE
  |# CREATE [ OR REPLACE ] ROLE [ IF NOT EXISTS ]
  ROLE
  |# CREATE [ OR REPLACE ] ROW ACCESS POLICY [ IF NOT EXISTS ]
  ROW\s*ACCESS\s*POLICY
  |# CREATE [ OR REPLACE ] SECURITY INTEGRATION [IF NOT EXISTS]
  SECURITY\s*INTEGRATION
  |# CREATE [ OR REPLACE ] SEQUENCE [ IF NOT EXISTS ]
  SEQUENCE
  |# CREATE [OR REPLACE] SESSION POLICY [IF NOT EXISTS]
  SESSION\s*POLICY
  |# CREATE [ OR REPLACE ] STORAGE INTEGRATION [IF NOT EXISTS]
  STORAGE\s*INTEGRATION
  |# CREATE [ OR REPLACE ] USER [ IF NOT EXISTS ]
  USER
  |# CREATE [ OR REPLACE ] WAREHOUSE [ IF NOT EXISTS ]
  WAREHOUSE
    /ix;
    $self->{gen_pat} = $gen_pat;
    my $vw_pat = qr/
  # CREATE [ OR REPLACE ] [ SECURE ] [ RECURSIVE ] VIEW [ IF NOT EXISTS ] <name>
  # CREATE [ OR REPLACE ] [ SECURE ] MATERIALIZED VIEW [ IF NOT EXISTS ] <name>
  (?:SECURE\s*)?(?:(?:RECURSIVE\s*)|(?:MATERIALIZED\s*))?VIEW
  # optional secure followed by optional recursive or materialized
    /ix;
    $self->{vw_pat} = $vw_pat;
    my $tbl_pat = qr/
  # CREATE [ OR REPLACE ]
  #   [ { [ LOCAL | GLOBAL ] TEMP[ORARY] | VOLATILE } | TRANSIENT ]
  #   TABLE [ IF NOT EXISTS ] <table_name>
  # [ 
  #   { 
  #     [ LOCAL | GLOBAL ] TEMP[ORARY] | VOLATILE 
  #   } 
  #   | TRANSIENT 
  #   | HYBRID
  #   | MATERIALIZED
  # ]
  # TABLE
  # TEMP[ORARY] | LOCAL TEMP[ORARY] | GLOBAL TEMP[ORARY] | VOLATILE
  (?:
     (?:
        (?:(?:LOCAL\s*)|(?:GLOBAL\s*))?
                                 (?:TEMP(?:ORARY)?\s*) # for this it isn't optional
     )
     |
     (?:VOLATILE\s*)
  )?
  (?:TRANSIENT\s*)? # if we can't have a temp transient table or volatile transient table
                    # TRANSIENT needs to be moved back to the above OR
  (?:HYBRID\s*)?
  (?:MATERIALIZED\s*)?
  TABLE
    /ix;
    $self->{tbl_pat} = $tbl_pat;
    my $db_sc_pat = qr/
  # CREATE [ OR REPLACE ] [ TRANSIENT ] DATABASE [ IF NOT EXISTS ]
  # CREATE [ OR REPLACE ] [ TRANSIENT ] SCHEMA [ IF NOT EXISTS ]
  (?:TRANSIENT\s*)?
  (?:(?:DATABASE)|(?:SCHEMA))
    /ix;
    $self->{db_sc_pat} = $db_sc_pat;
    my $stg_pat = qr/
  # CREATE [ OR REPLACE ] [ TEMPORARY ] STAGE [ IF NOT EXISTS ]
  (?:TEMPORARY\s*)?
  STAGE
    /ix;
    $self->{stg_pat} = $stg_pat;
    my $cor_pat = qr/
# Doesn't support IF NOT EXISTS
# CREATE [ OR REPLACE ] NETWORK POLICY
# CREATE [ OR REPLACE ] RESOURCE MONITOR
# CREATE [ OR REPLACE ] SHARE
  (?:(?:NETWORK\s*POLICY)|(?:RESOURCE\s*MONITOR)|(?:SHARE))
    /ix;
    $self->{cor_pat} = $cor_pat;
    my $prfn_pat = qr/
# CREATE [ OR REPLACE ] [ SECURE ] EXTERNAL FUNCTION <name> ( [ <arg_name> <arg_data_type> ] [ , ... ] ) RETURNS <result_data_type>
# CREATE [ OR REPLACE ] [ SECURE ] FUNCTION <name> ( [ <arg_name> <arg_data_type> ] [ , ... ] ) RETURNS { <result_data_type> | TABLE ( <col_name> <col_data_type> [ , ... ] ) }
# CREATE [ OR REPLACE ] PROCEDURE <name> ( [ <arg_name> <arg_data_type> ] [ , ... ] ) RETURNS <result_data_type>
  (?:SECURE\s*)?
  (?:(?:EXTERNAL\s*)?(?:FUNCTION)|(?:PROCEDURE))
    /ix;
    $self->{prfn_pat} = $prfn_pat;
    # technicall connection and managed account does not support "OR REPLACE"
    my $con_pat = qr/
# CREATE CONNECTION [ IF NOT EXISTS ] <name>
  CONNECTION
    /ix;
    $self->{con_pat} = $con_pat;
    my $manact_pat = qr/
# CREATE MANAGED ACCOUNT <name> 
  MANAGED\s*ACCOUNT
    /ix;
    $self->{manact_pat} = $manact_pat;
    # https://docs.snowflake.com/en/sql-reference/intro-summary-data-types.html
    # Should we support single quotes here? https://docs.snowflake.com/en/sql-reference/data-types-text.html#string-constants
    my $type_pat = qr/
(?:                              # max first digit is 38, max second digit is 37
  (?: (?:(?:NUMBER)|(?:DECIMAL)|(?:NUMERIC)) (?:\s*\(\s*\d{1,2}\s*\,\s*\d{1,2}\s*\))? )
  |(?:(?:INT(?:EGER)?)|(?:BIGINT)|(?:SMALLINT)|(?:TINYINT)|(?:BYTEINT))
  |(?:(?:FLOAT)|(?:FLOAT4)|(?:FLOAT8)|(?:DOUBLE(?:\s*PRECISION)?)|(?:REAL))
  |(?: (?:(?:VARCHAR)|(?:CHAR(?:ACTER)?)|(?:NCHAR)|(?:STRING)|(?:TEXT)|(?:NVARCHAR(?:2)?)|(?:CHAR\s*VARYING)|(?:NCHAR\s*VARYING)) (?:\s*\(\s*\d{1,8}\s*\))? )
  |(?: (?:(?:BINARY)|(?:VARBINARY)) (?:\s*\(\s*\d{1,8}\s*\))? )
  |(?:BOOLEAN)
  |(?: (?:(?:DATE)|(?:DATETIME)|(?:TIME)|(?:TIMESTAMP(?:\_[LN]?TZ))) (?:\s*\(\s*[A-Z\-\:]*\s*\))? )
  |(?:(?:VARIANT)|(?:OBJECT)|(?:ARRAY))
  |(?:GEOGRAPHY)
)
    /ix;
    $self->{type_pat} = $type_pat;
    my $object_type_pat = qr/
(?:
(?:CONNECTION)|(?:DATABASE)|(?:EXTERNAL\s*TABLE)|(?:FILE\s*FORMAT)|(?:FUNCTION)|(?:INTEGRATION)|(?:MANAGED\s*ACCOUNT)|(?:MASKING\s*POLICY)|(?:MASTERIALIZED\s*VIEW)|(?:NETWORK\s*POLICY)|(?:PIPE)|(?:PROCEDURE)|(?:RESOURCE\s*MONITOR)|(?:ROLE)|(?:ROW\s*ACCESS\s*POLICY)|(?:SCHEMA)|(?:SEQUENCE)|(?:SESSION\s*POLICY)|(?:SHARE)|(?:STAGE)|(?:STREAM)|(?:TABLE)|(?:TAG)|(?:TASK)|(?:USER)|(?:VIEW)|(?:WAREHOUSE)
)
    /ix;
    $self->{object_type_pat} = $object_type_pat;
    my $ref_obj_pat = qr{
  CREATE\s*                 # Match CREATE
    (?:OR\s*REPLACE\s*)?    # Optional OR REPLACE
(?:
   (?:($cor_pat|$prfn_pat|$manact_pat))
  |
   (?:($vw_pat|$tbl_pat|$gen_pat|$db_sc_pat|$stg_pat|$con_pat)(?:\s*IF\s*NOT\s*EXISTS)?\s*)
)
\s*($name_pat)
(?:
   \s*(
       \( (?:\s*$name_pat\s*$type_pat\s* (?:\s*\,\s*$name_pat\s*$type_pat\s*)*? ) \)
       \s*RETURNS
       \s*(?:
             (?:$type_pat)
            |
             (?:TABLE\s*\( (?:\s*$name_pat\s*$type_pat\s* (?:\s*\,\s*$name_pat\s*$type_pat\s*)*? ) \)
             )
          )
      )
)?
    }mix;
    $self->{ref_obj_pat} = $ref_obj_pat;
}

package SnowflakeCICD;

sub new {
    my $self = shift;
    my $git_output_file = shift;
    my $ref = bless {}, $self;
    $ref->{_gitparse} = SnowflakeCICD::GitParse->new($git_output_file);
    $ref->{_ddlparse} = SnowflakeCICD::DDLParse->new();
    @{$ref->{update}} = ();
    @{$ref->{rollback}} = ();
    return $ref;
}

sub ddl {
    my $self = shift;
    return $self->{_ddlparse};
}

sub git {
    my $self = shift;
    return $self->{_gitparse};
}

sub changed_files {
    my $self = shift;
    return $self->git->changed_files();
}

sub changed_files_by_path {
    my $self = shift;
    return $self->git->changed_files(@_);
}

sub changed_paths {
    my $self = shift;
    return $self->git->changed_paths();
}

sub add_to_update {
    my $self = shift;
    push @{$self->{update}}, @_;
}

sub add_to_rollback {
    my $self = shift;
    push @{$self->{rollback}}, @_;
}

sub update {
    my $self = shift;
    return join "\n", @{$self->{update}};
}

sub rollback {
    my $self = shift;
    return join "\n", @{$self->{rollback}};
}

1;

__END__

=head1 NAME

SnowflakeCICD - Parsing output from GIT to create Snowflake CICD pipelines

=head1 VERSION

Version 0.01

=cut

=head1 SYNOPSIS

use SnowflakeDDLParse;

my $parser = SnowflakeDDLParse->new();
my $statement = 'CREATE TABLE test ( .. ';

my $ret = $parser->match($statement);

# load Regexp::Debugger for subsequent regular expressions if module is present
$parser->debug();

# use Data::Dumper to dump the SnowflakeDDLParse object
$parser->dump();

my $name_pattern        = $parser->name_pat();
my $type_pattern        = $parser->type_pat();
my $object_type_pattern = $parser->object_type_pat();

=head2 new

Builds the object with pattern matching parsing of Snowflake CREATE statements

=cut

=head2 match

Returns the match of type of object and name of the object

=cut

=head2 drop_stmnt

Build the required drop statement syntax for a given object - especially important with
functions and procedures to not leave objects with similar parameters around.

=cut

=head2 name_pat

Returns the regular expression pattern used to validate a name of a table or column in Snowflake
built based on C<< <https://docs.snowflake.com/en/sql-reference/identifiers-syntax.html> >>

=cut

=head2 type_pat

Returns the regular expression pattern used to validate a data type in Snowflake built based on
C<< <https://docs.snowflake.com/en/sql-reference/intro-summary-data-types.html> >>

Does not currently support single quotes in the expression for string constants such as 'value'' '

Both name and type patterns are useful for extracting valid names and types.

=cut

=head2 object_type_pat

Returns the regular expression pattern used to validate an object in Snowflake - meant for creating
drop statements

=cut

=head1 AUTHOR

Thomas Eibner, C<< <thomas at stderr.net> >>

=head1

=head1 LICENSE AND COPYRIGHT

This software is Copyright (c) 2022 by Thomas Eibner.

This is free software, licensed under:

  The Apache License 2.0


=cut



