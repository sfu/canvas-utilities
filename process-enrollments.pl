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
#use awsomeLinux; 	# Local SFU library to handle SOAP calls to fetch course rosters
use Rest;		# Local SFU Library to handle RestServer calls
use Amaint; # Local SFU library to handle Amaint direct action calls
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


#--- end config ----

# Global array references for courses, sections and users
my ($courses,$sections,$users,$users_by_id,$users_by_username,$courses_by_id);

# Global vars for the CSVs that will hold user-adds and enrollment changes
my($users_csv,@enrollments_csv);
my $users_need_adding = 0;

# global var to hold computing IDs of new users for triggering UDD updates
my @new_user_computing_ids;

my ($currentTerm,$previousTerm);

# Global counters
my ($total_enrollments,%total_users,$total_sections);

getopts('cshd:f:');

$enrollments_csv_header = "course_id,user_id,role,section_id,status,associated_user_id\n";
$users_csv = "user_id,login_id,password,first_name,last_name,short_name,email,status\n";
push @sections_csv,"section_id,course_id,name,status";

# Main block
{
	if (defined($opt_h))
	{
		HELP_MESSAGE();
		exit 1;
	}
	$debug = $opt_d if (defined($opt_d));
	$Canvas::debug = ($debug > 2) ? 1 : 0;
	# getService();
	getTerm();
	fetch_courses_and_sections($opt_c) or error_exit("Couldn't fetch courses and sections from Canvas!");
	# Don't bother doing enrollment processing if we're doing a missing sections run
	exit 0 if (defined($opt_s));

	if (!defined($opt_f))
	{
		fetch_users() or error_exit("Couldn't fetch user list from Canvas!");
	}
	generate_enrollments();
	print @skipmsgs if $debug;
	process_user_adds();
	process_enrollments();
	summary();
	
	exit 0;
}

sub HELP_MESSAGE
{
	print <<EOM;
Usage:
 no arguments: 				process all enrolments for all non-completed Canvas courses and sections
           -c: 				include completed courses
	   -d [0-3]			Debug level. Default is currently 1 (verbose). 
					  2 == submit user adds but not enrolment changes. 
					  3 == submit no changes. Dump all HTTP traffic to Canvas
   -f sis_section_id[,sis_section_id]: 	process only the specified Canvas section(s). 
					this will also empty the enrolment if the data source indicates there are no enrolments
	   -s				Look for missing sections and generate a CSV to add them. Emails the CSV to Canvas Support staff
	   -h:				This message
EOM
}

# Fetch all courses and sections from Canvas unless the -f flag was
# specified, in which case just fetch the specified sections.
# For 'all sections', fetch all courses in all accounts
# then fetch all sections in each course
#
# If the -s flag was passed in, use this as an opportunity to check
# for missing setions. Fetch all sections for each course from Amaint
# (via an SFU API in Canvas) and compare

