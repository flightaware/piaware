# -*- mode: tcl; tab-width: 4; indent-tabs-mode: t -*-
#
# pirehose - firehose-alike interface to piaware
#
# Copyright (C) 2017 FlightAware LLC, All Rights Reserved
#

lappend auto_path /usr/local/lib

package require cmdline
package require tls
package require zlib
package require json::write
package require Tclx
package require Itcl

if {![info exists ::launchdir]} {
    set ::launchdir "."
}

source $::launchdir/config.tcl
source $::launchdir/listener.tcl
source $::launchdir/initiation.tcl
source $::launchdir/connection.tcl
source $::launchdir/state.tcl
source $::launchdir/reports.tcl
source $::launchdir/helpers.tcl

#
# main - the main program
#
proc main {{argv ""}} {
	set options {
		{port.arg "1501" "firehose listening port"}
		{username.arg "pirehose" "username clients use to authenticate"}
		{password.arg "pirehose" "API key / password clients use to authenticate"}
		{certfile.arg "/etc/piaware/pirehose.cert.pem" "path to SSL certificate file"}
		{keyfile.arg "/etc/piaware/pirehose.key.pem" "path to SSL key file"}
	}

    set usage ": $::argv0 ?options?"

    if {[catch {array set ::params [::cmdline::getoptions argv $options $usage]} catchResult] == 1} {
        puts stderr $catchResult
        exit 6
    }

    if {$argv != ""} {
        puts stderr [::cmdline::usage $options]
        exit 6
    }

	if {![file readable $::params(certfile)]} {
		puts stderr "Certificate file $::params(certfile) is not readable, giving up"
		exit 6
	}

	if {![file readable $::params(keyfile)]} {
		puts stderr "Key file $::params(keyfile) is not readable, giving up"
		exit 6
	}

	interp bgerror {} log_bgerror

	set ::die 0

	periodically_reap_children
	start_listening
	start_reading_stdin

	while {!$::die} {
		vwait ::die
	}
}

if {!$tcl_interactive} {
    main $argv
}

# vim: set ts=4 sw=4 sts=4 noet :
