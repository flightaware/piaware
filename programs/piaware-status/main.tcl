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

#
# main - the main program
#
proc main {{argv ""}} {
	report_status
}

if {!$tcl_interactive} {
    main $argv

	vwait die
	exit 0
}

# vim: set ts=4 sw=4 sts=4 noet :
