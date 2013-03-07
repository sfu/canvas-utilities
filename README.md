<h2>Collection of Canvas Utilities</h2>

This is a collection of Perl-based libraries and utilities for interacting with Canvas either through its API or by simulating browser-based transactions. Most of the utilities are fairly specific our site, but do provide examples for how to use the libraries in the /lib directory.

Before this code will do anything, you need to copy lib/Tokens.pm.example to lib/Tokens.pm and edit it to add your OAuth token. 

There's also code in lib/Canvas.pm to simulate a browser POST. This was necessary as some Canvas functionality can still only be accessed from a browser - notably course content import, which we needed to do en masse (11,000 courses). POSTing in this way requires a valid session cookie and authenticity token which is NOT the same as an OAuth token. The only way to get these is to perform a standard login. No code has been written to actually simulate a login yet, so you're required to do that step manually and paste the cookie and token into Tokens.pm. I will probably add a login function soon.

File summary:
* amaint-jms.pl - this daemon listens for XML messages arriving from our ActiveMQ enterprise messaging broker system and converts those messages into user updates for Canvas.
* import_csv_to_canvas.pl - simple script to send an SIS CSV file to Canvas
* process_enrollments.pl - nightly batch job to sync Canvas section enrollments to an external source. The script is currently capable of syncing against our SIS system, our maillist system (both site-specific, with data retrieved via custom SOAP calls), or via flat files. This script will not run as-is, as the module that handles the custom SOAP calls is not bundled in this repo. It would be easy to modify though
* lib/Canvas.pm - library of functions to access Canvas's API and browser transactions
* lib/Tokens.pm.template - copy to lib/Tokens.pm and modify the values as needed
* course-import/upload-imports.pl - Upload Course Import zip files to their matching Canvas course. Fetches all courses then POSTs the zip files - good example of how to use this code to simulate browser POSTs
* course-import/trigger-imports.pl - Course content import is an asynchronous process - the content is uploaded, then once it's processed, an 'import' can be triggered to actually import the content. This script triggrers the import process for all courses uploaded by the upload-imports.pl script

