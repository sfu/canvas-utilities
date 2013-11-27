#!/usr/bin/perl
use lib '/opt/amaint/etc/lib';
use Rest;

$Rest::debug = 1;

$members = members_of_maillist("icat-developers");

if (!defined($members))
{
	print STDERR "not able to retrieve members!\n";
}
else
{
	print join(",",@{$members});
}

$members = roster_for_section("MATH","100","1137","D100");


if (!defined($members))
{
	print STDERR "not able to retrieve Roster!\n";
}
else
{
	print join(",",@{$members});
}

print "\n",info_for_computing_id("kipling");
