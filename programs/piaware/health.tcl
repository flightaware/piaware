# -*- mode: tcl; tab-width: 4; indent-tabs-mode: t -*-
# Copyright (C) 2014 FlightAware LLC All Rights Reserved
#

package require fa_sysinfo

#
# construct_health_array - set an array to contain health info about the machine
#
proc construct_health_array {_row} {
    upvar $_row row
    catch {
		foreach {mountpoint usage} [::fa_sysinfo::filesystem_usage] {
			set row(disk-$mountpoint) $usage
		}
	}
	catch {set row(adsbprogram_running) [is_adsb_program_running]}
    catch {set row(cputemp) [::fa_sysinfo::cpu_temperature]}
    catch {set row(cpuload) [::fa_sysinfo::cpu_load]}
    catch {set row(uptime) [::fa_sysinfo::uptime]}

	if {[info exists ::netstatus(program_30005)]} {
		set row(adsbprogram) $::netstatus(program_30005)
	}

	catch {
		if {[::fa_sysinfo::route_to_flightaware gateway iface ip]} {
			set row(local_ip) $ip
			set row(local_iface) $iface
		}
	}
}

#
# periodically_send_health_information - every few minutes marshall up the
#  health information and forward it
#
proc periodically_send_health_information {} {
	if {[info exists ::healthTimer]} {
		after cancel $::healthTimer
	}

	set ::healthTimer [after [expr {$::sendHealthInformationIntervalSeconds * 1000}] periodically_send_health_information]

	if {![adept is_logged_in]} {
		return
	}

    construct_health_array row
	adept send_health_message row
	return
}

set ::gpsLocationValid 0
proc gps_location_update {lat lon alt} {
	if {$lat eq "" || $lon eq "" || $alt eq ""} {
		# not a 3D fix, invalidate any current position and
		# don't do anything further
		adept set_location ""
		set ::gpsLocationValid 0
		return
	}

	# valid 3D fix
	if {!$::gpsLocationValid} {
		# first time
		logger [format "GPS: Receiver location: %.5f, %.5f at %.0fm height (WGS84)" $lat $lon $alt]
		set ::gpsLocationValid 1
	}

	adept set_location [list $lat $lon $alt wgs84_meters]

	set last [adept last_reported_location]
	if {$last ne ""} {
		lassign $last lastLat lastLon lastAlt
		set moved [expr {abs($lat - $lastLat) > 0.001 || abs($lon - $lastLon) > 0.001 || abs($alt - $lastAlt) > 50}]
	} else {
		# have not yet reported a position
		set moved 1
	}

	# record the location and maybe restart faup1090 with the new value
	update_location $lat $lon

	if {$moved} {
		# trigger a healthcheck immediately to send the new position
		# if we didn't move much, it can wait until the next normal health update
		periodically_send_health_information
	}
}

proc adept_location_changed {lat lon alt altref} {
	if {$::gpsLocationValid} {
		# ignore it, we know better
		return
	}

	# record the location and maybe restart faup1090 with the new value
	update_location $lat $lon
}

proc connect_to_gpsd {} {
	::fa_gps::GpsdClient gpsd -callback gps_location_update
	gpsd connect
}

# vim: set ts=4 sw=4 sts=4 noet :
