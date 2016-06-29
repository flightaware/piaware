# Package that contains various system-info-collecting helpers

package require fa_sudo

namespace eval ::fa_sysinfo {
	# filesystem_usage - return a list of mountpoint / percentage-used pairs
	proc filesystem_usage {} {
		set result [list]
		set fp [::fa_sudo::open_as "|/bin/df --output=target,pcent"]
		gets $fp ;# skip header line
		while {[gets $fp line] >= 0} {
			lassign $line mountpoint percent
			set percent [string range $percent 0 end-1]
			lappend result $mountpoint $percent
		}
		close $fp
		return $result
	}

	#
	# cpu_temperature - return the highest thermal zone temperature in degrees celsius
	#
	proc cpu_temperature {} {
		set result 0
		foreach path [lsort [glob -nocomplain "/sys/class/thermal/thermal_zone*/temp"]] {
			catch {
				set fp [open /sys/class/thermal/thermal_zone0/temp]
				gets $fp temp
				close $fp
				if {$temp > $result} {
					set result $temp
				}
			}
		}

		return [expr {$result / 1000.0}]
	}

	#
	# cpu_load - return the cpu load since the last call (or since boot if no previous call)
	# as a percentage (0-100)
	#
	variable lastCPU [list 0 0]
	proc cpu_load {} {
		variable lastCPU

	    lassign [cpu_ticks] load_ticks elapsed_ticks
		lassign $lastCPU last_load_ticks last_elapsed_ticks

		set recent_load 0
		if {$elapsed_ticks > $last_elapsed_ticks} {
			set recent_load [expr {round(100.0 * ($load_ticks - $last_load_ticks) / ($elapsed_ticks - $last_elapsed_ticks))}]
		} else {
			set recent_load 0
		}


		set lastCPU [list $load_ticks $elapsed_ticks]
		return $recent_load
	}

	# cpu_ticks - return a count of busy cpu ticks and total cpu ticks since boot
	proc cpu_ticks {} {
		if {[catch {set fp [open "/proc/stat" r]}]} {
			return [list 0 0]
		}
		try {
			while {[gets $fp line] >= 0} {
				set rest [lassign $line key user nice sys idle]
				if {$key eq "cpu"} {
					set total [expr {$user + $nice + $sys + $idle}]
					foreach x $rest {
						incr total $x
					}
					return [list [expr {$total - $idle}] $total]
				}
			}

			return [list 0 0]
		} finally {
			catch {close $fp}
		}
	}

	# uptime - returns system uptime in seconds from /proc/uptime, return 0 if failed
	proc uptime {} {
		if {[catch {set fp [open "/proc/uptime" r]}]} {
			return 0
		}
		gets $fp line
		close $fp
		lassign $line uptime idle
		return [expr {round($uptime)}]
	}

	# loadavg - return 1/5/15 minute load average from /proc/loadavg
	proc loadavg {} {
		if {[catch {set fp [open "/proc/loadavg" r]}]} {
			return [list 0.0 0.0 0.0]
		}
		gets $fp line
		close $fp
		lassign $line load1 load5 load15
		return [list $load1 $load5 $load15]
	}

	#
	# get_mac_address - return the mac address of eth0 as a unique handle
	#  to this device.
	#
	#  if there is no eth0 tries to find another mac address to use that it
	#  can hopefully repeatably find in the future
	#
	#  if we can't find any mac address at all then return an empty string
	#
	proc mac_address {} {
		set macFile /sys/class/net/eth0/address
		if {[file readable $macFile]} {
			set fp [open $macFile]
			gets $fp mac
			close $fp
			return $mac
		}

		# well, that didn't work, look at the entire output of ifconfig
		# for a MAC address and use the first one we find

		if {[catch {set fp [open_nolocale "|/sbin/ip -o link show"]} catchResult] == 1} {
			puts stderr "ip command not found on this version of Linux, you may need to install the iproute2 package and try again"
			return ""
		}

		set mac ""
		while {[gets $fp line] >= 0} {
			if {[regexp {^\d+: ([^:]+):.*link/ether ((?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2})} $line -> dev mac]} {
				# gotcha
				logger "no eth0 device, using $mac from device '$dev'"
				break
			}
		}

		catch {close $fp}
		return $mac
	}
}


}

package provide fa_sysinfo 0.1
