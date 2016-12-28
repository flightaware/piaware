# -*- mode: tcl; tab-width: 4; indent-tabs-mode: t -*-
#
# fa_adept aka piaware-config - interactive program to
#  set flightaware user ID and password
#  and do other stuff
#
# Copyright (C) 2014 FlightAware LLC, All Rights Reserved
#
#

if {![info exists ::launchdir]} {
    set ::launchdir .
}

lappend auto_path /usr/local/lib

source $::launchdir/helpers.tcl

package require cmdline
package require Tclx

set pidFile "/var/run/piaware.pid"

#
# main - the main program
#
proc main {{argv ""}} {
	set options {
		{start "attempt to start the ADS-B client"}
		{stop "attempt to stop the ADS-B client"}
		{restart "attempt to restart the ADS-B client"}
		{status "get the status of the ADS-B client"}
		{show "show current config settings (or just the specified keys)"}
		{showall "show all config settings including passwords, unset values, and defaults"}
		{configfile.arg "" "specify an additional configuration file to read"}
	}

	set usage ": $::argv0 ?-configfile <file>? -help|-start|-stop|-restart|-status|-showall|-show ?key?|?key value?\n"

	if {[catch {array set ::params [::cmdline::getoptions argv $options $usage]} catchResult] == 1} {
		puts stderr $catchResult
		exit 1
	}

    if {$::params(start)} {
		start_piaware
    }

    if {$::params(stop)} {
		stop_piaware
    }

    if {$::params(restart)} {
		restart_piaware
    }

    if {$::params(status)} {
		piaware_status
    }

	if {$::params(show) || $::params(showall) || $argv == ""} {
		show_piaware_config $::params(showall) $argv
	} else {
		update_config_values $argv
	}
}

if {!$tcl_interactive} {
    main $argv
}

# vim: set ts=4 sw=4 sts=4 noet :
