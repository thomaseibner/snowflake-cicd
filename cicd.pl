#!/usr/bin/perl

use lib '.';
use SnowflakeCICD;
use Data::Dumper;
use File::Path;

my $cicd_output_dir = shift || die "Need to provide an output directory for the cicd files";
my $git_output_file = shift || die "Need to provide a git metadata file";

my $cicd = SnowflakeCICD->new($git_output_file);

# alternate way to run your pipeline
#foreach my $file ($cicd->changed_files()) {
#    print $file, "\n";
#}

my $cur_branch = $cicd->git->cur_branch();
my $prev_branch = $cicd->git->prev_branch();

foreach my $path ($cicd->changed_paths()) {
    # extract each file by path
    # write metadata to output files
    $cicd->add_to_update("-- path: $path");
    $cicd->add_to_rollback("-- path: $path");
    foreach my $file ($cicd->changed_files_by_path($path)) {
	my $action = $cicd->git->file_action($file);
	$cicd->add_to_update("-- $action $file");
	$cicd->add_to_rollback("-- $action $file");
	if ($action eq 'A') {
	    # New file
	    my $update = $cicd->git->update->get_content('deploy/' . $file);
	    $cicd->add_to_update($update);
	    $cicd->add_to_rollback($cicd->ddl->drop_stmnt($update));
	    # Add your own time-travel handler here
	} elsif ($action eq 'D') {
	    my $rollback = $cicd->git->rollback->get_content('rollback/' . $file);
	    $cicd->add_to_update($cicd->ddl->drop_stmnt($rollback));
	    $cicd->add_to_rollback($rollback);
	    # Add your own time-travel handler here
	} elsif ($action eq 'M') {
	    my $update = $cicd->git->update->get_content('deploy/' . $file);
	    my $rollback = $cicd->git->rollback->get_content('rollback/' . $file);
	    my $res_create = $cicd->ddl->match($update);
	    my $res_rollback = $cicd->ddl->match($rollback);
	    # if these statements aren't true the table will have to be recreated
	    # or renamed to a new table
	    if ($res_create->{type} =~ /TABLE/i && $res_create->{type} !~ /MATERIALIZED/i
		    && $res_create->{type} eq $res_rollback->{type}
		    && $res_create->{name} eq $res_rollback->{name}) {
		$cicd->process_table_changes($file);
#	    } elsif ($res_create->{type} eq $res_rollback->{type} && $res_create->{name} eq $res_rollback->{name}) {
		# Renames are a bit more involved if there are other changes
		# Rename of table also means that the file name technically should change
		# perform all changes then rename table for the update, then create rollback in reverse
		# 1) We need to make sure the rename itself is removed from the diff
		# 2) We reverse the alter name first in the rollback before calling
		#      $cicd->process_table_changes($file)
		# 3) Then add the rename to the $cicd->add_to_update
		#$cicd->add_to_rollback("ALTER TABLE " . $res_rollback->{name} . " RENAME to " . $res_create->{name} . ";";
		#$cicd->process_table_changes($file);
		#$cicd->add_to_update("ALTER TABLE " . $res_create->{name} . " RENAME to " . $res_rollback->{name} . ";";
	    } else {
		# these objects can be reloaded directly
		# this deals with removing old procedures/functions with different parameters
		$cicd->add_to_update($cicd->ddl->drop_stmnt($rollback));
		$cicd->add_to_update($update);
		$cicd->add_to_rollback($cicd->ddl->drop_stmnt($update));
		$cicd->add_to_rollback($rollback);
	    }
	}
    }
}

# open files in the directory for the output
mkpath($cicd_output_dir . '/' . $cur_branch . '/rollback');
my ($d, $m, $y) = ( localtime() )[3..5];
my $date = sprintf("%d-%02d-%02d", $y+1900, $m+1, $d);


open(FH, ">" . $cicd_output_dir . '/' . $cur_branch . '/001_' . $date . '.sql') or die $!;
print FH "-- UPDATE: $prev_branch -> $cur_branch\n", $cicd->update(), "\n";
close(FH);
open(FH, ">" . $cicd_output_dir . '/' . $cur_branch . '/rollback/001_' . $date . '.sql') or die $!;
print FH "-- ROLLBACK: $cur_branch -> $prev_branch\n", $cicd->rollback(), "\n";
close(FH);

