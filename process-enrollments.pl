#!/usr/bin/perl
#
# Process all Canvas course enrollments.
# This script is meant to be run overnight. It queries Canvas for all courses and sections
# then all users. Then for each section, it fetches what the enrollment should be from Amaint
# and processes any adds and drops
#
# You can optionally use "-f sis_section_id;sis_section_id" to force handling only the specified
# sis_section_ids and to empty them if the new enrollment is empty


use lib '/opt/amaint/etc/lib';
use Canvas;
use awsomeLinux; 	# Local SFU library to handle SOAP calls to fetch course rosters
use Switch;
use Getopt::Std;


#-----config------
# Canvas Account ID for "Simon Fraser University" account
$account_id = "2";
# Location where files are kept for manually generated section enrollments
$roster_files = "/opt/amaint/rosterfiles";
# Seconds to wait before giving up waiting for user import to complete
$import_timeout = 900;

# Set debug to '3' to do no processing. Set to '2' to process users but not enrollments. Set to 1 for normal processing with extra output
$debug = 1;

$Canvas::debug = ($debug > 2) ? 1 : 0;

#--- end config ----

# Global array references for courses, sections and users
my ($courses,$sections,$users,$users_by_id,$users_by_username,$courses_by_id);

# Global vars for the CSVs that will hold user-adds and enrollment changes
my($users_csv,@enrollments_csv);
my $users_need_adding = 0;

my ($currentTerm,$previousTerm);

# Global counters
my ($total_enrollments,%total_users,$total_sections);

getopt('f');

push @enrollments_csv,"course_id,user_id,role,section_id,status,associated_user_id";
$users_csv = "user_id,login_id,password,first_name,last_name,email,status\n";

# Main block
{
	getService();
	getTerm();
	fetch_courses_and_sections() or error_exit("Couldn't fetch courses and sections from Canvas!");
	fetch_users() or error_exit("Couldn't fetch user list from Canvas!");
	generate_enrollments();
	print @skipmsgs;
	process_user_adds();
	process_enrollments();
	summary();
	
	exit 0;
}

sub fetch_courses_and_sections
{
	my (@sections);
	$courses = rest_to_canvas_paginated("/api/v1/accounts/$account_id/courses");
	return undef if (!defined($courses));

	print "Retrieved ",scalar(@{$courses})," courses from Canvas\n";

	foreach $course (@{$courses})
	{
		$c_id = $course->{id};
		$courses_by_id{$c_id} = $course;
		$course_sections = rest_to_canvas_paginated("/api/v1/courses/$c_id/sections");
		if (!defined($course_sections))
		{
			print "Couldn't get sections for course $c_id\n";
			return undef;
		}
		push @sections,@{$course_sections};
	}

	print "Retrieved ",scalar(@sections), " sections from Canvas\n";

	$sections = \@sections;

	return 1;
}

sub fetch_users
{
	$users = rest_to_canvas_paginated("/api/v1/accounts/$account_id/users");
	return undef if (!defined($users));
	print "Fetched ",scalar(@{$users})," users from Canvas\n";
	foreach $u (@{$users})
	{
		# Don't include users that don't have an SIS ID (SFUID) defined. Forces them to be reimported if they're in any courses)
		next if (!$u->{sis_user_id});

		$users_by_username{$u->{login_id}} = $u;
		$users_by_id{$u->{id}} = $u;
	}
	print join("\nUser: ",sort(keys %users_by_username)) if ($debug > 2);

	return 1;
}

# Calculate the current term. This could get replaced with a REST call in the future
# This is a rather clumsy, brute force attempt. We've arbitrarily set term start dates
# of May 5 and Sep 1. This should be ok though because we also populate all *future*
# terms, so it'll only be old terms that don't get populated. This could become an issue
# though when we implement 'completed' enrollments -- we want to make sure the 'completed'
# change happens at the right time

