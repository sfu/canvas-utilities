#!/bin/sh
#
# Simple script to start udd.pl.
# This script will restart udd if it dies, and log why it died.

while true
do
        if [ -x /opt/amaint/etc/amaint-jms.pl ]; then
		sleep 30
                /opt/amaint/etc/amaint-jms.pl >> /tmp/amaint-jms.log
                # We only reach here if it dies
                echo "amaint-jms died with error code: $? at \c"
                date
        fi
done
