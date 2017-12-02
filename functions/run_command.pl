#!/usr/bin/perl

# This script provides a JSON interface to access the iPhone interface of
# Heatmiser's range of Wi-Fi enabled thermostats from languages other than
# Perl.

# Copyright © 2013 Alexander Thoukydides
#
# This file is part of the Heatmiser Wi-Fi project.
# <http://code.google.com/p/heatmiser-wifi/>
#
# Heatmiser Wi-Fi is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version.
#
# Heatmiser Wi-Fi is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
# or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for
# more details.
#
# You should have received a copy of the GNU General Public License
# along with Heatmiser Wi-Fi. If not, see <http://www.gnu.org/licenses/>.


# Catch errors quickly
use strict;
use warnings;

# Allow use of modules in the same directory
use Cwd 'abs_path';
use File::Basename;
use lib dirname(abs_path $0);
use lib '../bin';

# Useful libraries
use Getopt::Std;
use JSON;
use heatmiser_config;
use heatmiser_wifi;

# Command line options
my ($prog) = $0 =~ /([^\\\/]+$)/;
sub VERSION_MESSAGE { print "Heatmiser Wi-Fi Thermostat Set Away Mode\n"; }
sub HELP_MESSAGE { print "Usage: $prog [-h <host>] [-p <pin>]\n"; }
$Getopt::Std::STANDARD_HELP_VERSION = 1;
our ($opt_h, $opt_p);
getopts('h:p:');
heatmiser_config::set(host => [h => $opt_h], pin => [p => $opt_p]);

sub print_help()
{
	print "Known commands are:\n";
	print "\t1. set_away <on/off>\n";
	print "\t2. set_keylock <on/off>\n";
	print "\t3. set_temperature <temperature>\n";
	print "\t4. set_hold <temperature> <hours>\n";
	print "\t4. get_status\n";
}

{
	my $status = '';
	my $command = $ARGV[0];
	my $host = @{heatmiser_config::get_item('host')}[0];
	# Read the current status of the thermostat
	my $heatmiser = new heatmiser_wifi(host => $host, heatmiser_config::get(qw(pin)));

	if ($command eq "set_away") {
		my $on = $ARGV[1];
		$status = $heatmiser->set_away($on);
	}
	elsif ($command eq "set_keylock") {
		my $on = $ARGV[1];
		$status = $heatmiser->set_keylock($on);
	}
	elsif ($command eq "set_temperature") {
		my $temperature = $ARGV[1];
		$status = $heatmiser->set_temperature($temperature);
	}
	elsif ($command eq "set_hold") {
		my $temperature = $ARGV[1];
		my $hours = $ARGV[2];
		$status = $heatmiser->set_hold($temperature, $hours);
	}
	elsif ($command eq "get_status") {
		$status = $heatmiser->get_status();
	}
	else{
		print "Unknown command \'$command\'\n";
		print_help();
		exit;
	}

	my %status_hash;
	$status_hash{$host} = $status;
	print JSON->new->utf8->pretty->canonical->encode(\%status_hash);
}

exit;