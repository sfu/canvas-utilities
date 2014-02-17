#!/usr/bin/perl
#
# Process JMS messages from Amaint
# Connect to the JMS Broker at either the $primary_host or $secondary_host and wait
# for messages. Upon receipt of a message, process it as either a user update 
# (from Amaint) or enrollment update (from Grouper)
#
# Currently, user updates are done using the SIS Import API call rather than the
# user API calls. The SIS Import allows us to send updates exactly the same
# way as new-user creates so we don't have to care whether a user exists in
# Canvas yet before sending the update. 
#
# A future revision of this code should switch to using the User API call. The
# SIS API call doesn't give us any feedback on whether the user was successfully
# created or not. To do a User API call, we have to know whether the user exists
# and call either Create or Edit. There's no way to search for a user by username
# though, so this code will need to periodically fetch all users and maintain
# that state locally (e.g. as a giant hash fetched every <x> minutes)

use lib '/opt/amaint/etc/lib';
use Net::Stomp;
use XML::LibXML;
use HTTP::Request::Common qw(GET POST PUT DELETE);
use LWP::UserAgent;
use Canvas;
use Tokens;

$debug=0;

# If your ActiveMQ brokers are configured as a master/slave pair, define
# both hosts here. This script will try the primary, then try the failover
# host. "Yellow" == primary down, "Red" == both down
#
# If not running a pair, leave secondary_host set to undef

$primary_host = "msgbroker1.tier2.sfu.ca";
$secondary_host = "msgbroker2.tier2.sfu.ca";
#$secondary_host = undef;

$port = 61613;

$mquser = $Tokens::mquser;
$mqpass = $Tokens::mqpass;

$inqueue = "/queue/ICAT.amaint.toCanvas";

$timeout=600;		# Don't wait longer than this to receive a msg. Any longer and we drop, sleep, and reconnect. This helps us recover from Msg Broker problems too


# =============== end of config settings ===================

# For testing
#testing();
#exit 1;

# Autoflush stdout so log entries get written immediately
$| = 1;

# Attempt to connect to our primary server

while (1) {

  eval { $stomp = Net::Stomp->new( { hostname => $primary_host, port => $port, timeout => 10 }) };

  if($@ || !($stomp->connect( { login => $mquser, passcode => $mqpass })))
  {
    # Oh oh, primary failed
    if (defined($secondary_host))
    {
	eval { $stomp = Net::Stomp->new( { hostname => $secondary_host, port => $port, timeout => 10 }) };
	if ($@)
	{
	    $failed = 1;
	    $error.=$@;
	}
	elsif(!($stomp->connect( { login => $mquser, passcode => $mqpass })))
	{
	    $failed=1;
	    $error.="Master/Slave pair DOWN. Brokers at $primary_host and $secondary_host port $port unreachable!";
	}
	else
	{
	    $error.="Primary Broker at $primary_host port $port down. Slave at $secondary_host has taken over. ";
	}
    }
    else
    {
	$failed=1;
	$error="Broker $primary_host on port $port unreachable";
    }
  }

  if (!$failed)
  {
    # First subscribe to messages from the queue
    $stomp->subscribe(
        {   destination             => $inqueue,
            'ack'                   => 'client',
            'activemq.prefetchSize' => 1
        }
    );

    do {
    	$frame = $stomp->receive_frame({ timeout => $timeout });

    	if (!$frame)
    	{
	    # Got a timeout or null body back. Fall through to sleep and try again in a bit
	    $error .="No message response from Broker after waiting $timeout seconds!";
	    $failed=1;
	}
	else
	{
	    if (process_msg($frame->body))
	    {
		# message was processed successfully. Ack it
		$stomp->ack( {frame => $frame} );
	    }
	}
    } while (defined($frame));
    $stomp->disconnect;
  }

  # Sleep for 5 minutes and try again
  if ($failed)
  {
     print STDERR "Error: $error\n. Sleeping and retrying\n";
     $failed = 0;
  }
  sleep(300);

}

# Handle an XML Message from Amaint (or Grouper?)
# Returns non-zero result if the message was processed successfully