sub getTerm
{
	my $date = `date +\%y/\%m\%d`;
	chomp($date);
	my ($year,$moday) = split(/\//,$date);
	my $term = 7;
	my $prevterm = 4;
	my $prevyear = $year;
	if ($moday < 901)
	{
		$term = 4;
		$prevterm = 1;
	}
	if ($moday < 505)
	{
		$term = 1;
		$prevterm = 7;
		$prevyear--; 
	}

	$currentTerm = "1$year$term";
	$previousTerm = "1$prevyear$prevterm";
	print "Date: $year/$moday\nCurrent Term: $currentTerm\nPrevious Term: $previousTerm\n" if ($debug);
}
	

# The meat of the matter. Iterate through sections comparing their enrollments to what they should be
# Once finished, we'll have a users.csv and an enrollments.csv that each need to be processed.
#
# We also check for observer roles in *any* section of a course. After checking all sections of a course,
# we check all current enrollments and see if they match any observer role and if so, remove the observer role

sub generate_enrollments
{
	my ($c_id,$old_c_id,@all_enrollments,%observers);
	my $force = 0;

	foreach $section (@{$sections})
	{
		my ($maillist);

		$sis_id = $section->{'sis_section_id'};
		$c_id = $section->{'course_id'};
		if ($c_id != $old_c_id)
		{
			# Starting a new course. See if there were any observers in the last course
			$old_c_id = $c_id;
			check_observers(\%observers,\@all_enrollments);
			%observers = ();
			@all_enrollments = ();
		}

		if (defined($opt_f))
		{
			$force = 0;
			next if ($opt_f !~ /\Q$sis_id\E/);
			$force = 1;
		}


		if ($sis_id eq "null" || $sis_id eq "")
		{
			push @skipmsgs,"Skipped section \"".$section->{name}."\" in course ID $c_id. No sis_section_id set\n";
			next;
		}

		if ($sis_id !~ /:::/)
		{
			push @skipmsgs,"Skipped section \"".$section->{name}."\" with sis_section_id $sis_id in course ID $c_id. Missing ':::' delimiter\n";
			next;
		}
		else
		{
			$sis_id =~ s/:::.*//;
		}

		print "Processing $sis_id, Name: ",$section->{name},"\n" if $debug;


		if ($sis_id =~ /^(list:|group:|file:)/)
		{
			# Special cases -- 'type:source' is supported
			($type,$type_source) = split(/:/,$sis_id,2);
		}
		else
		{
			$type = "term";
			($term,$dept,$course,$sect) = split(/-/,$sis_id);

			# Do some basic sanity checks on the sis_section_id
			if ($term !~ /^\d+$/ || $dept !~ /^[a-zA-Z0-9]+$/ || $course !~ /^\d+\w?$/ || $sect !~ /^[a-zA-Z]+\d+$/) 
			{
				push @skipmsgs,"Malformed sis_section_id \"$sis_id\" for section ".$section->{name}." in course ID $c_id. SKIPPING\n";
				next;
			}

			# Skip past terms
			if ($term < $currentTerm)
			{
				print "Skipping $sis_id from a previous term\n" if $debug;
				next;
			}
		}
	
		$total_sections++;

		# Fetch enrollment data from Canvas
		
		$s_id = $section->{id};
		$enrollments = rest_to_canvas_paginated("/api/v1/sections/$s_id/enrollments");
		if (!defined($enrollments))
		{
			print "Error retrieving enrollments for section \"",$section->{name},"\" in course ID ",$section->{'course_id'},". SKIPPING\n";
			next;
		}

		# Generate a list of usernames that are currently in the course
		my (@current_enrollments);
		foreach $en (@{$enrollments})
		{
			# Skip all but student enrollments
			# TODO: But we need to check whether ObserverEnrollment needs to be deleted if a StudentEnrollment for the same user gets added
			if ($en->{type} eq "ObserverEnrollment")
			{
				$observers{$users_by_id{$en->{user_id}}->{login_id}} = $section;
				next;
			}
			next if ($en->{type} ne "StudentEnrollment");
			push (@current_enrollments, $users_by_id{$en->{user_id}}->{login_id});
		}
		print "Users in section: \n",join(",",sort @current_enrollments),"\n" if $debug;

		# Grab new enrollments from source

		switch ($type) {
		    case "list" {
			@new_enrollments = split(/:::/,membersOfMaillist($type_source));
			break;
		    }
		    case "file" {
			if (-f "$roster_files/$type_source")
			{
				open(IN,"$roster_files/$type_source");
				@new_enrollments = map chomp , <IN>;
				close IN;
			}
			else
			{
				print STDERR "Roster file $roster_files/$type_source not found for ",$section->{name},"\n";
			}
			break;
		    }
		    case "group" {
			print STDERR "Groups not implemented yet\n";
			break;
		    }
		    case "term" {
			@new_enrollments = split(/:::/,rosterForSection($dept,$course,$term,$sect));
			break;
		    }
		}

		if (scalar(@new_enrollments) == 0 && !$force)
		{
			print STDERR "New Enrollments for ",$section->{name}," is empty! Won't process without \'force\'\n";
			next;
		}

		print "New enrollments for ",$section->{name},": \n",join(",",sort @new_enrollments),"\n" if $debug;

		foreach $en (@new_enrollments)
		{
			$total_users{$en}++;
		}

		$total_enrollments += scalar(@new_enrollments);

		# Now we have our old and new enrollments. Calculate the diff
		($adds,$drops) = compare_arrays(\@new_enrollments,\@current_enrollments);
		push @all_enrollments,@new_enrollments;

		# If both 'adds' and 'drops' are empty, nothing to do
		if (!scalar(@{$adds}) && !scalar(@{$drops}))
		{
			print "Skipping ",$section->{name},". Nothing to do\n" if $debug;
			next;
		}

		# Go through our 'adds' and see if there are any users here who aren't in Canvas yet

		my (@new_users);
		foreach $add (@{$adds})
		{
			push (@new_users,$add) if (!defined($users_by_username{$add}));
		}
		if (scalar(@new_users))
		{
			print "Adding ",scalar(@new_users)," new users for section ",$section->{name},"\n";
			add_new_users(@new_users);
		}

		# Now convert the adds and drops into enrollments and de-enrollments
		print "Processing ",scalar(@{$adds})," Adds and ",scalar(@{$drops})," Drops for section ",$section->{name},"\n";
		add_enrollments($adds,$section);
		drop_enrollments($drops,$section);
	}
	check_observers(\%observers,\@all_enrollments);
}


# Add an array of new users to the CSV file. Uses Amaint to fetch info about each user
sub add_new_users
{
	my @adds = @_;
	foreach my $user (@adds)
	{
		my ($roles,$sfuid,$lastname,$firstnames,$givenname) = split(/:::/,infoForComputingID($user)); 
		if ($roles !~ /[a-z]+/)
		{
			print STDERR "Got back invalid response from infoForComputingID for $user. Skipping add\n";
			next;
		}
		#user_id,login_id,password,first_name,last_name,email,status\
		print "Adding new user to csv: $sfuid,$user,$givenname,$lastname\n" if $debug;
		$users_csv .= "$sfuid,$user,,$givenname,$lastname,$user\@sfu.ca,active\n";
		$users_need_adding++;
	}
}

sub check_observers
{
	my ($observers,$all_enrollments) = @_;
	if (scalar(keys %{$observers}))
	{
	    # There were observers in the previous course, see if any got added as students
	    my (%count,@dups);
	    map $count{$_}++ , keys %{$observers}, @{$all_enrollments};
	    @dups = grep $count{$_} == 2, keys %{$observers};
	    if (scalar(@dups))
	    {
		foreach my $dup (@dups)
		{
		    print "Deleting Observer $dup from ",$observers->{$dup}->{sis_section_id},"\n" if ($debug);
		    do_enrollments([$dup],$observers->{$dup},"deleted","observer");
		}
	    }
	}
}
# Add new enrollments to the CSV file
sub add_enrollments
{
	do_enrollments(@_,"active");
}

sub drop_enrollments
{
	do_enrollments(@_,"deleted");
}

sub do_enrollments
{
	my ($users,$section,$status,$role) = @_;

	$role = "student" if (!defined($role));

	foreach my $user (@{$users})
	{
		my $user_id = defined($users_by_username{$user}) ? $users_by_username{$user}->{sis_user_id} : "##$user##";

		# course_id, sfuid, role, section_id, status, associated_user_id(blank)
		push @enrollments_csv, join(",", $courses_by_id{$section->{course_id}}->{sis_course_id},$user_id, $role, $section->{sis_section_id}, $status, "");
	}
}

# Send users.csv to Canvas and wait for it to complete processing
# We're only willing to wait so long though before we throw an error
sub process_user_adds
{
	return if (!$users_need_adding);
	print "Adding $users_need_adding users to Canvas\n";
	if ($debug < 3)
	{
		my $json = rest_to_canvas("POSTRAW","/api/v1/accounts/2/sis_imports.json?extension=csv",$users_csv);
		if ($json eq "0")
		{
			print "Received error trying to import new users. Can't continue!\n";
			exit 1;
		}
		my $import_id = $json->{id};
		if ($import_id < 1)
		{
			error_exit("Received error trying to import new users. Can't continue!\n$json\n");
			exit 1;
		}

		# Now we wait for the import to complete. We need to poll Canvas to find out its status
		my $now = time();
		my $done = 0;
		while (time() < ($now + $import_timeout))
		{
			$json = rest_to_canvas("GET","/api/v1/accounts/2/sis_imports/$import_id");
			if ($json ne "0")
			{
				if ($json->{ended_at} =~ /^20\d\d-\d+-\d+T/)
				{
					$done++;
					last;
				}
				sleep 5;
			}
		}

		if (!$done)
		{
			error_exit("Timed out waiting for user import to finish. Can't continue! Course enrollments NOT DONE\n");
		}

		# Now fetch all users again from Canvas to update our user_id hash
		fetch_users();
	}
	else
	{
		print "Debug level 3 or higher. These users would be added: \n$users_csv\n";
	}
}

# Run after we've imported any necessary users
sub process_enrollments
{
	my ($enrollment_csv);
	# Short circuit if there were no user adds
	if ($users_need_adding)
	{
		foreach my $line (@enrollments_csv)
		{
			if ($line =~ /##(\w+)##/)
			{
				$u = $1;
				if (defined($users_by_username{$u}))
				{
					$uid = $users_by_username{$u}->{sis_user_id};
					$line =~ s/##\w+##/$uid/;
				}
				else
				{
					print "ERROR: user $u not found in Canvas. Skipping enrollment for this user\n";
					next;
				}
			}
			$enrollment_csv .= "$line\n";
		}
	}
	else
	{
		$enrollment_csv = join("\n",@enrollments_csv);
	}

	if ($debug < 2)
	{
	    if (scalar(@enrollments_csv) > 1)
	    {
		print "Submitting ",scalar(@enrollments_csv)-1," enrollment changes to Canvas\n";
		my $json = rest_to_canvas("POSTRAW","/api/v1/accounts/2/sis_imports.json?extension=csv",$enrollment_csv);
	    }
	    else
	    {
		print "No enrollment changes to process\n";
	    }
	}
	else
	{
		print "Debug level 2+. These enrollments would have been processed: \n$enrollment_csv\n";
	}
}

sub summary()
{
	print "\n\nSummary:\n";
	print "Total sections processed: $total_sections\n";
	print "Total enrolments: $total_enrollments\n";
	print "Total unique users enrolled: ", scalar(keys %total_users),"\n";
}


# Utility functions below here
#


# Compare two ararys, passed in as references
# Returns two array references - one with a list of elements only in array1, and one for array2
# If both returned array references are empty, the arrays are identical
sub compare_arrays
{
	($arr1, $arr2) = @_;
	my (@diff1, @diff2,%count);
	map $count{$_}++ , @{$arr1}, @{$arr2};

	@diff1 = grep $count{$_} == 1, @{$arr1};
	@diff2 = grep $count{$_} == 1, @{$arr2};

	return \@diff1, \@diff2;
}

sub error_exit
{
	$errmsg = shift;
	print STDERR "$errmsg\n";
	print STDERR "Execution aborted\n";
	exit 1;
}
