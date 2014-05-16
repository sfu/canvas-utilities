# Library of routines to handle the API calls to Canvas

package Rest;
require Exporter;
@ISA    = qw(Exporter);
@EXPORT = qw(rest_to_restserver members_of_maillist SFU_members_of_maillist roster_for_section info_for_computing_id);

use HTTP::Request::Common qw(GET POST PUT DELETE);
use LWP::UserAgent;
use JSON::Parse 'json_to_perl';

# Find the lib directory above the location of myself. Should be the same directory I'm in
# This isn't necessary if these libs get installed in a standard perl lib location
use FindBin;
use lib "$FindBin::Bin/../lib";
use Tokens;

# Set to 1 to see all content that's received from Canvas
$debug=0;

$restserver_url = "https://rest.its.sfu.ca/cgi-bin/WebObjects/AOBRestServer.woa/rest";

$oauth_token = $Tokens::restserver_token;
my $resp;

# Process REST calls to SFU AOBRestServer
# Takes as arguments:
#  $action = one of POST, POSTRAW (similar to POST but specifically for CSV file uploads), GET, DELETE or PUT
#  $uri = local portion of the URL to access (e.g. /classroster.js?term=1141&course=CMNS800D100)
#  $params = [optional] pass in params this way or via directly embedding them in the $uri above
#
# Returns either the decoded JSON (e.g. a hash or array reference) or undef if there was an error

sub rest_to_restserver
{
    my ($action, $uri, $params) = @_;

    my $url = ($uri =~ /^http/) ? $uri : $restserver_url . $uri;

    my $sep = ($uri =~ /\?/) ? "&" : "?";

    $url .= $sep."art=$oauth_token";

    my $ua = LWP::UserAgent->new( timeout => 20 );

    print "Processing $url\n" if $debug;

    if ($action eq "POST")
    {
	$resp = $ua->request(POST $url,
		Authorization => "Bearer $oauth_token",
		Content_Type => 'form-data',
		Content => $params 
	);
    }
    elsif ($action eq "POSTRAW")
    {
	# Special for SIS csv file uploads
	$resp = $ua->request(POST $url,
		Authorization => "Bearer $oauth_token",
		Content_Type => 'text/csv',
		Content => $params 
	);
    }
    elsif ($action eq "GET")
    {
	$resp = $ua->request(GET $url,
		Authorization => "Bearer $oauth_token"
	);
    }

    elsif ($action eq "DELETE")
    {
	$resp = $ua->request(DELETE $url,
		Authorization => "Bearer $oauth_token"
	);
    }
    if ($action eq "PUT")
    {
	if (defined($params))
	{
	    $resp = $ua->request(PUT $url,
		Authorization => "Bearer $oauth_token",
		Content_Type => 'form-data',
		Content => $params 
	    );
	}
	else
	{
		$resp = $ua->request(PUT $url,
			Authorization => "Bearer $oauth_token"
		);
	}
    }

    if ($resp->is_success) {
	my $jsonref;
	my $json = $resp->decoded_content;
	print "$json\n" if $debug;

	if ($json eq "0")
	{
		print "No JSON returned from call to $uri\n" if $debug;
	}
	eval {
		$jsonref = json_to_perl($json);
	};
	if ($@) {
		print STDERR "Error parsing JSON from Canvas for $uri\n";
		return undef;
	}

	if ($action eq "GET" && $params == 1)
	{
	    return $jsonref, $json;
	}

        return  $jsonref;
    }
    else {
        print STDERR $resp->status_line, "\n";
        print $resp->decoded_content,"\n" if $debug;
	return undef;
    }
}

sub members_of_maillist
{
    my $list = shift;
    my $members = rest_to_restserver("GET","/maillist/members.js?listname=$list");

    return $members;
}

sub SFU_members_of_maillist
{
    my $list = shift;
    my $result = [];
    my $members = members_of_maillist($list);
    foreach (@{$members})
    {
	push (@{$result},$_) if (!/\@/);
    }
    return $result;
}

# my ($roles,$sfuid,$lastname,$firstnames,$givenname) = split(/:::/,infoForComputingID($user));

sub info_for_computing_id
{
    my $uid = shift;
    my $userBio = rest_to_restserver("GET","/datastore2/global/userBio.js?username=$uid");

    return undef if (!defined $userBio);

    return (join(":::",	join(",",@{$userBio->{'roles'}}), 
		       	$userBio->{'sfuid'}, 
			$userBio->{'lastname'}, 
			$userBio->{'firstnames'},
			$userBio->{'commonname'})
		);
}

# enrollments = split(/:::/,rosterForSection($dept,$course,$term,$sect));

sub roster_for_section
{
    my ($dept,$course,$term,$sect) = @_;
    my @enrollments = ();

    my $roster = rest_to_restserver("GET","/classroster.js?term=$term&course=$dept$course$sect");

    return undef if (!defined($roster));

    foreach my $student (@{$roster})
    {
	push(@enrollments,$student->{'username'});
    }

    return \@enrollments;
}

1;
