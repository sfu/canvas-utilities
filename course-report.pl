#!/usr/bin/perl

use lib '/opt/amaint/etc/lib';
use Canvas;
# use awsomeLinux; 	# Local SFU library to handle SOAP calls to fetch course rosters

# $Canvas::debug=1;

# getService();

my (@all_courses);

$max_account = 20;

# First, fetch all accounts
# Stupid: API call "/api/v1/accounts" doesn't return all accounts. Need to iterate over every possible account number

for($ac_id=1;$ac_id < $max_account;$ac_id++)
{
	$ac = rest_to_canvas("GET","/api/v1/accounts/$ac_id");
	next if (!defined($ac) || $ac->{status} eq "not_found");
	$accounts_by_id{$ac_id} = $ac;
}

# Then, iterate through each account, collect the courses for that account

foreach $ac_id (sort keys %accounts_by_id)
{
	$courses = rest_to_canvas_paginated("/api/v1/accounts/$ac_id/courses?per_page=200");
	push (@all_courses,@{$courses}) if defined($courses);
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
