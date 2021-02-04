## -*- mode: tcl; tab-width: 4; indent-tabs-mode: t -*-
#
# piaware - aviation data exchange protocol ADS-B client
#
# Copyright (C) 2014 FlightAware LLC, All Rights Reserved
#

package require fa_sudo
package require fa_services

#
# Subclass for 1090ES specific handling
#
::itcl::class FaupConnection_1090 {
	inherit FaupConnection

	method constructor {args} {
		configure {*}$args
	}

	protected method program_args {} {
		set args [list "--net-bo-ipaddr" $receiverHost "--net-bo-port" $receiverPort "--stdout"]
		if {$::receiverLat ne "" && $::receiverLon ne ""} {
			lappend args "--lat" [format "%.3f" $::receiverLat] "--lon" [format "%.3f" $::receiverLon]
		}
		return $args
	}

	method custom_handler {_row} {
		upvar $_row row

		# extra filtering to avoid looping mlat results back
		if {[info exists row(hexid)]} {
			set hexid $row(hexid)
			if {[info exists ::mlatSawResult($hexid)]} {
				if {($row(clock) - $::mlatSawResult($row(hexid))) < 45.0} {
					foreach field {alt alt_gnss vrate vrate_geom position track speed} {
						if {[info exists row($field)]} {
							lassign $row($field) value age src
							if {$src eq "A"} {
								# This is suspect, claims to be ADS-B while we're doing mlat, clear it.
								unset -nocomplain row($field)
							}
						}
					}
				}
			}
		}
	}
}

#
# connect_adsb_via_faup1090 - connect to the receiver using faup1090 as an intermediary;
# if it fails, schedule another attempt later
#
proc connect_adsb_via_faup1090 {} {
	set receiverType [piawareConfig get receiver-type]

	# is 1090 enabled?
	if {$receiverType eq "none"} {
		logger "1090ES support disabled by local configuration setting: receiver-type"
		return
	}

	# path to faup1090
	set path [auto_execok "/usr/lib/piaware/helpers/faup1090"]
	if {$path eq ""} {
		logger "No faup1090 found at $path, 1090ES support disabled"
		return
	}

	# stop faup1090 connection just in case...
	stop_faup1090

	# Create faup connection object with receiver config
	lassign [receiver_host_and_port piawareConfig ES] host port
	set ::faup1090 [FaupConnection_1090 faup1090 \
						-adsbDataProgram [receiver_description piawareConfig ES] \
						-receiverType $receiverType \
						-receiverHost $host \
						-receiverPort $port \
						-receiverDataFormat [receiver_data_format piawareConfig ES] \
						-adsbLocalPort [receiver_local_port piawareConfig ES] \
						-adsbDataService [receiver_local_service piawareConfig ES] \
						-faupProgramPath $path]

	$::faup1090 faup_connect
}

#
# stop_faup1090 - clean up faup1090 pipe, don't schedule a reconnect
#
proc stop_faup1090 {} {
	if {![info exists ::faup1090]} {
		# Nothing to do
		return
	}

	itcl::delete object $::faup1090
	unset ::faup1090
}

#
# restart_faup1090 - pretty self-explanatory
#
proc restart_faup1090 {{delay 30}} {
	if {![info exists ::faup1090]} {
		# Nothing to do
		return
	}

	$::faup1090 faup_restart $delay
}

#
# periodically_check_adsb_traffic - periodically perform checks to see if
# we are receiving data and possibly start/restart faup1090
#
# also issue a traffic report
#
proc periodically_check_adsb_traffic {} {
	if {![info exists ::faup1090]} {
		return
	}

	after [expr {$::adsbTrafficCheckIntervalSeconds * 1000}] periodically_check_adsb_traffic

	$::faup1090 check_traffic

	after 30000 $::faup1090 traffic_report
}

#
# handle_faup_command - validates/converts command array to tsv and sends to faup1090
#
proc handle_faup_command {_row} {
	if {![info exists ::faup1090]} {
		# No faup1090 connection
		return
	}

	upvar $_row row

	set message ""
	foreach field [lsort [array names row]] {
		append message "\t$field\t$row($field)"
	}

	$::faup1090 send_to_faup $message
}

# vim: set ts=4 sw=4 sts=4 noet :
