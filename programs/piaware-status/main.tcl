# -*- mode: tcl; tab-width: 4; indent-tabs-mode: t -*-
#
# fa_adept aka piaware-status - interactive program to
#  get the status of the piaware toolchain
#
# Copyright (C) 2014 FlightAware LLC, All Rights Reserved
#
#

if {![info exists ::launchdir]} {
    set ::launchdir .
}

source $::launchdir/helpers.tcl

lappend auto_path /usr/local/lib

package require piaware
package require cmdline
package require Tclx
package require fa_piaware_config

#
# main - the main program
#
proc main {{argv ""}} {
	set options {
		{configfile.arg "" "specify an additional configuration file to read"}
	}

	set usage ": $::argv0 ?-configfile path?\n"

	if {[catch {array set ::params [::cmdline::getoptions argv $options $usage]} catchResult] == 1} {
		puts stderr $catchResult
		exit 1
	}

	report_status
}

if {!$tcl_interactive} {
    main $argv
	exit 0
}

# vim: set ts=4 sw=4 sts=4 noet :
