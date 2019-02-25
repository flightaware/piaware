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
                puts "Creating FaupConnection_978 Object"
                configure {*}$args
        }

        method custom_handler {_row} {
		upvar $_row row
                # Append some field to designate 978
	}

}

#
# setup_faup978_vars - setup faup978 configuration variables
#
proc setup_faup978_vars {} {
	# receiver config for UAT
	set ::message_type_UAT UAT
	set ::receiverTypeUAT [piawareConfig get uat-receiver-type]
	lassign [receiver_host_and_port piawareConfig $::message_type_UAT] ::receiverHostUAT ::receiverPortUAT
	set ::receiverDataFormatUAT [receiver_data_format piawareConfig $::message_type_UAT]
	set ::adsbLocalPortUAT [receiver_local_port piawareConfig $::message_type_UAT]
	set ::adsbDataServiceUAT [receiver_local_service piawareConfig $::message_type_UAT]
	set ::adsbDataProgramUAT [receiver_description piawareConfig $::message_type_UAT]

	# path to faup978
	set path "/usr/lib/piaware/helpers/faup978"
	if {[set ::faup978Path [auto_execok $path]] eq""} {
		logger "No faup978 found at $path, cannot continue"
		exit 1
	}
}

#
# connect_uat_via_faup978 - if UAT enabled, connect to the receiver using faup978 as an intermediary;
# if it fails, schedule another attempt later
#
proc connect_uat_via_faup978 {} {
	if {$::receiverTypeUAT eq "none"} {
		logger "UAT support disabled by local configuration setting: uat-receiver-type"
		return
	}

	set ::faup978 [FaupConnection_978 faup978 \
		-adsbDataProgram $::adsbDataProgramUAT \
		-receiverType $::receiverTypeUAT \
		-receiverHost $::receiverHostUAT \
		-receiverPort $::receiverPortUAT \
		-receiverLat $::receiverLat \
		-receiverLon $::receiverLon \
		-receiverDataFormat $::receiverDataFormatUAT \
		-adsbLocalPort $::adsbLocalPortUAT \
		-adsbDataService $::adsbDataServiceUAT \
		-faupProgramPath $::faup978Path]

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

        $::faup978 faup_disconnect
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
