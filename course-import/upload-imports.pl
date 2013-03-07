#!/usr/bin/perl
#
# This utility script sends a directory full of Canvas course content zip files
# to Canvas. Each file follows a naming convention of "number:::source:::sis_id.zip".
# It is the sis_id that we care about - it must match a Canvas course with the same sis_id.
#
# This script is fairly SFU-specific, but does demonstrate how to use both the API calls and
# the browser simulator calls (course content zips can only be uploaded from a browser)

use FindBin;
use lib "$FindBin::Bin/../lib";
use Canvas;
use Tokens qw(cookie auth_token);
use JSON::Parse 'json_to_perl'; 
use HTTP::Request::Common qw(GET POST PUT DELETE);
use LWP::UserAgent;
use HTTP::Cookies;

$uploaddir = "/usr/local/webct/sectionBackup/canvas-export-new";
$status_file = "/tmp/upload_status";
$account_id = 2;
$debug = 1;

$Canvas::debug = 0;

$cookie = $Tokens::cookie;
$auth_token = $Tokens::auth_token;

die "No Cookies defined!" if (!defined($cookie));

fetch_files();
fetch_courses();
load_status();
upload_files();


sub fetch_files
{
	opendir(DIR,$uploaddir) or die "Can't open $uploaddir for reading";
	@files = grep(/.zip$/, readdir(DIR));
	closedir(DIR);
}


sub fetch_courses
{
        my (@sections);
        $courses = rest_to_canvas_and_cache("/api/v1/accounts/$account_id/courses","/tmp/courses.json",86400);
        return undef if (!defined($courses));

        print "Retrieved ",scalar(@{$courses})," courses from Canvas\n";

        foreach $course (@{$courses})
        {
                $c_id = $course->{id};
                $courses_by_id{$c_id} = $course;
		if ($course->{sis_course_id})
		{
			$courses_by_sis{$course->{sis_course_id}} = $course;
		}
        }

}


#
# Actually upload the files. After each file is sent, we update
# the upload_status file with the course id and import id for later processing

sub upload_files
{
	$count = 0;
	foreach $file (@files)
	{
		($num,$src,$name) = split(/:::/,$file);
		$name =~ s/.zip$//;
		print "Processing $file\n";

		if (!defined($courses_by_sis{$name}))
		{
			print STDERR "WARNING: No matching course found for $name\n";
			next;
		}
		if (defined($statuses{$courses_by_sis{$name}->{id}}))
		{
			print "Skipping $file. Already done\n";
			next;
		}

		$import = do_upload($courses_by_sis{$name}->{id},$file);
		if (!$import)
		{
			print STDERR "WARNING: Import failed for $file\n";
			next;
		}

		save_status($courses_by_sis{$name}->{id},$import);

		# Just do 5 courses for now
		$count++;
	 	return if ($count > 5);
	}
}

sub save_status
{
	($id,$import) = @_;
	open(ST,">>$status_file");
	print ST "$id:$import\n";
	close ST;
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

# File upload requires two posts - one to set params, the other to send the actual file
sub do_upload
{
    ($c_id,$file) = @_;
    print "POSTing metadata for $file\n" if $debug;
    $json = post("/courses/$c_id/imports/migrate", {
 	authenticity_token => $auth_token,
    	"attachment[filename]" => $file,
    	"attachment[context_code]" => "course_".$c_id,
    	export_file_enabled => 1,
    	"migration_settings[migration_type]" => "canvas_cartridge_importer",
    	"migration_settings[question_bank_name]" => "Imported Questions",
    	"migration_settings[only][assignments]" => 1,
    	"migration_settings[only][announcements]" => 1,
    	"migration_settings[only][calendar_events]" => 1,
    	"migration_settings[only][discussions]" => 1,
    	"migration_settings[only][all_files]" => 1,
    	"migration_settings[only][assessments]" => 1,
    	"migration_settings[only][question_bank]" => 1,
    	"migration_settings[only][goals]" => 1,
    	"migration_settings[only][tasks]" => 1,
    	"migration_settings[only][groups]" => 1,
    	"migration_settings[only][rubrics]" => 1,
    	"migration_settings[only][web_links]" => 1,
    	"migration_settings[only][wikis]" => 1,
    	"migration_settings[only][learning_modules]" => 1
	}, $cookie);

    if (!defined($json))
    {
	print STDERR "First POST failed for $file\n";
	return 0;
    }

    my $id = $json->{id};
    if ($id < 1)
    {
	print STDERR "Invalid response received from first POST for $file\n";
	return 0;
    }

    my $upload_url = $json->{upload_url};
    if ($upload_url =~ /upload\?id=(\d+)/)
    {
	$id = $1;
    }
    
    print "POSTing $file\n" if $debug;
    $json = post("/$upload_url", {
    	"authenticity_token" => $auth_token,
    	"export_file" => ["$uploaddir/$file"]
	}, $cookie);

    if (!defined($json->{attachment}))
    {
	print STDERR "Invalid response received after uploading $file\n";
	return 0;
    }

    return $id;
}