sub SnowflakeCICD::process_table_changes {
    my $self = shift; # $cicd
    my $file = shift;
    my $update = $self->git->update->get_content('deploy/' . $file);
    my $rollback = $self->git->rollback->get_content('rollback/' . $file);
    my $res_create = $self->ddl->match($update);
    my $res_rollback = $self->ddl->match($rollback);

    my $tbl_nm = $res_create->{name};
    my $diff = $self->git->file_diff($file);
    my $name_pat = $self->ddl->name_pat();
    my $type_pat = $self->ddl->type_pat();
    # Renames for columns in tables?

    ######
    # Step 1 - if we are adding a row at the end of the table there is likely
    # going to be a - row and + row that matches except the comma at the end
    # of the row. Remove that one to start with.

    my @pos_rows = map { substr($_, 1) } grep { substr($_, 0, 1) eq '+' } @$diff;
    my @neg_rows = map { substr($_, 1) } grep { substr($_, 0, 1) eq '-' } @$diff;
    map { $_ =~ s/\,\s*$//; } @pos_rows; # $_ =~ s/^\s*//
    map { $_ =~ s/\,\s*$//; } @neg_rows; # $_ =~ s/^\s*//
    # Now, if there is overlap in these two arrays we should remove the -/+ from the main $diff array
    # Perl Cookbook C 4.8
    my %count = ();
    my @isect = ();
    foreach my $e (@pos_rows, @neg_rows) { $count{$e}++ }
    foreach my $e (keys %count) { if ($count{$e} == 2) { push @isect, $e } }
    my %seen = ();
    my %delete = ();
    foreach my $e (@isect) {
	# remove from the main diff array
	for (my $i = 0; $i < scalar @{$diff}; $i++) {
	    if (index($diff->[$i], $e) > 0) {
		$diff->[$i] = ' ' . $e;
		if (!defined($seen{$e})) {
		    $seen{$e} = $i;
		} else {
		    if (defined($delete{$e})) {
			print "$e has been seen 3 times (1 seen, 1 delete, and 1 extra)\n";
		    } else {
			$delete{$e} = $i;
			# we should delete both this and $seen{$e}
		    }
		}
	    }
	}
    }
    # we have to remove duplicate rows as defined by %delete and in this case also %seen so we
    # don't make changes to the row(s) that didn't change
    # but have to be careful to keep an index of which were deleted
    my $index = 0;
    foreach my $file (sort { $delete{$a} <=> $delete{$b} } keys %delete) {
	splice @$diff, $seen{$file}-$index, 1;
	$index++;
	splice @$diff, $delete{$file}-$index, 1;
	$index++;
    }

    # from perldoc perlfaq4
    sub uniq { my %seen; grep !$seen{$_}++, @_ }
    my @all_chg_rows = grep { /^[-\+]/ } @$diff;
    my @all_chg_rows_order = uniq map { (/^[-\+]\s*($name_pat)\s/)[0] } grep { /^[-\+]/ } @$diff;

    ######
    # Next Step: Now process each set of grouped changes
    ######
    my @diff = @$diff;
    my @new_diff = (); my @new_diff_nm = ();
    my $state = 0; my $idx = -1;
    for (my $i = 0; $i < scalar @diff; $i++) {
	if ($diff[$i] =~ /^[\+\-]/) {
	    $idx++ if $state == 0;
	    $state = 1;
	    push @{$new_diff[$idx]}, $diff[$i];
	    # don't want duplicates in this last one 
	    push @{$new_diff_nm[$idx]}, ($diff[$i] =~ /^[-\+]\s*($name_pat)\s/)[0];
	} else {
	    # unique $new_diff_nm
	    $state = 0;
	}
    }
    foreach my $array_ref (@new_diff_nm) {
	@{$array_ref} = uniq @{$array_ref}
    }
    ######
    # Now the array of arrays we have can be used to determine the groups of changes needed
    # If the array starts with a + the changes are easy column adds
    # If the array starts with a - and only has - it is easy column removes
    # If the array starts with a - and has one or more - as well as one or more +
    #   we have to be a little more careful and there could be column renames
    ######
    # What can we expect here? For each array we should check if the same field is being changed?

    my @individual_fields = ();
    for (my $j = 0; $j < scalar @new_diff; $j++) {
	my $new_diff = $new_diff[$j];
	for (my $i = 0; $i < scalar @{$new_diff}; $i++) {
	    my $row = $new_diff->[$i];
	    my ($name, $type) = $row =~ /($name_pat)\s*($type_pat)/;
	    if (defined($name) && defined($type)) {
		push @{$individual_fields[$j]->{$name}}, $row;
	    }
	}
    }

    ######
    # Process the $diff and @individual_fields groupings
    ######
    # Now we can start working on all the rows based on the order in @all_chg_rows_order

    # @new_diff_nm array of array refs to use for each of the fields below
    my %actions = ('-' => 'DROP', '+' => 'ADD');
    for (my $i = 0; $i < scalar @new_diff_nm; $i++) {
	# if there are only two rows it could be a rename
	for (my $j = 0; $j < scalar @{$new_diff_nm[$i]}; $j++) {
	    my $column_name = $new_diff_nm[$i]->[$j];
	    my $diff_for_column_ref = $individual_fields[$i]->{$column_name};
	    if (@{$diff_for_column_ref} == 2) {
		# if there are two rows in the $diff_for_column_ref
		# it means that either the type or rest of the column definition changed
		my $before_column_def = $diff_for_column_ref->[0];
		my $after_column_def = $diff_for_column_ref->[1];
		# given the names are the same we should not need to extract both names
		my ($before_name, $before_type, $before_rest) = $before_column_def =~ /^\-\s*($name_pat)\s*($type_pat)\s*?(.*)?,?$/;
		my ($name, $type, $rest) = $after_column_def =~ /^\+\s*($name_pat)\s*($type_pat)\s*?(.*)?,?$/;
		# Handle NULLs, and other parts of 
		# https://docs.snowflake.com/en/sql-reference/sql/create-table.html#optional-parameters
		# support COLLATE ' ', COMMENT ' ', DEFAULT ' ', AUTOINCREMENT, IDENTITY, CONSTRAINT 
		if (uc($before_type) ne uc($type)) {
		    $cicd->add_to_update("ALTER TABLE $tbl_nm ALTER COLUMN $name type $type;");
		    #print "alter table ",  $tbl_nm, " ALTER column $name type $type\n";
		    $cicd->add_to_rollback("ALTER TABLE $tbl_nm ALTER COLUMN $name type $before_type;");
		}
		if (uc($before_rest) ne uc($rest)) {
		    print "$before_rest : doesn't match : $rest\n";
		}
	    } else {
		# Single row for each field - unless using some heuristics or guessing it is
		# impossible to say that any single row is a rename
		# We could use Text::Fuzzy to attempt to match names for rename
		# or simply see how many rows only has a different name but all other parameters the same?
		my $clmn_def = $diff_for_column_ref->[0];
		my ($action, $name, $type) = $clmn_def =~ /^([-\+])\s*($name_pat)\s*($type_pat)/;
		if ($actions{$action} eq 'ADD') {
		    $clmn_def =~ s/^\+\s*//;
		    # Really should be careful to not add 'not null', but if table is empty it could
		    # still work.
		    $cicd->add_to_update("ALTER TABLE $tbl_nm ADD COLUMN $name $type;");
		    $cicd->add_to_rollback("ALTER TABLE $tbl_nm DROP COLUMN $name;");
		    #print "alter table ", $tbl_nm, " ", $actions{$actionstion}, " column $clmn_def\n";
		    # rollback?
		} else {
		    $cicd->add_to_update("ALTER TABLE $tbl_nm DROP COLUMN $name;");
		    $cicd->add_to_rollback("ALTER TABLE $tbl_nm ADD COLUMN $name $type;");
		    #print "alter table ", $tbl_nm, " DROP column $name\n";
		    # rollback?
		}
	    }
	}
    }
}


exit 0;
