## -*- mode: tcl; tab-width: 4; indent-tabs-mode: t -*-
#
# piaware - driver to connect to faup978
#
# Copyright (C) 2019 FlightAware LLC, All Rights Reserved
#

#
# Subclass for UAT specific handling
#
::itcl::class FaupConnection_978 {
	inherit FaupConnection

	method constructor {args} {
		configure {*}$args
	}

	protected method program_args {host port} {
		return [list "--connect" $receiverHost:$receiverPort]
	}
}

#
# connect_uat_via_faup978 - if UAT enabled, connect to the receiver using faup978 as an intermediary;
# if it fails, schedule another attempt later
#
proc connect_uat_via_faup978 {} {
	# is 1090 enabled?
	if {$receiverType eq "none"} {
		logger "UAT support disabled by local configuration setting: uat-receiver-type"
		return
	}

	# path to faup978
	set path [auto_execok "/usr/lib/piaware/helpers/faup978"]
	if {$path eq ""} {
		logger "No faup978 found at $path, UAT support disabled"
		return
	}

	# stop faup978 connection just in case...
	stop_faup978

	lassign [receiver_host_and_port piawareConfig UAT] host port
	set ::faup978 [FaupConnection_978 faup978 \
					   -adsbDataProgram [receiver_description piawareConfig UAT] \
					   -receiverType $receiverType \
					   -receiverHost $host \
					   -receiverPort $port \
					   -receiverLat $::receiverLat \
					   -receiverLon $::receiverLon \
					   -receiverDataFormat [receiver_data_format piawareConfig UAT] \
					   -adsbLocalPort [receiver_local_port piawareConfig UAT] \
					   -adsbDataService [receiver_local_service piawareConfig UAT] \
					   -faupProgramPath $path]

	$::faup978 faup_connect
}

#
# stop_faup978 - clean up faup978 pipe, don't schedule a reconnect
#
proc stop_faup978 {} {
	if {![info exists ::faup978]} {
		# Nothing to do
		return
	}

	itcl::delete object $::faup978
	unset ::faup978
}

#
# restart_faup978 - pretty self-explanatory
#
proc restart_faup978 {{delay 30}} {
	if {![info exists ::faup978]} {
		# Nothing to do
		return
	}

	$::faup978 faup_restart $delay
}

#
# periodically_check_adsb_traffic - periodically perform checks to see if
# we are receiving data and possibly start/restart faup1090
#
# also issue a traffic report
#
proc periodically_check_uat_traffic {} {
	if {![info exists ::faup978]} {
		return
	}

	after [expr {$::adsbTrafficCheckIntervalSeconds * 1000}] periodically_check_uat_traffic

	$::faup978 check_traffic

	after 30000 $::faup978 traffic_report
}
