#!/usr/bin/perl
#
# This script launches the process-enrollments script. Depending on what
# host it's run on, what day of the week it is, and what time it is, the
# options are different. A crontab to capture all of this was getting
# too messy and hence we have this script
#
# This script expects to get invoked about hourly and will run the
# enrollment processing with the minimum set of options unless the
# current day/time matches specified patterns

$hostname = `hostname -s`;
chomp($hostname);
$debug = 0;

$stderr = "/tmp/process-enrollments.err";
$stdout = "/tmp/process-enrollments.out";
$cmd = "/opt/amaint/etc/process-enrollments.pl";
$error_email = "hillman\@sfu.ca,mstanger\@sfu.ca,andrewleung\@sfu.ca";
$info_email = "hillman\@sfu.ca,mstanger\@sfu.ca,andrewleung\@sfu.ca,mluck\@sfu.ca";

($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime(time);

# At 4am, we run with debug=1 to give verbose output
$debug = 1 if ($hour == 4);

# At 6am, we process missing sections
$sections = 1 if ($hour == 6);

# Only run under prod conditions if host is canvas-mp
$prod = 1 if ($hostname =~ /canvas-mp(\d*)/);
# Exit if we're not running on the first canvas-m node
exit 0 if ($1 > 1);

# Exit unless we're running on Prod or it's 4am (stage and test run at 4am only)
exit 0 unless ($hour == 4 || $prod);

# On Sundays, process ALL courses not just non-completed ones
$completed = 1 if ($wday == 0 && $hour == 4);

# We only email the Canvas queue if the stderr output changes between runs
if (-e $stderr)
{
    system("mv $stderr $stderr.old");
}
else
{
    system("touch $stderr.old");
}

$opts = "-d $debug ";
$opts .= "-s " if ($sections);
$opts .= "-c " if ($completed);

# Run it!
#print("$cmd $opts > $stdout 2> $stderr");
system("$cmd $opts > $stdout 2> $stderr");

# See if STDERR changed between runs
$junk = `diff $stderr.old $stderr > /dev/null 2>&1`;
if ($?)
{
    # Files are different, we have new errors
    system("cat $stderr | mail -s \"Errors from process-enrollments script on $hostname\" $error_email");
}

# Check to see whether there were any new sections in the output
if ($sections)
{
    $junk = `grep "course_id" $stdout`;
    $sections = ! $?;
}

# See if script produced any enrollment changes. If not, exit quietly
$junk = `grep "No enrollment changes to process" $stdout`;
exit 0 if (!$sections && $? == 0 );

system("cat $stdout | mail -s \"Results of process-enrollments script on $hostname\" $info_email");
