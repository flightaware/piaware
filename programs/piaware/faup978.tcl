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
# connect_UAT_via_faup978 - if UAT enabled, connect to the receiver using faup978 as an intermediary;
# if it fails, schedule another attempt later
#
proc connect_UAT_via_faup978 {} {
	set uatConnection [FaupConnection_978 faup978 \
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

	$uatConnection faup_connect
}
