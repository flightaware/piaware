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
    catch {set row(adsbprogram_running) [is_adsb_program_running [receiver_local_port piawareConfig ES]]}
    catch {set row(cputemp) [::fa_sysinfo::cpu_temperature]}
    catch {set row(cpuload) [::fa_sysinfo::cpu_load]}
    catch {set row(uptime) [::fa_sysinfo::uptime]}

	if {[info exists ::netstatus(program_30005)]} {
		set row(adsbprogram) $::netstatus(program_30005)
	}

	catch {
		if {[::fa_sysinfo::route_to_flightaware gateway iface ip]} {

			# get override-site-info-host
			set osih [piawareConfig get override-site-info-host]

			# if override-site-info-host is not set, then send the ip as-per fa_sysinfo
			if {$osih eq ""} {
				
				set row(local_ip) $ip
				set row(local_iface) $iface

			# if override-site-info-host is set, then send the contents of override-site-info-host
			} else {

				set row(local_ip) $osih
				set row(local_iface) $iface

			}
		}
	}

	catch {
		set ntp [::fa_sysinfo::ntp_status stratum offset]
		if {$ntp ne ""} {
			set row(ntp_status) $ntp
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

proc gps_location_update {lat lon alt} {
	if {$lat eq "" || $lon eq "" || $alt eq ""} {
		handle_location_update gpsd "" "" "" ""
		return
	}

	# valid 3D fix
	handle_location_update gpsd $lat $lon $alt wgs84_meters
}

proc handle_location_update {src lat lon alt altref {override ""}} {
	if {$lat eq "" || $lon eq ""} {
		unset -nocomplain ::locationData($src)
	} else {
		set lat [format "%.5f" $lat]
		set lon [format "%.5f" $lon]
		set alt [format "%.0f" $alt]

		if {![info exists ::locationData($src)]} {
			# first time
			if {$altref ne ""} {
				switch -- $altref {
					wgs84_feet { set unit "ft (WGS84)" }
					wgs84_meters { set unit "m (WGS84)" }
					egm96_feet { set unit "ft AMSL" }
					egm96_meters { set unit "m AMSL" }
					default { set unit " (unknown unit)" }
				}

				logger "$src reported location: $lat, $lon, $alt$unit"
			} else {
				logger "$src reported location: $lat, $lon"
			}
		}

		set ::locationData($src) [list $lat $lon $alt $altref $override]
	}

	location_data_changed
}

proc location_data_changed {} {
	# find best location, prefer receiver data over gpsd over adept
	array set typePriority {
		adept 1
		gpsd 2
		receiver 3
		mlat 4
	}

	set newloc ""
	set newprio -99
	foreach {src srcData} [array get ::locationData] {
		lassign $srcData lat lon alt altref override
		if {$override ne ""} {
			set priority $override
		} elseif {[info exists typePriority($src)]} {
			set priority $typePriority($src)
		} else {
			set priority 0
		}

		if {$priority > $newprio} {
			set newloc $srcData
			set newprio $priority
		}
	}

	if {$newloc eq ""} {
		# no valid position
		adept set_location ""
		return
	}

	# record the location and maybe restart necessary programs with the new location
	lassign $newloc lat lon alt altref
	update_location $lat $lon

	# tell adept about the new location
	# (unless the location already came from adept)
	if {$src ne "adept"} {
		set last [adept last_reported_location]
		if {$last ne ""} {
			lassign $last lastLat lastLon lastAlt lastAltref
			set moved [expr {abs($lat - $lastLat) > 0.001 || abs($lon - $lastLon) > 0.001 || $altref ne $lastAltref || abs($alt - $lastAlt) > 50}]
		} else {
			# have not yet reported a position
			set moved 1
		}

		adept set_location $newloc

		if {$moved} {
			# trigger a healthcheck immediately to send the new position
			# if we didn't move much, it can wait until the next normal health update
			periodically_send_health_information
		}
	}
}

proc adept_location_changed {lat lon alt altref override} {
	handle_location_update "adept" $lat $lon $alt $altref $override
}

proc connect_to_gpsd {} {
	set ::gpsd [::fa_gps::GpsdClient #auto -callback gps_location_update]
	$::gpsd connect
}

# vim: set ts=4 sw=4 sts=4 noet :
