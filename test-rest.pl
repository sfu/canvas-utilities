#!/usr/bin/perl
use lib '/opt/amaint/etc/lib';
use Rest;

$Rest::debug = 1;

$sis_id = $ARGV[0];

$members = members_of_maillist("icat-developers");

if (!defined($members))
{
	print STDERR "not able to retrieve members!\n";
}
else
{
	print join(",",@{$members});
}

if ($sis_id)
{
	$sis_id =~ s/:::.*//;
	@fields = split(/-/,$sis_id);
	$members = roster_for_section($fields[1],$fields[2],$fields[0],$fields[3]);
}
else
{
	$members = roster_for_section("MATH","100","1137","D100");
}


if (!defined($members))
{
	print STDERR "not able to retrieve Roster!\n";
}
else
{
	print join(",",@{$members});
}

print "\n",info_for_computing_id("kipling");
