# Copyright (C) 2014 FlightAware LLC All Rights Reserved
#

#
# filesystem_usage - return key-value pairs of the percentage of storage
#  used for most local filesystems
#
#Filesystem     1K-blocks    Used Available Use% Mounted on
proc filesystem_usage {} {
	set result [list]
	set fp [open "|/bin/df --local --portability"]
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
	catch {set row(adsbprogram_runing) [is_adsb_program_running]}
    catch {set row(cputemp) [cpu_temperature]}
    catch {set row(uptime) [get_uptime]}

	if {[info exists ::netstatus(program_30005)]} {
		set row(adsbprogram) $::netstatus(program_30005)
	}

	if {[info exists ::netstatus(program_10001)]} {
		set row(transprogram) $::netstatus(program_10001)
	}

	set row(type) health

    # do clock last to maximize accurace
    set row(clock) [clock seconds]
}

#
# periodically_send_health_information - every few minutes marshall up the
#  health information and forward it
#
proc periodically_send_health_information {} {
    after 300000 periodically_send_health_information

	if {![adept is_logged_in]} {
		return
	}

    construct_health_array row

    set list [list]
    foreach element [lsort [array names row]] {
		lappend list $element $row($element)
    }

	send_line [join $list "\t"]
}

# vim: set ts=4 sw=4 sts=4 noet :
