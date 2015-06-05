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

package require fa_adept_config
package require cmdline
package require Tclx

set pidFile "/var/run/piaware.pid"

#
# main - the main program
#
proc main {{argv ""}} {
	set options {
		{user.arg "" "specify the user name of a valid FlightAware account"}
		{password "interactively specify the password of the FlightAware account"}
		{autoUpdate.arg "" "1 = allow FlightAware to automatically update software on my Pi, 0 = no"}
		{manualUpdate.arg "" "1 = allow me to trigger manual updates through FlightAware, 0 = no"}
		{mlat.arg "" "1 = allow multilateration data to be provided, 0 = no"}
		{start "attempt to start the ADS-B client"}
		{stop "attempt to stop the ADS-B client"}
		{restart "attempt to restart the ADS-B client"}
		{status "get the status of the ADS-B client"}
		{show "show config file"}
	}

	set usage ": $::argv0 -help|-user|-password|-start|-stop|-restart|-status|-autoUpdate 1/0|-manualUpdate 1/0|-mlat 1/0"

	if {$argv == ""} {
		puts stderr "usage$usage"
		exit 1
	}

	if {[catch {array set ::params [::cmdline::getoptions argv $options $usage]} catchResult] == 1} {
		puts stderr $catchResult
		exit 1
	}

	if {$argv != ""} {
		puts stderr [::cmdline::usage $options]
		exit 1
	}

	user_check

	load_adept_config
	process_parameters ::params
}

if {!$tcl_interactive} {
    main $argv
}

# vim: set ts=4 sw=4 sts=4 noet :
