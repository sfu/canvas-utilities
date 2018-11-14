# Library of routines to handle making Direct Action calls to Amaint

package Amaint;
require Exporter;
@ISA    = qw(Exporter);
@EXPORT = qw(push_account_update);

use LWP::UserAgent;

# Find the lib directory above the location of myself. Should be the same directory I'm in
# This isn't necessary if these libs get installed in a standard perl lib location
use FindBin;
use lib "$FindBin::Bin/../lib";
use Tokens;

# Set to 1 to see all content that's received from Canvas
$debug=0;

$amaint_url = "https://amaint.sfu.ca/cgi-bin/WebObjects/Amaint.woa/wa";

my $gateway_password = $Tokens::gateway_password;
my $resp;

# Make an `accountUpdate` direct action call to Amaint
# Takes as arguments:
#  $username = string computing ID of the target user
sub push_account_update {
  my $username = shift;
  print "Processing push_account_update for computing ID $username\n" if $debug;

  my $uri = $amaint_url .= "/pushAccountUpdate?username=$username&gatewayPassword=$gateway_password";
  print "$uri\n" if $debug;

  my $ua = LWP::UserAgent->new( timeout => 20 );
  $resp = $ua->get($uri);
  if ($resp->is_success) { 
    print "Account update pushed: ", $resp->decoded_content, "\n" if $debug;
    return $resp->decoded_content;
  } else {
    print STDERR $resp->status_line, "\n";
    print $resp->decoded_content, "\n" if $debug;
    return undef;
  }
}

1;