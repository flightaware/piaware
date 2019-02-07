# -*- mode: tcl; tab-width: 4; indent-tabs-mode: t -*-
#
# piaware - ADS-B data upload to FlightAware
#
# Copyright (C) 2014 FlightAware LLC, All Rights Reserved
#

lappend auto_path /usr/local/lib

package require piaware
package require fa_adept_client
package require fa_gps
#package require BSD
package require Tclx
package require cmdline
package require tls

if {![info exists ::launchdir]} {
    set ::launchdir "."
}

source $::launchdir/config.tcl
source $::launchdir/helpers.tcl
source $::launchdir/faup1090.tcl
source $::launchdir/health.tcl
source $::launchdir/mlat.tcl
source $::launchdir/pirehose.tcl
source $::launchdir/update.tcl
source $::launchdir/login.tcl
source $::launchdir/statusfile.tcl
source $::launchdir/faup.tcl

#
# main - the main program
#
proc main {{argv ""}} {
	set options {
		{p.arg "" "specify the name of a file to write our pid in"}
		{configfile.arg "" "specify an additional configuration file to read"}
		{cachedir.arg "/var/cache/piaware" "specify alternative cache directory"}
		{serverhosts.arg "" "specify alternate server hosts (for FA testing)"}
		{serverport.arg "" "specify alternate server port (for FA testing)"}
		{plainlog "log to stderr without timestamps"}
		{debug "log to stderr, maybe enable more debugging messages"}
		{logfile.arg "/var/log/piaware.log" "set logfile location (not used if -debug or -plainlog are given)"}
		{showtraffic  "emit traffic to stdout (for debugging)"}
		{statusfile.arg "" "periodically write json status to this location"}
		{v	"emit version information and exit"}
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

	if {$::params(v)} {
		puts stdout "$::piawareVersionFull"
		exit 0
	}

	interp bgerror {} log_bgerror

	setup_config
	setup_faup1090_vars

	# setup adept client early so logger command won't trace back
	# (this does not initiate a connection, it just creates the object)
    setup_adept_client

	# arrange for a clean shutdown in the event of certain common signals
	setup_signals

	# start logging to a file unless configured for debug
	reopen_logfile

	# maintain a pidfile so we don't get multiple copies of ourself
	# (only does anything if we were invoked with the -p option)
	create_pidfile

	# write json status if configured
	periodically_update_status_file

	greetings

	connect_to_gpsd

	# we stagger this a little to let
	#  1) gpsd give us a location if it's going to (typically takes up to 1 second to do this)
	#  2) have the login happen and maybe pass back a receiver location
	#  3) fire up faup1090 with the new position
	after 1500 adept connect
	after 3000 connect_adsb_via_faup1090
	after 3500 start_pirehose
	after 4500 periodically_check_adsb_traffic
	after 30000 periodically_send_health_information

    catch {vwait die}

	cleanup_and_exit
}

if {!$tcl_interactive} {
    main $argv
}

# vim: set ts=4 sw=4 sts=4 noet :
