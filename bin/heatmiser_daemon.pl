#!/usr/bin/perl

# This is a daemon for logging temperature and central heating usage data from
# the iPhone interface of Heatmiser's range of Wi-Fi enabled thermostats to a
# database for later analysis and charting.
#
# Ensure that user that runs this script is able to create
# '/var/run/heatmiser_daemon.pl.pid'. On most systems this probably means that
# it needs to be run as root.

# Copyright © 2011, 2012, 2013 Alexander Thoukydides
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

# Useful libraries
use Getopt::Std;
use POSIX qw(strftime);
use Proc::Daemon;
use Proc::PID::File;
use heatmiser_config;
use heatmiser_db;
use heatmiser_weather;
use heatmiser_wifi;

# Command line options
my ($prog) = $0 =~ /([^\\\/]+$)/;
sub VERSION_MESSAGE { print "Heatmiser Wi-Fi Thermostat Daemon v1\n"; }
sub HELP_MESSAGE { print "Usage: $prog [-v] [-h <host>] [-p <pin>] [-i <logseconds>] [-r <wlograte>] [-w <wservice>] [-k <wkey>] [-g <wlocation>] [-f <wunits>] [-s <dbsource>] [-u <dbuser>] [-a <dbpassword>] [-l <logfile>]\n"; }
$Getopt::Std::STANDARD_HELP_VERSION = 1;
our ($opt_v, $opt_h, $opt_p, $opt_i, $opt_r, $opt_w, $opt_k, $opt_g, $opt_f,
     $opt_s, $opt_u, $opt_a, $opt_l);
getopts('vh:p:i:r:w:k:g:f:s:u:a:l:');
heatmiser_config::set(verbose => $opt_v, host => [h => $opt_h],
                      pin => [p => $opt_p], logseconds => [i => $opt_l],
                      wlograte => [r => $opt_r], wservice => [w => $opt_w],
                      wkey => [k => $opt_k], wlocation => [g => $opt_g],
                      wunits => [f => $opt_f], dbsource => [s => $opt_s],
                      dbuser => [u => $opt_u], dbpassword => [a => $opt_a],
                      logfile => [l => $opt_l]);

# Start as a daemon (current script exits at this point)
my $logfile = heatmiser_config::get_item('logfile');
Proc::Daemon::Init({child_STDERR => "+>>$logfile"});

# Exit if already running
die "Daemon already running\n" if Proc::PID::File->running();

# Redirect all output to the log file and disable buffering
open(STDOUT, '>&STDERR') or die "Failed to re-open STDOUT to STDERR: $!\n";
$| = 1, select $_ for select STDOUT;
syslog(">>>> $prog started >>>>");

# Connect to the database
my $db = new heatmiser_db(heatmiser_config::get(qw(dbsource dbuser dbpassword host)));

# Prepare each thermostat being logged
my %thermostats;
foreach my $thermostat (@{heatmiser_config::get_item('host')})
{
    $thermostats{$thermostat} =
    {
        # Instantiate an object for connecting to this thermostat
        hm => new heatmiser_wifi(host => $thermostat,
                                 heatmiser_config::get(qw(pin))),

        # Initial state for this thermostat for tracking interesting events
        last_heat     => { cause => '', state => -1, target => -1 },
        last_hotwater => { cause => '', state => 0 }
    };
}

# Prepare the online weather service
my $weather;
if (defined heatmiser_config::get_item('wservice'))
{
    $weather =
    {
        # Instantiate an object for connecting to this weather service
        ws => new heatmiser_weather(heatmiser_config::get(qw(wservice wkey wlocation wunits))),

        # Initial state for tracking new weather observations
        last_timestamp => eval { $db->weather_retrieve_latest(['time'])->[0]; } || '',
        count          => 0
    };
}

