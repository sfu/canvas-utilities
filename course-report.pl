#!/usr/bin/perl

use lib '/opt/amaint/etc/lib';
use Canvas;
# use awsomeLinux; 	# Local SFU library to handle SOAP calls to fetch course rosters

# $Canvas::debug=1;

# getService();

my (@all_courses);

# First, fetch all accounts

$accounts = rest_to_canvas("GET","/api/v1/accounts");

die "Couldn't retrieve accounts" if (!defined($accounts));

# Then, iterate through each account, collect the courses for that account

foreach $ac (@{$accounts})
{
	$ac_id = $ac->{id};
	$courses = rest_to_canvas_paginated("/api/v1/accounts/$ac_id/courses");
	push (@all_courses,@{$courses}) if defined($courses);
	$accounts_by_id{$ac_id} = $ac;
}

# Now we have all courses for all accounts

print "Name,Term,Sub-Account,Teachers,Teacher-Emails\n";

foreach $course (@all_courses)
{
	# Skip WEBCT courses
	next if ($course->{name} =~ /\(WebCT\)/);
	
	# Fetch full course details including term
	my $id = $course->{id};
	my $course_info = rest_to_canvas("GET","/api/v1/courses/$id?include[]=term");
	$enrollments = rest_to_canvas_paginated("/api/v1/courses/$id/enrollments?type[]=TeacherEnrollment");
	my $teachers = ""; my $teacher_emails = "";
	if (defined($enrollments))
	{
		my (@teachers, @teacher_emails);
		foreach $en (@{$enrollments})
		{
			push (@teachers, $en->{user}->{name});
			push (@teacher_emails, $en->{user}->{login_id}."\@sfu.ca");
		}
		$teachers = join(";",@teachers);
		$teacher_emails = join(";",@teacher_emails);
	}

	# Finally, print out the result in CSV format
	print   $course->{name}.",";
	print	$course_info->{term}->{name}.",";
	print	$accounts_by_id{$course_info->{account_id}}->{name};
	print	",\"$teachers\",\"$teacher_emails\"\n";
#	print   $course->{name}.",".  $course_info->{term}->{name}.",".  $accounts_by_id{$course_info->{account_id}}->{name}.  ",\"$teachers\",\"$teacher_emails\"\n";
}
