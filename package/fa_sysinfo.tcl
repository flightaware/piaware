# Package that contains various system-info-collecting helpers

package require fa_sudo

namespace eval ::fa_sysinfo {
	# filesystem_usage - return a list of mountpoint / percentage-used pairs
	proc filesystem_usage {} {
		set result [list]
		set fp [::fa_sudo::open_as "|/bin/df --output=target,pcent"]
		try {
			gets $fp ;# skip header line
			while {[gets $fp line] >= 0} {
				lassign $line mountpoint percent
				set percent [string range $percent 0 end-1]
				lappend result $mountpoint $percent
			}
		} finally {
			catch {close $fp}
		}
		return $result
	}

	#
	# cpu_temperature - return the highest thermal zone temperature in degrees celsius
	#
	proc cpu_temperature {} {
		set result 0
		foreach path [lsort [glob -nocomplain "/sys/class/thermal/thermal_zone*/temp"]] {
			set temp [sysfs_value $path 0]
			if {$temp > $result} {
				set result $temp
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
		set result [list 0 0]
		catch {
			set fp [open "/proc/stat" r]
			try {
				while {[gets $fp line] >= 0} {
					set rest [lassign $line key user nice sys idle]
					if {$key eq "cpu"} {
						set total [expr {$user + $nice + $sys + $idle}]
						foreach x $rest {
							incr total $x
						}
						set result [list [expr {$total - $idle}] $total]
						break
					}
				}
			} finally {
				catch {close $fp}
			}
		}

		return $result
	}

	# uptime - returns system uptime in seconds from /proc/uptime, return 0 if failed
	proc uptime {} {
		set result 0
		catch {
			set fp [open "/proc/uptime" r]
			try {
				gets $fp line
			} finally {
				catch {close $fp}
			}
			lassign $line uptime idle
			set result [expr {round($uptime)}]
		}

		return $result
	}

	# loadavg - return 1/5/15 minute load average from /proc/loadavg
	proc loadavg {} {
		set result [list 0.0 0.0 0.0]
		catch {
			set fp [open "/proc/loadavg" r]
			try {
				gets $fp line
			} finally {
				catch {close $fp}
			}
			lassign $line load1 load5 load15
			set result [list $load1 $load5 $load15]
		}
		return $result
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
		# try eth0 directly
		set mac [sysfs_value "/sys/class/net/eth0/address" ""]
		if {$mac ne ""} {
			return $mac
		}

		# well, that didn't work, look at the entire output of "ip link"
		# for a MAC address and use one that looks sensible.
		#
		# look at Raspberry Pi OUI (Pi4) interfaces,
		# broadcom OUI (Pi 1-3) interfaces,
		# other UP interfaces,
		# and everything else, in that order. If there's still a tie,
		# use the interface name as a tiebreaker.

		if {[catch {set fp [::fa_sudo::open_as "|/sbin/ip -o link show"]} catchResult] == 1} {
			puts stderr "ip command not found on this version of Linux, you may need to install the iproute2 package and try again"
			return ""
		}

		try {
			set candidates [list]
			while {[gets $fp line] >= 0} {
				if {[regexp -nocase {^\d+: ([^:]+):.*state (\S+).*link/ether ((?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2})} $line -> dev state mac]} {
					switch -glob -nocase -- "$state|$mac" {
						"*|dc:a6:32:*" {
							# RPi OUI, any state
							set prio 0
						}

						"*|b8:27:eb:*" {
							# Broadcom OUI, any state
							set prio 1
						}

						"UP|*" {
							# Other OUI, interface is up
							set prio 2
						}

						default {
							# Other OUI, interface is not up
							set prio 3
						}
					}

					lappend candidates [list $prio $dev $mac]
				}
			}

			# sort by priority, then by interface name (lsort is a stable sort)
			# (nb: if systemd predictable interface naming is in use, then
			# wired-ethernet "en" sorts before wireless "wl" which is what
			# we'd prefer)
			set candidates [lsort -index 1 $candidates]
			set candidates [lsort -integer -index 0 $candidates]
			if {[llength $candidates] > 0} {
				lassign [lindex $candidates 0] prio dev mac
				return $mac
			}

			# nothing suitable
			return ""
		} finally {
			catch {close $fp}
		}
	}

	proc interface_ip_and_prefix {dev} {
		set fp [::fa_sudo::open_as "|ip -o address show dev $dev"]
		try {
			while {[gets $fp line] >= 0} {
				if {[regexp {inet ([^/]*)/(\S+)} $line -> ip prefix]} {
					return [list $ip $prefix]
				}
			}
		} finally {
			catch {close $fp}
		}

		return [list "" ""]
	}

	#
	# interface_ip_address - figure out the specified device's IP address
	#
	# note - does not cache, returns empty string if the machine doesn't
	#  have one
	#
	proc interface_ip_address {dev} {
		lassign [interface_ip_and_prefix $dev] addr prefix
		return $addr
	}

	# interface_netmask - figure up the specified device's netmask
	proc interface_netmask {dev} {
		lassign [interface_ip_and_prefix $dev] addr prefix
		if {$prefix eq ""} {
			return ""
		}

		set netmask [expr {0xFFFFFFFF << (32 - $prefix)}]
		set b1 [expr {($netmask & 0xFF000000) >> 24}]
		set b2 [expr {($netmask & 0x00FF0000) >> 16}]
		set b3 [expr {($netmask & 0x0000FF00) >> 8}]
		set b4 [expr {($netmask & 0x000000FF)}]
		return [format "%d.%d.%d.%d" $b1 $b2 $b3 $b4]
	}

	# generic fetcher for sysfs values
	proc sysfs_value {path def} {
		set state $def
		catch {
			set fp [open $path]
			try {
				gets $fp state
			} finally {
				catch {close $fp}
			}
		}
		return $state
	}

	# generic fetcher for per-interface sysfs values
	proc interface_sysfs_value {dev path def} {
		return [sysfs_value "/sys/class/net/$dev/$path" $def]
	}

	# return the state of the given interface ("up"/"down"/"unknown")
	proc interface_state {dev} {
		return [interface_sysfs_value $dev "operstate" "unknown"]
	}

	# return the interface speed in Mbps, or "" if unknown
	proc interface_speed {dev} {
		return [interface_sysfs_value $dev "speed" ""]
	}

	# return the interface duplex setting, or "" if unknown"
	proc interface_duplex {dev} {
		return [interface_sysfs_value $dev "duplex" ""]
	}

	# return the number of bytes transmitted on the interface, or 0 if unknown
	proc interface_tx_bytes {dev} {
		return [interface_sysfs_value $dev "statistics/tx_bytes" 0]
	}

	# return the number of packets transmitted on the interface, or 0 if unknown
	proc interface_tx_packets {dev} {
		return [interface_sysfs_value $dev "statistics/tx_packets" 0]
	}

	# return the number of bytes received on the interface, or 0 if unknown
	proc interface_rx_bytes {dev} {
		return [interface_sysfs_value $dev "statistics/rx_bytes" 0]
	}

	# return the number of packets received on the interface, or 0 if unknown
	proc interface_rx_packets {dev} {
		return [interface_sysfs_value $dev "statistics/rx_packets" 0]
	}

	# route_to_flightaware - find the gateway / interface / source IP for traffic to FlightAware
	proc route_to_flightaware {_gateway _iface _ip} {
		upvar $_gateway gateway $_iface iface $_ip ip
		return [route_to 70.42.6.191 gateway iface ip]
	}

	# route_to - find the gateway / interface / source IP for traffic to a given IP
	proc route_to {target _gateway _iface _ip} {
		upvar $_gateway gateway $_iface iface $_ip ip

		set iface ""
		set gateway ""
		set ip ""

		set fp [::fa_sudo::open_as "|ip -o route get to $target"]
		try {
			while {[gets $fp line] >= 0} {
				if {[lindex $line 0] ne $target} {
					continue
				}

				for {set i 1} {$i < [llength $line]} {incr i} {
					set item [lindex $line $i]
					if {$item eq "via"} {
						incr i
						set gateway [lindex $line $i]
						continue
					}
					if {$item eq "dev"} {
						incr i
						set iface [lindex $line $i]
						continue
					}
					if {$item eq "src"} {
						incr i
						set ip [lindex $line $i]
						continue
					}
				}
			}
		} finally {
			catch {close $fp}
		}

		if {$gateway ne "" && $iface ne "" && $ip ne ""} {
			return 1
		} else {
			return 0
		}
	}

	#
	# wireless_interface - select a wireless interface to use and return its name
	#
	proc wireless_interface {} {
		set candidates [list]
		foreach interface [glob -nocomplain -tails -directory /sys/class/net *] {
			if {![file isdirectory /sys/class/net/$interface/wireless]} {
				continue
			}

			# ignore wifi that has rfkill set
			set rfkill 0
			set rfkillPath [glob -nocomplain -directory /sys/class/net/$interface/phy80211 rfkill*/state]
			if {$rfkillPath ne ""} {
				set rfkillState [sysfs_value [lindex $rfkillPath 0] 1]
				if {$rfkillState ne 1} {
					set rfkill 1
				}
			}

			if {!$rfkill} {
				# if we have a Pi / broadcom wifi (probably the Pi 3 built-in wifi)
				# and also something else
				# then prefer the something else
				if {[string match -nocase b8:27:eb:* [interface_sysfs_value $interface address ""]] ||
					[string match -nocase dc:a6:32:* [interface_sysfs_value $interface address ""]]} {
					lappend candidates [list "2:$interface" $interface]
				} else {
					lappend candidates [list "1:$interface" $interface]
				}
			}
		}

		return [lindex [lindex [lsort -index 0 $candidates] 0] 1]
	}

	#
	# os_release_info - parse /etc/os-release and return a key-value list
	#
	proc os_release_info {} {
		set result ""

		set f [open "/etc/os-release" "r"]
		try {
			while {[gets $f line] >= 0} {
				if {[regexp {^\s*([A-Za-z_]+)="(.+)"} $line -> key value]} {
					lappend result $key $value
				} elseif {[regexp {^\s*([A-Za-z_]+)=(\S+)} $line -> key value]} {
					lappend result $key $value
				}
			}
		} finally {
			catch {close $f}
		}

		return $result
	}

	#
	# ntp_status - extract the specified vars (or "stratum" and "offset" if
	# none are specified) from from the local ntp via the "rv" ntpq command.
	#
	# returns a key-value list suitable for 'array set'
	# returns an empty list on failure
	#
	proc ntp_status {args} {
		if {[llength $args] == 0} {
			set args {stratum offset}
		}

		set result [list]
		set options "-c {timeout 100}"	 ;# milliseconds, actual is about 2x this
		foreach item $args {
			append options " -c {rv 0 $item}"  ;# read system (assocID 0) variable
		}

		set f [open "|ntpq $options" "r"]
		try {
			while {[gets $f line] >= 0} {
				set sep [string first "=" $line]
				if {$sep >= 0} {
					set key [string trim [string range $line 0 $sep-1]]
					set value [string trim [string range $line $sep+1 end]]
					if {$key in $args} {
						lappend result $key $value
					}
				}
			}
		} finally {
			catch {close $f}
		}

		return $result
	}
}

package provide fa_sysinfo 0.1
