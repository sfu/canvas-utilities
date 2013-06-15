# Library of routines to handle the API calls to Canvas

package Canvas;
require Exporter;
@ISA    = qw(Exporter);
@EXPORT = qw(rest_to_canvas rest_to_canvas_paginated rest_to_canvas_and_cache post);

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

$canvas_url = "http://localhost";

$oauth_token = $Tokens::oauth_token;
my $resp;

# Process REST calls to Canvas. 
# Takes as arguments:
#  $action = one of POST, POSTRAW (similar to POST but specifically for CSV file uploads), GET, DELETE or PUT
#  $uri = local portion of the URL to access (e.g. /api/v1/accounts/1/users)
#  $params = [optional] either the content of a CSV file or a reference to a hash of params to POST or PUT (see the Canvas API docs for list of params)
#
# Returns either the decoded JSON (e.g. a hash or array reference) or undef if there was an error

sub rest_to_canvas
{
    my ($action, $uri, $params) = @_;

    my $url = ($uri =~ /^http/) ? $uri : $canvas_url . $uri;

    my $ua = LWP::UserAgent->new( timeout => 900 );

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

# Fetch a response from Canvas that could be paginated. Can only be used with GET
sub rest_to_canvas_paginated
{
    my ($uri, $params) = @_;
    my $sep = ($uri =~ /\?/) ? '&' : '?';

    my $result = [];
    my $json_as_strings = [];
    my ($json, $json_string);

    $uri = $uri . $sep . "per_page=5000" if ($uri !~ /per_page=/);

    if ($params == 1)
    {
	($json,$json_string) = rest_to_canvas("GET",$uri,$params);
    }
    else
    {
        $json = rest_to_canvas("GET",$uri);
    }

    return $json if (!defined($json) || $json eq "0");

    while (1)
    {
	push(@{$result},@{$json});
	push(@{$json_as_strings},$json_string);

    	@links = $resp->header('Link');

    	if (!defined(@links))
        {
            if ($params == 1)
            {
                return $result,$json_as_strings;
            }
            else
            {
                return $result;
            }
        }



	print "Got a Link header: ", join("\n",@links) if $debug;

        my $next;
    	foreach $l (@links)
    	{
		if ($l =~ /<(.+)>; rel=\"next\"/)
		{
	    		$next = $1;
			$next =~ s/^https/http/i;
		}
    	}

	if (!defined($next))
	{
    	    if ($params == 1)
    	    {
    		return $result,$json_as_strings;
    	    }
    	    else
    	    {
    		return $result;
    	    }
	}

    	if ($params == 1)
    	{
		($json,$json_string) = rest_to_canvas("GET",$next,$params);
    	}
    	else
    	{
        	$json = rest_to_canvas("GET",$next);
    	}
    }

}

# Check to see if we have a cached result and if not, do standard REST call then cache
# result. Can only be used with GET operations
# Takes as arguments:
#  $uri = local portion of the URL to access (e.g. /api/v1/accounts/1/users)
#  $cache_file = absolute path to file to use to cache results (e.g /tmp/course_cache.json)
#  $maxage = maximum age of the cache_file, in seconds, before it's discarded and $uri is refetched
#
# Returns either the decoded JSON (e.g. a hash or array reference) or undef if there was an error

sub rest_to_canvas_and_cache
{
    my ($uri,$cache_file,$maxage) = @_;
    my ($json,$json_as_strings);
    if ((! -e $cache_file) || (time() - (stat($cache_file))[9]) > $maxage)
    {
	($json,$json_as_strings) = rest_to_canvas_paginated($uri,"1");
	if (defined($json) && $json ne "0")
	{
	    open(OUT,">$cache_file");
	    print OUT join("\n",@{$json_as_strings});
	    print OUT "\n";
	    close OUT;
	}
    }
    else
    {
	my $js;
	$json = [];
	open(IN,$cache_file);
	while(<IN>)
	{
	    chomp;
            eval {
                $js = json_to_perl($_);
            };
            if ($@) {
                print STDERR "Error parsing JSON from Canvas for $uri\n";
                return undef;
            }
	    push (@{$json},@{$js});
	}
	close IN;

    }
    return $json;
}

# Do POST calls to Canvas. These calls are made to the regular web UI, simulating a browser submit
# rather than to the API. As such, a cookie should be supplied for authenticated access. See Tokens.pm

sub post
{
    my ($uri,$params,$cookie) = @_;

    my $url = ($uri =~ /^http/) ? $uri : $canvas_url . $uri;

    my $ua = LWP::UserAgent->new( timeout => 900 );

    if (defined($cookie))
    {
    	$cookie_jar = HTTP::Cookies->new;

    	$cookie_jar->set_cookie(undef,"_normandy_session",$cookie,"/","localhost.local",undef,0,0,999999,0);
    	$ua->cookie_jar($cookie_jar);
    }


    print "Processing $url\n" if $debug;

    $resp = $ua->request(POST $url,
		Content_Type => 'form-data',
		Content => $params 
	);

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

        return  $jsonref;
    }
    else {
        print STDERR $resp->status_line, "\n";
        print $resp->decoded_content,"\n" if $debug;
	return undef;
    }
}


1;