sub process_msg
{
    $xmlbody = shift;
    $xdom  = XML::LibXML->load_xml(
             string => $xmlbody
           );

    # First, generate an XPath object from the XML
    $xpc = XML::LibXML::XPathContext->new($xdom);

    # See if we have a syncLogin message
    if ($xpc->exists("/syncLogin"))
    {
	my (%params);
	# Add code in here to only sync certain account types?

	# Add code in here to process deletes differently?

	# We handle user adds by packaging them up as a "CSV" and using the SIS_ID import API
	$csv = "user_id,login_id,password,first_name,last_name,short_name,email,status\n";

	$login_id = $xpc->findvalue("/syncLogin/username");
	$user_id = $xpc->findvalue("/syncLogin/person/sfuid");

	if ($user_id < 1)
	{
		$user_id = $xpc->findvalue("/syncLogin/person/externalID");
	}

	# If the user has a modern SSHA password, pass it into Canvas. Canvas won't use it,
	# but if we later pass in a different string, Canvas will invalidate any existing
	# sessions for that user (forced logout)
	$password = $xpc->findvalue("/syncLogin/login/sshaPassword");
	if ($password =~ /^{SSHA}/)
	{
		$password =~ s/{SSHA}//;
	}
	else
	{
		$password = "";
	}

	$first_name = $xpc->findvalue("/syncLogin/person/firstnames");
	$last_name = $xpc->findvalue("/syncLogin/person/surname");
	$short_name = $xpc->findvalue("/syncLogin/person/preferredName") || "";
	$short_name .= " $last_name" if ($short_name ne "");
	$email = $login_id . "\@sfu.ca";

	# Status can be either "active" or "deleted". We may use "deleted" in the future
	$status = "active";

	$csv .= "$user_id,$login_id,$password,$first_name,$last_name,$short_name,$email,$status";

	print `date`, " Processing update for user $login_id\n$csv\n";
	$json = rest_to_canvas("POSTRAW","/api/v1/accounts/2/sis_imports.json?extension=csv",$csv);
	return 0 if (!defined($json));

    }
    else
    {
	if ($debug)
	{
		($line1,$line2,$junk) = split(/\n/,$xmlbody,3);
		print "Skipping unrecognized JMS message type:\n$line1\n$line2\n$junk";
	}
	# process Grouper JMS messages?
    }
    
    return 1;
}



# This code did user adds using the Users API and then created Communications Channels.
# It didn't work the way we wanted, but I'm leaving the code here for reference on
# how to use those APIs
sub oldcode
{
	# Process the syncLogin message (User add/update/delete?)
	$params{"pseudonym[unique_id]"} = $xpc->findvalue("/syncLogin/username");
	$params{"pseudonym[send_confirmation]"} = "0";
	$params{"self_enrollment"} = 1;

	$sfuid = $xpc->findvalue("/syncLogin/person/sfuid");
	$params{"pseudonym[sis_user_id]"} = $sfuid if ($sfuid > 0);

	$params{"user[name]"} = $xpc->findvalue("/syncLogin/person/firstnames") . " " . $xpc->findvalue("/syncLogin/person/surname");
	$params{"user[short_name]"} = $xpc->findvalue("/syncLogin/person/preferredName") . " " . $xpc->findvalue("/syncLogin/person/surname");
	$params{"pseudonym[path]"} = $params{"pseudonym[unique_id]"} . "\@sfu.ca";

	$userhash = rest_to_canvas("POST","/api/v1/accounts/2/users",\%params);

	return 0 if (!defined($userhash));

	# Parse the response from creating the user to determine the user's numerical ID

	if ($userhash->{id} > 0)
	{
		# Handle "Communication Channels" (email addresses)
		# In order to prevent a user from having to verify their email address, we need to set the email
		# address in a separate REST call and force Canvas to accept it. We also need to delete the 'unconfirmed'
		# address that got created when the user got created. But since we don't know for sure whether we've just
		# created this user (vs updated them), we need to fetch email addresses that have been set. 

		my $userid = $userhash->{id};

		# We got a valid ID back - create a REST call to the Communications Channel service
		$channels = rest_to_canvas("GET","/api/v1/users/$userid/communication_channels");
		return 0 if (!defined($channels));

		# Iterate through the returned channels looking for the one with the lowest position #, is email, and isn't confirmed 
		$position = 99999;
		$found = 0;
		foreach $chan (@{$channels})
		{
			if ($chan->{type} eq "email" && $chan->{position} < $position)
			{
				$position = $chan->{position};
				$found = $chan->{id};
				$workflow = $chan->{workflow_state};
			}
		}

		# Only delete the primary email address and only if it's unconfirmed
		if ($found > 0 && $workflow eq "unconfirmed")	 
		{
			print "Deleting unconfirmed email for ",$params{"pseudonym[unique_id]"},"\n";

			rest_to_canvas("DELETE","/api/v1/users/$userid/communication_channels/$found");

			# And now, finally, create a confirmed email address
			my %cparams;
			$cparams{"communication_channel[address]"} = $params{"pseudonym[unique_id]"} . "\@sfu.ca";
			$cparams{"communication_channel[type]"} = "email";
			$cparams{"skip_confirmation"} = 1;

			$userhash = rest_to_canvas("POST","/api/v1/users/$userid/communication_channels",\%cparams);
			return 0 if (!defined($userhash));
		}
		return $userid;
	}
	else
	{
		print STDERR "create-user didn't return a valid userID for ",$params{"pseudonym[unique_id]"},". Aborted\n";
		return 0;
	}

}
