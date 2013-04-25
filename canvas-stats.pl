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
my ($total_enrollments,%total_users,$total_sections,$course_seats);

getopts('chf:t:');

push @enrollments_csv,"course_id,user_id,role,section_id,status,associated_user_id";
$users_csv = "user_id,login_id,password,first_name,last_name,email,status\n";

# Main block
{
	if (defined($opt_h))
	{
		HELP_MESSAGE();
		exit 1;
	}
	$currentTerm = (defined($opt_t)) ? $opt_t : getTerm();
	fetch_courses_and_sections($opt_c) or error_exit("Couldn't fetch courses and sections from Canvas!");
	fetch_enrollments();
	summary();
	
	exit 0;
}

sub HELP_MESSAGE
{
	print <<EOM;
Usage:
 no arguments: 				produce stats on all enrolments
   -t term: 				Limit stats to a particular term (1131, 1137, etc)
   -f sis_section_id[,sis_section_id]: 	process only the specified Canvas section(s). 
   -c:					include completed courses (will take MUCH longer)
   -h:					This message
EOM
}

sub fetch_courses_and_sections
{
    	my (@sections);
	my $completed = shift;

	my $completed_string = ($completed) ? "" : "?completed=false";
	$courses = rest_to_canvas_paginated("/api/v1/accounts/$account_id/courses".$completed_string);
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

# Fetch a single user by Canvas userID. Adds the user to our internal hashes
sub fetch_user
{
	$u_id = shift;
	return undef if ($u_id < 1);
	$user = rest_to_canvas("GET","/api/v1/users/$u_id/profile");
	return undef if (!defined($user));
	if ($user->{sis_user_id})
	{
		$users_by_username{$user->{login_id}} = $user;
		$users_by_id{$user->{id}} = $user;
	}

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

	return "1$year$term";
}
	

# The meat of the matter. Iterate through sections fetching their enrollments 
#

sub fetch_enrollments
{
	my ($c_id,$old_c_id,%all_enrollments,%observers);
	my $force = 0;

	foreach $section (@{$sections})
	{
		my ($maillist);

		$sis_id = $section->{'sis_section_id'};
		$c_id = $section->{'course_id'};
		if ($c_id != $old_c_id)
		{
			# Starting a new course. Sum results for last course
			$total_courses++;
			$old_c_id = $c_id;
			$course_seats += scalar(keys %all_enrollments);
			%all_enrollments = {};
		}

		$force = 0;
		$force = 1 if (defined($opt_f));

		# We calculate stats on all sections, but we'll track sis and non-sis courses differently

		$type = "";
		if ($sis_id !~ /:::/)
		{
			$is_sis = 0;
		}
		else
		{
			$sis_id =~ s/:::.*//;
			$is_sis = 1;
		}

		print "Processing $sis_id, Name: ",$section->{name},"\n" if $debug;


		if ($is_sis && $sis_id !~ /^(list:|group:|file:)/)
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
			if ($term < $currentTerm || (defined($opt_t) && $term != $currentTerm))
			{
				print "Skipping $sis_id from a previous term\n" if $debug;
				next;
			}
		}

		# If doing a specific term, skip over non-sis sections
		next if (defined($opt_t) && $type ne "term");
	
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
		foreach $en (@{$enrollments})
		{
			if ($en->{type} eq "ObserverEnrollment")
			{
				$observers++;
			}
			if ($en->{type} ne "StudentEnrollment")
			{
				$designer_or_teacher++;
				next;
			}
			$all_enrollments{$en->{user_id}}++;
			$total_enrollments++;
			$total_users{$en->{user_id}}++;
		}

	}
}


sub summary()
{
	print "\n\nSummary:\n";
	print "Total sections processed: $total_sections\n";
	print "Total courses: $total_courses\n";
	print "Total enrolments: $total_enrollments\n";
	print "Total teachers and designer enrolments: $designer_or_teacher\n";
	print "Total Observer enrolments: $observers\n";
	print "Total course seats: $course_seats\n";
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