sub fetch_courses_and_sections
{
    	my (@sections);
	my $completed = shift;

	# If we're just handling a specific section or sections, don't bother fetching all courses and sections
	if (defined($opt_f))
	{
		foreach $sec (split(/,/,$opt_f))
		{
			$course_section = rest_to_canvas("GET","/api/v1/sections/sis_section_id:$sec");
			if (!defined($course_section))
			{
				print "Couldn't get section for sis_section_id $sec\n";
				return undef;
			}
			push @sections,$course_section;
		}
	}
	else
	{
	    	$courses = ();
		my $accounts = ();

		# Fetch SFU account
	    	my $acct = rest_to_canvas("GET","/api/v1/accounts/$account_id");
		push (@{$accounts},$acct);

	    	# Fetch all sub-accounts 
		# Jan 3/14: Turns out we don't need this. top-level account encompasses all courses
	    	#my $accts = rest_to_canvas_paginated("/api/v1/accounts/$account_id/sub_accounts");
		#push (@{$accounts},@{$accts});

		# Now iterate over the whole mess
		# and for each account, fetch all courses
	    	foreach $acc (@{$accounts})
	    	{
			# Skip the "Site" account
			next if ($acc->{id} == 1);
			$acc_id = $acc->{id};
			my $completed_string = ($completed) ? "" : "?completed=false";
			$acc_courses = rest_to_canvas_paginated("/api/v1/accounts/$acc_id/courses".$completed_string);
			next if (!defined($acc_courses));

			push (@{$courses},@{$acc_courses});
		}
		return undef if (scalar(@{$courses}) == 0);

		print "Retrieved ",scalar(@{$courses})," courses from Canvas\n";

		my @drops;
		push @drops,@enrollments_csv;
		my $has_drops = 0;

		# Iterate through each course, fetching all sections. 
		# If -s flag was given, compare to what should be there and create missing ones and delete extras
		foreach $course (@{$courses})
		{
			$c_id = $course->{id};
			$s_id = $course->{sis_course_id};

			# Only process courses that have a defined sis_id that's not 'sandbox'
			next if ($s_id eq "" || $s_id =~ /sandbox/);

			$courses_by_id{$c_id} = $course;
			$course_sections = rest_to_canvas_paginated("/api/v1/courses/$c_id/sections");
			if (!defined($course_sections))
			{
				print "Couldn't get sections for course $c_id\n";
				return undef;
			}
			push @sections,@{$course_sections};

			# Check for missing sections. For each course, fetch all sections and
			# compare the list to what Amaint says. Produce a list of adds and drops

			# If -s flag was given, and this course is an SIS course, and it's not cross-listed..
			if (defined($opt_s) && $s_id =~ /^\d\d\d\d/ && $s_id !~ /[^:]:[^:]/)
			{
			    # Then we can determine Amaint tutorial sections, so save what Canvas has

			    # One more check: if this course has no enrollments yet, don't add any sections (requested by TLC)
			    # (note, deliberately not using the 'paginated' call so that we only get the first 10 results)
			    my $c_en = rest_to_canvas("GET","/api/v1/courses/$c_id/enrollments");
			    if (!defined($c_en))
			    {
				print "Couldn't get enrollments for course $c_id! Skipping check for missing sections\n";
				next;
			    }
			    my $has_enrollments = scalar(@{$c_en});

			    my (@canvas_sections, @amaint_sections);
			    foreach $s (@{$course_sections})
			    {
				my $sec_id = $s->{sis_section_id};
				next if (!($sec_id =~ s/:::.*//));
				($t,$d,$c,$sect) = split(/-/,$sec_id);
				push(@canvas_sections,lc($sect));
			    }
	
			    # and fetch what Amaint has (via SFU API in Canvas)..
			    $temp = rest_to_canvas("GET","/sfu/api/v1/amaint/course/$s_id/sections");
			    if (!defined($temp))
			    {
				if ($@ =~ /^404/)
				{
				    @amaint_sections = ();
				    print "Warning: Amaint says $s_id contains no sections\n";
				}
				else
				{
				    print STDERR "unable to fetch Amaint sections for $s_id\n";
				    next;
				}
			    }

			    else
			    {
			        # lowercase it..
			        push(@amaint_sections, map lc, @{$temp->{sections}});
			    }

			    if ($debug)
			    {
				print " Canvas sections for $s_id: ",join(",",@canvas_sections,"\n");
				print " Amaint sections for $s_id: ",join(",",@amaint_sections,"\n");
			    }

			    # then compare them and generate any new sections
			    ($adds,$drops) = compare_arrays(\@amaint_sections,\@canvas_sections);
			    if (scalar(@{$adds}) || scalar(@{$drops}) )
			    {
				print "Sections to add for $s_id: ", join(",",@{$adds}),"\n" if ($debug && scalar(@{$adds}));
				print "Sections to drop for $s_id: ", join(",",@{$drops}),"\n" if ($debug && scalar(@{$drops}));
				($term,$dept,$course,$junk) = split(/-/,$s_id);
				$time = time();
				if ($has_enrollments)
				{
				    foreach $sec (@{$adds})
				    {
				        $sec_id = "$term-$dept-$course-$sec".":::$time";
				        push @sections_csv,"$sec_id,$s_id,\"".uc($dept).uc($course)." ".uc($sec)."\",active";
				    }
				    # Don't process drops if we've done adds. Otherwise, if we're adding, say D101,D102
				    # and dropping D100, a student will lose access until D101,D102 have been populated. 
				    # So we'll skip the drop and get them next time we run
				    next if (scalar(@{$adds}));
				}
				else
				{
				    print "Course $s_id appears to have no enrollments. Won't add missing sections\n" if (scalar(@{$adds}));
				}

				# section drops are much harder. Need to determine if there are any student enrollments that
				# must be deleted before the section can be deleted
				foreach $sec (@{$drops})
				{
				    my $course_has_enrollments = $has_enrollments;
				    my $ok_to_delete = 0;
				    my $s_en = $c_en;
				    # Find the dropped section in the existing sections. We need its unique SIS_ID
				    foreach $s (@{$course_sections})
				    {
                                        my $sec_id = $s->{sis_section_id};
                                        next if (!($sec_id =~ s/:::.*//));
                                        ($t,$d,$c,$sect) = split(/-/,$sec_id);
                                        if ($sect eq $sec)
                                        {
					    if (!$course_has_enrollments)
					    {
						# No enrollments in any section of the course. Definitely ok to delete this section
						$ok_to_delete = 1;
					    }
					    else
					    {
						# Some enrollments. Better check this section
						$s_en = rest_to_canvas_paginated("/api/v1/sections/".$s->{id}."/enrollments");
						if (!defined($s_en))
						{
							print STDERR "Couldn't get enrollments for section $s->{id} $sec_id! Can't determine if it's deletable\n";
							next;
						}

						if (!scalar(@{$s_en}))
						{
						    # No enrollments - ok to delete this section
						    $ok_to_delete = 1;
						}
						else
						{
						    $ok_to_delete = 1;
						    foreach (@{$s_en})
						    {
							if ($_->{type} ne "StudentViewEnrollment")
							{
						    	    $ok_to_delete = 0;
                                                            print "  Found a ",$_->{type}, " enrollment in $sec_id\n" if ($debug);
							    last;
							}
						    }
						}
					    }
					    if ($ok_to_delete)
					    {
                                                push @sections_csv,$s->{sis_section_id}.",$s_id,\"".uc($dept).uc($course)." ".uc($sec)."\",deleted";
                                                print "  ",$s->{sis_section_id},",$s_id,\"".uc($dept).uc($course)." ".uc($sec)."\",deleted\n" if ($debug);
					    }
					    else
					    {
						print "Can't delete $sec_id. Has ", scalar(@{$s_en})," enrollments\n";

						# If in current term, just don't delete populated sections at all, otherwise we could kick students
						# out of their groups due to Canvas bug
						# [ We can remove this once we go back to multi-section enrollments (i.e. student is d100+d101) 
						# because a student will always be in at least one section ]
						next if ($term == $currentTerm);

						my $en;
						$ok_to_delete=1;
						foreach $en (@{$s_en})
						{
						    fetch_user($en->{user_id});
						    my $sis_user_id = defined($users_by_id{$en->{user_id}}) ? $users_by_id{$en->{user_id}}->{sis_user_id} : "##".$en->{user_id}."##";

						    if ($sis_user_id =~ /^##/)
						    {
							print "Couldn't retrieve sis_user_id for $sis_user_id so can't drop their enrollment in $en->{sis_section_id}\n";
						    }
						    else
						    {
							my $role = "student";

							# For now, only delete student enrollments. If we delete any other type of enrollment, we
							# could inadvertently block their access to the course. If there are non-student enrollments, 
							# it'll make the section undeletable but it'll be fairly obvious why
							if ($en->{type} ne "StudentEnrollment")
							{
							    $ok_to_delete=0;
							    next;
							}
							#$role = "ta" if ($en->{type} eq "TaEnrollment");
							#$role = "teacher" if ($en->{type} eq "TeacherEnrollment");
							#$role = "designer" if ($en->{type} eq "DesignerEnrollment");

						    	# course_id, sfuid, role, section_id, status, associated_user_id(blank)
						    	push @drops, join(",", $en->{sis_course_id},$sis_user_id, $role, $en->{sis_section_id}, "deleted", "");
						    }
						}
						$has_drops=1;
						if ($ok_to_delete)
						{
						    # Section only had student enrollments, so add it to the sections to delete but mark with a '*' to
						    # indicate it can't be deleted until after enrollment deletions have been processed (i.e requires a manual decision)
                                                    push @sections_csv,$s->{sis_section_id}.",$s_id,\"".uc($dept).uc($course)." ".uc($sec)."\",deleted*";
                                                    print "  ",$s->{sis_section_id},",$s_id,\"".uc($dept).uc($course)." ".uc($sec)."\",deleted*\n" if ($debug);
						}
					    }
                                            break;
                                        }
				    }
				}
			    }
			}
		}
		if (defined($opt_s) && scalar(@sections_csv) > 1)
		{
			print "\n\n",join("\n",@sections_csv,"","");
		}
		if (defined($opt_s) && $has_drops)
		{
			print "\n\n",join("\n",@drops,"","");
		}
	}

	print "Retrieved ",scalar(@sections), " sections from Canvas\n";

	$sections = \@sections;

	return 1;
}

# Fetch all users from Canvas. In theory, all users should be in Canvas
# so we could fetch them from Amaint (which might be faster), but there's 
# always a chance a user didn't get added via the real-time JMS sync,
# so we fetch them from Canvas. If any are found to be missing during
# the enrollment process, they're added at that point

sub fetch_users
{
	$users = rest_to_canvas_paginated("/api/v1/accounts/$account_id/users");
	return undef if (!defined($users));
	print "Fetched ",scalar(@{$users})," users from Canvas\n";
	foreach $u (@{$users})
	{
		# Don't include users that don't have an SIS ID (SFUID) defined unless they're external users. Forces local users to be reimported if they're in any courses)
		if ($u->{sis_user_id} || $u->{login_id} =~ /@/)
		{
			$users_by_username{$u->{login_id}} = $u;
			$users_by_id{$u->{id}} = $u;
		}
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
	if ($user->{sis_user_id} || $user->{login_id} =~ /@/)
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

	$currentTerm = "1$year$term";
	$previousTerm = "1$prevyear$prevterm";
	print "Date: $year/$moday\nCurrent Term: $currentTerm\nPrevious Term: $previousTerm\n" if ($debug);
}
	

# The meat of the matter. Iterate through sections comparing their enrollments to what they should be
# Once finished, we'll have a users.csv and an enrollments.csv that each need to be processed.
#
# We also check for observer roles in *any* section of a course. Observers are used for Auditors of a
# course. They *may* also show up in the SIMS feed. If they do, don't re-add them as a student
#
# Support for manually added students: Students with no sis_import_id defined are treated almost identically
# to observers, but are kept in a separate hash. For any 'manual' user who is enrolled in any section of a given
# course and then shows up in the SIS source, they'll be deleted from the sections they were enrolled in manually,
# then added to the section(s) via CSV. Since deleting a manual enrollment deletes the user from their groups,
# we retrieve their group memberships before deleting them, then reactivate those memberships after the delete is
# done. This is all handled by the 'check_observers' function each time we get to the end of the sections for a course
#
# Teacher/designer/TA enrollments are checked by accumulating them as each section of a course is scanned. If
# a user shows up in the SIS source who is already in the teachers list, they won't be added as a student. But
# if they show up in the SIS source for a section that's processed before the section they're enrolled as a teacher
# in, then they'll get added. This shouldn't be a problem though as teachers are supposed to be enrolled in the
# default section going forward (which is always the first one fetched for a course)

sub generate_enrollments
{
	my ($c_id,$old_c_id,@all_enrollments,%observers,%manuals,%teachers,$new_students);
	my $force = 0;

	foreach $section (@{$sections})
	{
		my ($maillist,$term,$dept,$course,$sect);

		$sis_id = $section->{'sis_section_id'};
		$c_id = $section->{'course_id'};
		if ($c_id != $old_c_id)
		{
			# Starting a new course. See if there were any manuals in the last course
			check_observers(\%manuals,\@all_enrollments,1);
			check_teachers(\%teachers,\@all_enrollments,$course_by_id{$old_c_id}->{sis_course_id}) if ($new_students);
			$old_c_id = $c_id;
			%manuals = ();
			%teachers = ();
			@all_enrollments = ();
			$new_students = 0;
		}

		$force = 0;
		$force = 1 if (defined($opt_f));

		# We have to look in the default section for manual enrollments and teachers, but
		# that's all we do with the default section
		$check_for_manuals = ($sis_id eq "null" || $sis_id eq "") ? 1 : 0;

		if (!$check_for_manuals && $sis_id !~ /:::/)
		{
			push @skipmsgs,"Skipped section \"".$section->{name}."\" with sis_section_id $sis_id in course ID $c_id. Missing ':::' delimiter\n";
			next;
		}
		else
		{
			$delete_enrollments = ($sis_id =~ /:::REMOVE$/);
			$sis_id =~ s/:::.*//;
		}

		print "Processing $sis_id, Name: ",$section->{name},"\n" if $debug;


		if ($sis_id =~ /^(list:|group:|file:)/)
		{
			# Special cases -- 'type:source' is supported
			($type,$type_source) = split(/:/,$sis_id,2);
		}
		elsif (!$check_for_manuals)
		{
			$type = "term";
			($term,$dept,$course,$sect) = split(/-/,$sis_id);

			# Do some basic sanity checks on the sis_section_id
			if ($term !~ /^\d+$/ || $dept !~ /^[a-zA-Z0-9]+$/ || $course !~ /^[xX]*\d+\w?$/ || $sect !~ /^[a-zA-Z0-9]+$/) 
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
			print STDERR "Error retrieving enrollments for section \"",$section->{name},"\" in course ID ",$section->{'course_id'},". SKIPPING\n";
			next;
		}

		# Generate a list of usernames that are currently in the course
		my (@current_enrollments,@current_observers);
		foreach $en (@{$enrollments})
		{
			my $res = 1;
			# If we're force-handling just specific sections, fetch each user as we encounter them if necessary
			if ($force && !defined($users_by_id{$en->{user_id}}))
			{
				print "Fetching $en->{user_id} from Canvas\n" if ($debug > 1);
				$res = fetch_user($en->{user_id});
				if (!$res)
				{
					# This should never happen (communcations error with Canvas maybe?)
					# but we can't retrieve a user that Canvas just told us is registered in the course
					# Throw a big fat error 
					print STDERR "Unable to retrieve user ",$en->{user_id}," from Canvas! Can't continue\n";
					return undef;
				}
			}

			if ($en->{type} eq "ObserverEnrollment")
			{
				push @current_observers,$users_by_id{$en->{user_id}}->{login_id};
				next;
			}
			# Was this enrollment a manual student one?
                        if (exists($en->{sis_import_id}) && ($en->{sis_import_id} eq "") && ($en->{type} eq "StudentEnrollment"))

			{
				# %manual is a hash whose values are arrays of enrollments for a given course
				print "Found manual student $users_by_id{$en->{user_id}}->{login_id}\n" if ($debug > 1);
				$manuals{$users_by_id{$en->{user_id}}->{login_id}} = () if (!defined($manuals{$users_by_id{$en->{user_id}}->{login_id}}));
				push(@{$manuals{$users_by_id{$en->{user_id}}->{login_id}}}, $en);
				next;
			}

			# Track the teachers/designers separately as well
			$teachers{$users_by_id{$en->{user_id}}->{login_id}}++ if ($en->{type} ne "StudentEnrollment" && $en->{type} ne "StudentViewEnrollment");

			next if ($check_for_manuals);

			push (@current_enrollments, $users_by_id{$en->{user_id}}->{login_id}) if ($en->{type} eq "StudentEnrollment");
		}
		print "Users in section: \n",join(",",sort @current_enrollments),"\n" if $debug;

		# If we're just checking this section for manual enrollments, we're done. Move onto the next section
		next if ($check_for_manuals);

		# Grab new enrollments from source

		my $failed=0;

		if ($delete_enrollments)
		{
		    @new_enrollments = ();
		    print "DELETING all enrollments for ",$section->{name},"\n" if ($debug);
		}
		else
		{
		    switch ($type) {
		        case "list" {
			    my $newenrl = SFU_members_of_maillist($type_source);
			    if (!defined($newenrl))
			    {
				print STDERR "Error retrieving enrollments for $sis_id from RestServer. Skipping!\n";
				$failed=1;
			    }
			    @new_enrollments = @{$newenrl};
			    # @new_enrollments = split(/:::/,membersOfMaillist($type_source));
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
				$failed=1;
			    }
			    break;
		        }
		        case "group" {
			    print STDERR "Groups not implemented yet\n";
			    break;
		        }
		        case "term" {
			    my $newenrl = roster_for_section($dept,$course,$term,$sect);
			    if (!defined($newenrl))
			    {
				print STDERR "Error retrieving enrollments for $sis_id from RestServer. Skipping!\n";
				$failed=1;
			    }
			    @new_enrollments = @{$newenrl};
			    # @new_enrollments = split(/:::/,rosterForSection($dept,$course,$term,$sect));
			    break;
		        }
		    }
		}

		next if $failed;
		# Regex means that tutorial/lab sections that drop to 0 enrollment WILL be automatically processed
		if (scalar(@new_enrollments) == 0 && !$force && ($type ne "term" || $sect =~ /00$/) && !$delete_enrollments)
		{
			# Only print a warning if Canvas course does have enrollments
			print STDERR "New Enrollments for $sis_id is empty! Won't process without \'force\'\n" if (scalar(@current_enrollments) > 0);
			next;
		}

		print "New enrollments for ",$section->{name},": \n",join(",",sort @new_enrollments),"\n" if $debug;

		foreach $en (@new_enrollments)
		{
			$total_users{$en}++;
		}

		$total_enrollments += scalar(@new_enrollments);

		# Observers are now Audit students. Add them to both arrays to ensure they don't 
		# get flagged for either addition or removal
		push(@new_enrollments,@current_observers);
		push(@current_enrollments,@current_observers);
		
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
			$new_students++;
		}
		if (scalar(@new_users))
		{
			print "Adding ",scalar(@new_users)," new users for section ",$section->{name},"\n";
			add_new_users(@new_users);
		}

		# Now convert the adds and drops into enrollments and de-enrollments
		print "Processing ",scalar(@{$adds})," Adds and ",scalar(@{$drops})," Drops for section ",$section->{name},"\n";
		drop_enrollments($drops,$section,\%teachers);
		add_enrollments($adds,$section,\%teachers);

	}
	check_observers(\%manuals,\@all_enrollments,1);
	check_teachers(\%teachers,\@all_enrollments,$course_by_id{$c_id}->{sis_course_id}) if ($new_students);
}


# Add an array of new users to the CSV file. Uses Amaint to fetch info about each user
sub add_new_users
{
	my @adds = @_;
	foreach my $user (@adds)
	{
		# my ($roles,$sfuid,$lastname,$firstnames,$givenname) = split(/:::/,infoForComputingID($user)); 
		my ($roles,$sfuid,$lastname,$firstnames,$givenname) = split(/:::/,info_for_computing_id($user)); 
		if ($roles !~ /[a-z]+/)
		{
			print STDERR "Got back invalid response from infoForComputingID for $user. Skipping add\n";
			next;
		}
		$givenname .= " $lastname" if ($givenname ne "");
		#user_id,login_id,password,first_name,last_name,email,status\
		print "Adding new user to csv: $sfuid,$user,$firstnames,$lastname,$givenname\n" if $debug;
		$users_csv .= "$sfuid,$user,,$firstnames,$lastname,$givenname,$user\@sfu.ca,active\n";
		$users_need_adding++;

		# keep track of new user computing IDs so that we can trigger account updates later
		push @new_user_computing_ids, $user;

		# Bit of a hack, but we want to avoid pulling all users from Canvas if we're just
		# processing one section, so add the users directly to our internal hashes
		if (defined($opt_f))
		{
			$users_by_username{$user} = { "sis_user_id" => $sfuid };
		}
					
	}
}


# Handle deleting Observers or "Manual students" who now show up in the SIS feed.
# $observers = ref to hash of either section objects (observers) or array of enrollment objects (manuals). Key is SFU computing ID
# $all_enrollments = ref to array of all SFU computing IDs in SIS source
# $manual = boolean flag - set to '1' for 'manual student' processing
#
# If we find a match in the Observers ref and all_enrollments ref:
#  - for Observer: add record to sis_import to delete observer enrollment
#  - for Manual: do API call to enrollment api to delete each enrollment in array 

sub check_observers
{
	my ($observers,$all_enrollments,$manual) = @_;
	if (scalar(keys %{$observers}))
	{
	    print "Processing observer/manuals\n" if ($debug > 1);
	    # There were observers in the previous course, see if any got added as students
	    my (%count,@dups);
	    map $count{$_}++ , keys %{$observers}, @{$all_enrollments};
	    @dups = grep $count{$_} == 2, keys %{$observers};
	    if (scalar(@dups))
	    {
		print "  Processing ",scalar(@dups)," users\n" if ($debug > 1);
		foreach my $dup (@dups)
		{
		    if ($manual)
		    {
		   	@groups = (); $gotem=0;
			foreach $en (@{$observers->{$dup}})
			{
			    # First, retrieve the list of group memberships for this user
			    # (only do this once if there are multiple manual enrollments for this user in this course)
			    if (!$gotem)
			    {
			    	$group_memberships = rest_to_canvas_paginated("/sfu/api/v1/user/$dup/groups");
				$gotem++;
			    	if (defined($group_memberships))
			    	{
				    # Save the group memberships that match the current course
				    foreach $grp (@{$group_memberships})
				    {
				        push @groups,$grp->{group_membership_id} if (lc($grp->{context_type}) eq "course" && $grp->{context_id} == $en->{course_id});
				    }
			    	}
			    }
	
			    # Now process the unenrollment of the manually added user
			    print "Deleting Manual Student $dup from section ",$en->{section_id},"\n" if ($debug);
			    if ($debug < 3) 
			    {
			    	$res = rest_to_canvas("DELETE","/api/v1/courses/".$en->{course_id}."/enrollments/".$en->{id}."?task=delete");
			    	if (!$res)
			    	{
			    	    print STDERR "Error deleting enrollment $en->{id} for $dup but there's nothing I can do. Continuing\n";
			    	}
			    }
			}
			# Deleting the manual enrollment(s) removes the user from their course-related groups, so flip those
			# group membership states from 'deleted' back to 'active'
			foreach $grp (@groups)
			{
			    $res = rest_to_canvas("PUT","/sfu/api/v1/group_memberships/$grp/undelete");
			    print STDERR "Couldn't undelete group membership $grp for user $dup\n" if (!defined($res));
			}
		    }
		    else
		    {
			print "Deleting Observer $dup from ",$observers->{$dup}->{sis_section_id},"\n" if ($debug);
		    	do_enrollments([$dup],$observers->{$dup},{},"deleted","observer");
		    }
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
	my ($users,$section,$teachers,$status,$role) = @_;

	$role = "student" if (!defined($role));

	foreach my $user (@{$users})
	{
		# If we were given a list of teachers, don't add or drop them
		if (defined($teachers))
		{
			if (defined($teachers->{$user}))
			{
				print "Not processing Teacher: $user\n" if ($debug);
				next;
			}
		}
		my $user_id = defined($users_by_username{$user}) ? $users_by_username{$user}->{sis_user_id} : "##$user##";

		# course_id, sfuid, role, section_id, status, associated_user_id(blank)
		push @enrollments_csv, join(",", $courses_by_id{$section->{course_id}}->{sis_course_id},$user_id, $role, $section->{sis_section_id}, $status, "");
	}
}


# After a course has been processed, check to see if any teachers
# show up in the enrollments list. If they do, delete them from the 
# enrollments_csv file so they don't get added as students
#
# Under exceedingly rare conditions, this can prevent a user from
# being enrolled as a student in another course:
#  - the user must be both a teacher and a student in a course ("course A")
#  - the user must be a student in another course ("course B")
#  - the user must not have been enrolled in course B before being added as a teacher in course A
#  - course B must be processed by this script before course A
# Because this code just walks the csv file looking for student enrollments, it will remove the "add" to
# course B when it removes the student enrollment from course A

sub check_teachers
{
	my ($teachers,$all_enrollments,$sis_course_id) = @_;
	# exit fast if there are no teachers
	return if (!scalar(keys %{$teachers}));

	my (%count,@dups);
	map $count{$_}++ , keys %{$teachers}, @{$all_enrollments};
	@dups = grep $count{$_} == 2, keys %{$teachers};
	# We found some teachers who are also students. Delete them from our CSV if they're there
	# (we can't delete them if they've already been enrolled as we don't know here what section they're in)
	if (scalar(@dups))
	{
		foreach my $dup (@dups)
		{
                        print " Removing Teacher $dup from student enrollment CSV\n"; # if ($debug);
			my $user_id = defined($users_by_username{$dup}) ? $users_by_username{$dup}->{sis_user_id} : "##$user##";
			@enrollments_csv = grep {!/$sis_course_id,$user_id,/} @enrollments_csv;
		}
	}
}

# Send users.csv to Canvas and wait for it to complete processing
# We're only willing to wait so long though before we throw an error
sub process_user_adds
{
	return if (!$users_need_adding || defined($opt_f));
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

		# Fire a UDD update for each imported user. 
		# This is so that the amaint-canvas-jms process will 
		# create communication channels for the new users.
		# This is easier than getting the Canvas user ID of 
		# each new user and publishing a CREATE_CANVAS_COMMUNICATION_CHANNEL message manually
		push_account_updates(@new_user_computing_ids);
		
	}
	else
	{
		print "Debug level 3 or higher. These users would be added: \n$users_csv\n";
	}
}

# Run after we've imported any necessary users
sub process_enrollments
{
	my (@enrollment_csvs);
	my $batch = 0;
	
	$enrollment_csvs[$batch] = $enrollments_csv_header;

	$linecount = 0;
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
		$enrollment_csvs[$batch] .= "$line\n";
		$linecount++;
		# Break the CSV files into batches no larger than 1000 lines each to avoid hardcoded Canvas batch size limit
		if (! ($linecount % 1000))
		{
			$batch++;
			$enrollment_csvs[$batch] = $enrollments_csv_header;
		}
	}
	

	if ($debug < 2)
	{
	    if (scalar(@enrollments_csv) > 1)
	    {
			print "Submitting ",scalar(@enrollments_csv)-1," enrollment changes to Canvas in ",$batch+1," batches\n";
			foreach $b (0..$batch)
			{
				my $json = rest_to_canvas("POSTRAW","/api/v1/accounts/2/sis_imports.json?extension=csv",$enrollment_csvs[$b]);
				sleep 5;
			}
	    }
	    else
	    {
			print "No enrollment changes to process\n";
	    }
	}
	else
	{
		print "Debug level 2+. These enrollments would have been processed: \n";
		foreach $b (0..$batch)
		{
			print "Batch $b\n";
			print $enrollment_csvs[$b],"\n\n";
		}
	}
}

sub summary()
{
	print "\n\nSummary:\n";
	print "Total sections processed: $total_sections\n";
	print "Total enrolments: $total_enrollments\n";
	print "Total unique users enrolled: ", scalar(keys %total_users),"\n";
}

sub push_account_updates
{
	foreach my $username (@new_user_computing_ids) 
	{
		print "Pushing account update for user $username" if $debug;
		my $resp = push_account_update($username);
		if ($resp eq "ok") {
			print "Account update pushed for $username" if $debug;
		}
	}
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
