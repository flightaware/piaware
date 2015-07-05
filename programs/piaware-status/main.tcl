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
package require fa_adept_config

set ::die 0

#
# main - the main program
#
proc main {{argv ""}} {
	if {[id user] != "root"} {
		puts stderr "you need to be root to run this, try 'sudo $::argv0'"
		exit 1
	}
	load_adept_config
	report_status
}

if {!$tcl_interactive} {
    main $argv

	while {!$die} {
		vwait die
	}

	exit 0
}

# vim: set ts=4 sw=4 sts=4 noet :
