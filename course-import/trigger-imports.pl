#!/usr/bin/perl
# Upload all zip files into Canvas

use Canvas;
use Tokens qw(cookie auth_token);
use JSON::Parse 'json_to_perl'; 
use HTTP::Request::Common qw(GET POST PUT DELETE);
use LWP::UserAgent;
use HTTP::Cookies;

$status_file = "/tmp/upload_status";
$trigger_file = "/tmp/trigger_status";
$debug = 1;

# $Canvas::debug = 0;

$cookie = $Tokens::cookie;
$auth_token = $Tokens::auth_token;

die "No Cookies defined!" if (!defined($cookie));

load_status();
load_triggered();
trigger_imports();

sub trigger_imports
{
    foreach $c_id(keys %statuses)
    {
	if (defined($triggered{$c_id}))
	{
	    print "Skipping course $c_id. Already triggered\n";
	    next;
	}

	$result = do_trigger($c_id);
	if ($result)
	{
	    save_trigger($c_id);
	}
	else
	{
	    print STDERR "Failed to execute migration for course $c_id\n";
	}
    }
}

sub save_trigger
{
	$id = shift;
	open(ST,">>$trigger_file");
	print ST "$id\n";
	close ST;
}

sub load_triggered
{
	open(TR,$trigger_file) or return;
	while(<TR>)
	{
		chomp;
		$triggered{$_} = 1;
	}
	close TR;
}

sub load_status
{
	open(ST,$status_file) or return;
	while(<ST>)
	{
		chomp;
		my ($c_id,$import) = split(/:/);
		$statuses{$c_id} = $import;
	}
	close ST;
}

sub do_trigger
{
    my $c_id = shift;
    my $m_id = $statuses{$c_id};
    
    $json = post("$canvas_url/courses/$c_id/imports/migrate/$m_id/execute", {
    	"authenticity_token" => $auth_token,
    	"copy[everything]" => 1
	}, $cookie);

    return $json;
}