# Loop until a signal is caught
my $signal;
sub quit { $signal = shift; syslog("Caught $signal: exiting gracefully"); }
$SIG{HUP}  = sub { quit('SIGHUP'); };
$SIG{INT}  = sub { quit('SIGINT'); };
$SIG{QUIT}  = sub { quit('SIGQUIT'); };
$SIG{TERM}  = sub { quit('SIGTERM'); };
while (not $signal)
{
    # Read and log the status for each thermostat
    my $last_time;
    while (my ($thermostat, $self) = each %thermostats)
    {
        # Trap errors while reading the status and updating the database
        eval
        {
            # Read current status and disconnect so other clients can connect
            my @dcb = $self->{hm}->read_dcb();
            $self->{hm}->close();

            # Decode the status
            my $status = $self->{hm}->dcb_to_status(@dcb);
            my ($comfort, $next_comfort, $next_comfort_hours) = $self->{hm}->lookup_comfort($status);
            my $timer = $self->{hm}->lookup_timer($status);
            $last_time = $status->{time} unless defined $last_time;

            # Determine the actions and their causes
            my ($heat_target, $heat_cause) =
                action_heat($status, $comfort,
                            $next_comfort, $next_comfort_hours);
            my ($hotwater_state, $hotwater_cause) =
                action_hotwater($status, $timer);

            # Update the stored configuration
            log_config($db, $thermostat, $status);

            # Log the current details
            log_status($db, $thermostat, $status,
                       $comfort, $heat_target, $heat_cause,
                       $timer, $hotwater_state, $hotwater_cause);

            # Log interesting events
            log_event_heat($db, $thermostat, $status,
                           $heat_target, $heat_cause,
                           $self->{last_heat});
            log_event_hotwater($db, $thermostat, $status,
                               $hotwater_state, $hotwater_cause,
                               $self->{last_hotwater});

        };
        syslog($@, $thermostat) if $@;
    }

    # Retrieve the weather observations if enabled
    if ($weather
        and ++($weather->{count}) == heatmiser_config::get_item('wlograte'))
    {
        # Reset the log rate counter
        $weather->{count} = 0;

        # Trap errors while retrieving the weather and updating the database
        eval
        {
            # Read the current weather observations
            my ($external, $timestamp) = $weather->{ws}->current_temperature();

            # Log the weather observations if new
            if ($timestamp ne $weather->{last_timestamp})
            {
                $weather->{last_timestamp} = $timestamp;
                $db->weather_insert(time => $timestamp, external => $external);
            }
        };
        syslog($@) if $@;
    }

    # Pause before reading the status again
    my $sleep = heatmiser_config::get_item('logseconds');
    if ((24 * 60 * 60) % $sleep == 0
        and defined $last_time and $last_time =~ /(\d\d):(\d\d):(\d\d)$/)
    {
        # Attempt to align to a multiple of the log interval
        my $correction = (($1 * 60 + $2) * 60 + $3) % $sleep;
        $correction -= $sleep if $sleep / 2 < $correction;
        $sleep -= $correction;
    }
    syslog("Sleeping for $sleep seconds") if heatmiser_config::get_item('verbose');
    sleep($sleep);
}

# That's all folks!
syslog("<<< $prog stopped ($signal) <<<<");
exit;


# Determine the target temperature and its cause
sub action_heat
{
    my ($status, $comfort, $next_comfort, $next_comfort_hours) = @_;

    # Consider influences in decreasing order of importance
    my ($target, $cause);
    unless (exists $status->{heating})
    {
        # Thermostat does not control heating
        $target = 0;
        $cause = '';
    }
    elsif (not $status->{enabled})
    {
        # Thermostat switched off
        $target = 0;
        $cause = 'off';
    }
    elsif ($status->{runmode} eq 'frost')
    {
        # Frost protection mode (includes away/summer and holiday)
        $target = $status->{frostprotect}->{enabled}
                  ? $status->{frostprotect}->{target} : 0;
        $cause = $status->{holiday}->{enabled} ? 'holiday' : 'away';
    }
    else
    {
        # Normal heating mode (includes manual adjustment and comfort level)
        $target = $status->{heating}->{target};
        $cause = $status->{heating}->{hold}
                 ? 'hold'
                 : ($status->{heating}->{target} == $comfort
                    ? 'comfortlevel'
                    : (($status->{heating}->{target} == $next_comfort
                        and $comfort < $next_comfort
                        and $next_comfort_hours
                            <= $status->{config}->{optimumstart})
                       ? 'optimumstart' : 'manual'));
    }

    # Return the result
    return ($target, $cause);
}

