#!/usr/bin/perl
#
# Simple script to send a CSV file to Canvas for SIS Import

use lib '/opt/amaint/etc/lib';
use Canvas;

$file = shift;
open (IN,$file) or die "Can't open $file\n";

$csv = join("",<IN>);

$json = rest_to_canvas("POSTRAW","/api/v1/accounts/2/sis_imports.json?extension=csv",$csv);
print "Sleeping 10 seconds to see if import completes\n";
sleep 10;
print "Import status:\n";
$id = $json->{id};
$json = rest_to_canvas("GET","/api/v1/accounts/2/sis_imports/$id");

printhash ($json);
print "\n\n";
exit 0;

sub printhash
{
   my ($hash,$spaces) = @_;
   if ($hash =~ /HASH/)
   {
     foreach $k (keys %{$hash})
     {
	if ($hash->{$k} =~ /HASH/)
	{
		print "$spaces $k:\n";
		printhash($hash->{$k},$spaces."  ");
	}
	elsif ($hash->{$k} =~ /ARRAY/)
	{
		print "$spaces $k:\n";
		foreach my $arr (@{$hash->{$k}})
		{
		    printhash($arr,$spaces."  ");
		}
	}
	else
	{
	    print "$spaces $k: ",$hash->{$k},"\n";
	}
     }
   }
   elsif ($hash =~ /ARRAY/)
   {
		foreach my $arr (@{$hash})
		{
		    printhash($arr,$spaces."  ");
		}
   }
   else
   {
	print "$spaces $hash\n";
   }
}
