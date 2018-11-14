#!/usr/bin/perl
use lib './lib';
use Amaint;

$Amaint::debug = 1;
my $username = @ARGV[0];
my $resp = push_account_update($username);
print $resp;