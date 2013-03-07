#!/usr/bin/perl

@starts = ("01-01","05-01","09-01");
@ends = ("04-30","08-31","12-31");
@names = ("Spring","Summer","Fall");

print "term_id,name,status,start_date,end_date\n";
foreach $year (6..12)
{
    $y = $year+100;
    $yr = $year+2000;
    foreach $term (0..2)
    {
	$t = 1;
	$t = 4 if ($term == 1);
	$t = 7 if ($term == 2);
	print "$y$t,$names[$term] $yr,active,$yr-$starts[$term]T00:00:00Z,$yr-$ends[$term]T00:00:00Z\n"
    }
}
