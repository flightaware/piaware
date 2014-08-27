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
	user_check

	set options {
		{user.arg "" "specify the user name of a valid FlightAware account"}
		{password "interactively specify the password of the FlightAware account"}
		{start "attempt to start the ADS-B client"}
		{stop "attempt to stop the ADS-B client"}
		{restart "attempt to restart the ADS-B client"}
		{status "get the status of the ADS-B client"}
	}

	set usage ": $::argv0 -help|-user|-password|-start|-stop|-status ?args?"

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

	load_adept_config
	process_parameters ::params
}

if {!$tcl_interactive} {
    main $argv
}

# vim: set ts=4 sw=4 sts=4 noet :