# Determine the hot water state and its cause
sub action_hotwater
{
    my ($status, $timer) = @_;

    # Consider influences in decreasing order of importance
    my ($state, $cause);
    unless (exists $status->{hotwater})
    {
        # Thermostat does not control hot water
        $state = 0;
        $cause = '';
    }
    else
    {
        # Hot water is being controlled so determine influence
        $state = $status->{hotwater}->{on};
        unless ($status->{enabled})
        {
            # Thermostat switched off
            $cause = 'off';
        }
        elsif ($status->{holiday}->{enabled})
        {
            # Holiday
            $cause = 'holiday';
        }
        elsif ($status->{awaymode} eq 'away')
        {
            # Away mode
            $cause = 'away';
        }
        elsif ($status->{hotwater}->{boost})
        {
            # Hot water boost
            $cause = 'boost';
        }
        elsif ($status->{hotwater}->{on} == $timer)
        {
            # Timer control
            $cause = 'timer';
        }
        else
        {
            # Manual override
            $cause = 'override';
        }
    }

    # Return the result
    return ($state, $cause);
}

# Update the stored the configuration
sub log_config
{
    my ($db, $thermostat, $status) = @_;

    # Store the main configuration of the thermostat
    $db->settings_update($thermostat,
                         host     => $thermostat,
                         vendor   => $status->{product}->{vendor},
                         version  => $status->{product}->{version},
                         model    => $status->{product}->{model},
                         heating  => exists $status->{heating}
                                     ? ($status->{enabled}
                                        ? $status->{runmode} : 'off')
                                     : 'n/a',
                         hotwater => exists $status->{hotwater}
                                     ? ($status->{enabled}
                                        && $status->{awaymode} eq 'home'
                                        ? 'hotwater' : 'off')
                                     : 'n/a',
                         units    => $status->{config}->{units},
                         holiday  => $status->{holiday}->{enabled}
                                     ? $status->{holiday}->{time} : '',
                         progmode => $status->{config}->{progmode});

    # Update the programmed comfort levels and hot water timers
    $db->comfort_update($thermostat, $status->{comfort});
    $db->timer_update($thermostat, $status->{timer});
}

# Log the current status and measurements
sub log_status
{
    my ($db, $thermostat, $status,
        $comfort, $heat_target, $heat_cause,
        $timer, $hotwater_state, $hotwater_cause) = @_;

    # Store the current status
    my $air = $status->{temperature}->{remote}
              || $status->{temperature}->{internal}
              || $status->{temperature}->{floor};
    $db->log_insert($thermostat,
                    time    => $status->{time},
                    air     => $air,
                    target  => $heat_target,
                    comfort => $comfort);

    # Add a log file entry if enabled
    if (heatmiser_config::get_item('verbose'))
    {
        my $u = $status->{config}->{units};
        printf "%s: %s Air=%.1f$u Target=%i$u Cause=%s Comfort=%i$u Heating=%s HotWater=%s Cause=%s Timer=%s\n",
               $thermostat,
               $status->{time},
               $air,
               $heat_target,
               $heat_cause,
               $comfort,
               $status->{heating}->{on} ? 'ON' : 'OFF',
               $hotwater_state ? 'ON' : 'OFF',
               $hotwater_cause,
               $timer ? 'ON' : 'OFF';
    }
}

# Log interesting heating events
sub log_event_heat
{
    my ($db, $thermostat, $status, $target, $cause, $last) = @_;

    # Only record changes of state (and initial state)
    my $state = $status->{heating}->{on};
    if ($state != $last->{state})
    {
        $db->event_insert($thermostat,
                          time        => $status->{time},
                          class       => 'heating',
                          state       => $state);
    }
    if ($cause ne $last->{cause} or $target != $last->{target})
    {
        $db->event_insert($thermostat,
                          time        => $status->{time},
                          class       => 'target',
                          state       => $cause,
                          temperature => $target);
    }

    # Remember the current state
    $last->{cause} = $cause;
    $last->{state} = $state;
    $last->{target} = $target;
}

# Log interesting hot water events
sub log_event_hotwater
{
    my ($db, $thermostat, $status, $state, $cause, $last) = @_;

    # Only record changes of state (and initial state, if hot water controlled)
    if ($state ne $last->{state} or $cause ne $last->{cause})
    {
        $db->event_insert($thermostat,
                          time        => $status->{time},
                          class       => 'hotwater',
                          state       => $cause,
                          temperature => $state);
    }

    # Remember the current state
    $last->{cause} = $cause;
    $last->{state} = $state;
}

# Record an error or debug information in the system log
sub syslog
{
    my ($message, $thermostat) = @_;

    # Output the message prefixed by a timestamp and the thermostat's name
    $message =~ s/\s+$//;
    print strftime("%b %d %H:%M:%S", localtime),
          (defined $thermostat ? " [$thermostat]" : ''), ': ', $message, "\n";
}
