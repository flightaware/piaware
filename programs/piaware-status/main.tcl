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

set ::die 0

#
# main - the main program
#
proc main {{argv ""}} {
	report_status
}

if {!$tcl_interactive} {
    main $argv
	exit 0
}

# vim: set ts=4 sw=4 sts=4 noet :
