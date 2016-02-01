# -*- mode: tcl; tab-width: 4; indent-tabs-mode: t -*-
# Copyright (C) 2014 FlightAware LLC All Rights Reserved
#

#
# filesystem_usage - return key-value pairs of the percentage of storage
#  used for most local filesystems
#
#Filesystem     1K-blocks    Used Available Use% Mounted on
proc filesystem_usage {} {
	set result [list]
	set fp [open_nolocale "|/bin/df --local --portability"]
	gets $fp ;# skip header line
	gets $fp ;# skip semi-replicated line
	while {[gets $fp line] >= 0} {
		lassign $line filesystem blocks used available percent point
		if {$filesystem == "unionfs-fuse"} {
			continue
		}
		set percent [string range $percent 0 end-1]
		lappend result disk-$point $percent
	}
	close $fp
	return $result
}

#
# cpu_temperature - return the cpu temperature in degrees celsius
#
proc cpu_temperature {} {
    set fp [open /sys/class/thermal/thermal_zone0/temp]
    gets $fp temp
    close $fp

    set temp [format "%.1f" [expr {$temp / 1000.0}]]
	return $temp
}

#
# get_cpu_load - return the recent cpu load as a percentage (0-100)
#
proc get_cpu_load {} {
	if {[catch {lassign [get_cpu_ticks] load_ticks elapsed_ticks}] == 1} {
		return 0
	}

	set recent_load 0
	if {[info exists ::lastCPU]} {
		lassign $::lastCPU last_load_ticks last_elapsed_ticks
		if {$elapsed_ticks > $last_elapsed_ticks} {
			set recent_load [expr {round(100.0 * ($load_ticks - $last_load_ticks) / ($elapsed_ticks - $last_elapsed_ticks))}]
		}
	} else {
		# use load since boot
		if {$elapsed_ticks > 0} {
			set recent_load [expr {round(100.0 * $load_ticks / $elapsed_ticks)}]
		}
	}

	set ::lastCPU [list $load_ticks $elapsed_ticks]
	return $recent_load
}

proc get_cpu_ticks {} {
	set fp [open /proc/stat r]
	while 1 {
		gets $fp line
		set splitted [split $line " "]
		if {[lindex $splitted 0] eq "cpu"} {
			set others [lassign $splitted dummy dummy user nice sys idle]
			break
		}
	}
	close $fp

	if {![info exists others]} {
		return [list 0 0]
	}

	set total [expr {$user + $nice + $sys + $idle}]
	foreach x [split $others " "] {
		incr total $x
	}

	return [list [expr {$total - $idle}] $total]
}

#
# get_uptime - get uptime from /proc/uptime, return 0 if failed
#
proc get_uptime {} {
    if {[catch {set fp [open /proc/uptime]}] == 1} {
        return 0
    }
    gets $fp line
    close $fp
    regexp {([^ ]*) } $line dummy uptime
    return [expr {round($uptime)}]
}

#
# is_adsb_program_running - return 1 if the adsb program (probably dump1090)
# is running, else 0
#
proc is_adsb_program_running {} {
	# NB our intention is to go exclusively to the ::netstatus check
	# but we are falling back for now until we're sure it's all cool
	if {[info exists ::netstatus(status_30005)]} {
		return $::netstatus(status_30005)
	}

	return 0
}

#
# construct_health_array - set an array to contain health info about the machine
#
proc construct_health_array {_row} {
    upvar $_row row
    catch {array set row [filesystem_usage]}
	catch {set row(adsbprogram_running) [is_adsb_program_running]}
    catch {set row(cputemp) [cpu_temperature]}
    catch {set row(cpuload) [get_cpu_load]}
    catch {set row(uptime) [get_uptime]}

	if {[info exists ::netstatus(program_30005)]} {
		set row(adsbprogram) $::netstatus(program_30005)
	}

	if {[info exists ::netstatus(program_10001)]} {
		set row(transprogram) $::netstatus(program_10001)
	}

	catch {
		if {[get_default_gateway_interface_and_ip gateway iface ip]} {
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
		after cancel ::healthTimer
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
		adept update_location ""
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

proc adept_location_changed {lat lon} {
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
