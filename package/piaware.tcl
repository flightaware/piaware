# -*- mode: tcl; tab-width: 4; indent-tabs-mode: t -*-
#
# piaware package - Copyright (C) 2014 FlightAware LLC
#
# Berkeley license
#

package require http
package require tls
package require Itcl
package require tryfinallyshim

set piawarePidFile /var/run/piaware.pid
set piawareConfigFile /etc/piaware

#
# do a pipe open after clearing locale vars
#
proc open_nolocale {args} {
	set oldenv [array get ::env]
	array unset ::env LANG
	array unset ::env LC_*
	try {
		return [::fa_sudo::open_as {*}$args]
	} finally {
		# work around http://core.tcl.tk/tcl/info/bc1a96407a
		# (::env is internally a traced variable, so trying to
		# "array set ::env" will trigger the bug)
		#
		# this bug is not present in 8.5 (Raspbian wheezy),
		# and was fixed in 8.6.3, but Raspbian jessie has 8.6.2.

		#array set ::env $oldenv
		foreach {k v} $oldenv {
			set ::env($k) $v
		}
	}
}

# query_dpkg_names_and_versions - Match installed package names and return a list
# of names and versions.
proc query_dpkg_names_and_versions {pattern} {
	set results [list]

	if {[catch {set fp [open "|dpkg-query --show $pattern 2>/dev/null"]}]} {
		# silently swallow
		return $results
	}

	while {[gets $fp line] >= 0} {
		if {[regexp {([^\t]*)\t(.*)} $line dummy packageName packageVersion]} {
			lappend results $packageName $packageVersion
		}
	}

	catch {close $fp}
	return $results
}

# is_pid_running - return 1 if the specified process ID is running, else 0
#
proc is_pid_running {pid} {
    if {[catch {kill -0 $pid} catchResult] == 1} {
		switch [lindex $::errorCode 1] {
			"EPERM" {
				# we didn't have permission to kill it but that we got this
				# means the process exists
				return 1
			}

			"ESRCH" {
				# no such process
				return 0
			}

			default {
				error "is_pid_running unexpectedly got '$catchResult' $::errorCode"
			}
		}
    }
	# no error from kill, that means the process exists and we had permissions
	# to kill it.  whatever, the main point is the process exists
    return 1
}

#
# find_processes - return a list of pids running with a command of exactly "name"
#
proc find_processes {name} {
	set pidlist {}
    set fp [::fa_sudo::open_as "|pgrep --exact $name"]
    while {[gets $fp line] >= 0} {
		set pid [string trim $line]
		lappend pidlist $pid
	}
    catch {close $fp}
	return $pidlist
}

#
# is_piaware_running - find out if piaware is running by checking its pid
#  file
#
proc is_piaware_running {} {
    if {[catch {set fp [open $::piawarePidFile]}] == 1} {
		return 0
    }

    gets $fp pid
    close $fp

    if {![string is integer -strict $pid]} {
		return 0
    }

    return [is_pid_running $pid]
}

#
# test_port_for_traffic - connect to a port and
#  see if we can read a byte before a timeout expires.
#
# invokes the callback with a 0 for no data received or a 1 for data recv'd
#
proc test_port_for_traffic {port callback {waitSeconds 60}} {
    if {[catch {set sock [socket localhost $port]} catchResult] == 1} {
		puts "got '$catchResult'"
		{*}$callback 0
		return
    }

    fconfigure $sock -buffering none \
		-translation binary \
		-encoding binary

    set timer [after [expr {$waitSeconds * 1000}] [list test_port_callback "" $sock 0 $callback]]
    fileevent $sock readable [list test_port_callback $timer $sock 1 $callback]
}

#
# test_port_callback - routine used by test_port_for_traffic to cancel
#  the timer and close the socket and invoke the callback
#
proc test_port_callback {timer sock status callback} {
    if {$timer != ""} {
		catch {after cancel $timer}
    }
    catch {close $sock}
    {*}$callback $status
}

#
# process_netstat_socket_line - process a line of output from the netstat
#   command
#
proc process_netstat_socket_line {line} {
    lassign $line proto recvq sendq localAddress foreignAddress state pidProg

	if {$proto ne "tcp" && $proto ne "tcp6"} {
		return
	}

	if {$pidProg eq "-"} {
		set pid "unknown"
		set prog "unknown"
	} else {
		lassign [split $pidProg "/"] pid prog
	}

    if {[string match "*:30005" $localAddress] && $state == "LISTEN"} {
		set ::netstatus(program_30005) $prog
		set ::netstatus(status_30005) 1
    }

    switch $prog {
		"faup1090" {
			if {[string match "*:30005" $foreignAddress] && $state == "ESTABLISHED"} {
				set ::netstatus(faup1090_30005) 1
			}
		}

		"piaware" {
			if {[string match "*:1200" $foreignAddress] && $state == "ESTABLISHED"} {
				set ::netstatus(piaware_1200) 1
			}
		}
    }
}

#
# inspect_sockets_with_netstat - run netstat and make a report
#
proc inspect_sockets_with_netstat {} {
    set ::netstatus(status_30005) 0
    set ::netstatus(faup1090_30005) 0
    set ::netstatus(piaware_1200) 0

	# try to run as root if we can, to get the program names
	set command [list netstat --program --protocol=inet --tcp --wide --all --numeric]
	if {[::fa_sudo::can_sudo root {*}$command]} {
		set fp [open_nolocale -root "|$command"]
	} else {
		# discard the warning about not being able to see all data
		set fp [open_nolocale "|$command 2>/dev/null"]
	}

    # discard two header lines
    gets $fp
    gets $fp
    while {[gets $fp line] >= 0} {
		process_netstat_socket_line $line
    }
    close $fp
}

#
# subst_is_or_is_not - substitute "is" or "is not" into a %s in string
#  based on if value is true or false
#
proc subst_is_or_is_not {string value} {
    if {$value} {
		set value "is"
    } else {
		set value "is NOT"
    }

    return [format $string $value]
}

#
# netstat_report - parse netstat output and report
#
proc netstat_report {} {
    inspect_sockets_with_netstat

	if {!$::netstatus(status_30005)} {
		puts "no program appears to be listening for connections on port 30005."
	} else {
		puts "$::netstatus(program_30005) is listening for connections on port 30005."
	}

    puts "[subst_is_or_is_not "faup1090 %s connected to port 30005." $::netstatus(faup1090_30005)]"
    puts "[subst_is_or_is_not "piaware %s connected to FlightAware." $::netstatus(piaware_1200)]"
}

#
# get_local_device_ip_address - figure out the specified device's IP address
#
# note - does not cache, returns empty string if the machine doesn't
#  have one
#
proc get_local_device_ip_address {dev} {
    set fp [open_nolocale "|ip address show dev $dev"]
    while {[gets $fp line] >= 0} {
        if {[regexp {inet ([^/]*)} $line dummy ip]} {
            catch {close $fp}
            return $ip
        }
    }
    # didn't find it, command might not have worked, make sure trying to
    # close it doesn't cause a traceback
    catch {close $fp}
    if {$dev == "eth0"} {
		warn_once "failed to get mac address for this computer. piaware will not work properly without it! are you running piaware on something other than a raspberry pi? piaware may need to be modified"
    }
    return ""
}

#
# get_local_ethernet_ip_address - figure out the ethernet port's IP address
#
proc get_local_ethernet_ip_address {} {
    return [get_local_device_ip_address eth0]
}

#
# get_default_gateway_interface_and_ip - assign the default gateway and 
#  interface to the passed-in variables and return 1 if successful in
# determining, else return 0
#
proc get_default_gateway_interface_and_ip {_gateway _iface _ip} {
    upvar $_gateway gateway $_iface iface $_ip ip

    set fp [open_nolocale "|netstat -rn"]
    gets $fp
    gets $fp

    while {[gets $fp line] >= 0} {
		if {[catch {lassign $line dest gateway mask flags mss window irtt iface}] == 1} {
			continue
		}
		if {$dest == "0.0.0.0"} {
			close $fp
			set ip [get_local_device_ip_address $iface]
			return 1
		}
	}
    close $fp
    return 0
}

#
# get_os_release - parse /etc/os-release and populate an array
#
proc get_os_release {_out} {
	upvar $_out out

	set f [open "/etc/os-release" "r"]
	while {[gets $f line] >= 0} {
		if {[regexp {^\s*([A-Za-z_]+)="(.+)"} $line -> key value]} {
			set out($key) $value
		} elseif {[regexp {^\s*([A-Za-z_]+)=(\S+)} $line -> key value]} {
			set out($key) $value
		}
	}
	close $f
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
proc get_mac_address {} {
	set macFile /sys/class/net/eth0/address
	if {[file readable $macFile]} {
		set fp [open $macFile]
		gets $fp mac
		close $fp
		return $mac
	}

	# well, that didn't work, look at the entire output of ifconfig
	# for a MAC address and use the first one we find

	if {[catch {set fp [open_nolocale "|ifconfig"]} catchResult] == 1} {
		puts stderr "ifconfig command not found on this version of Linux, you may need to install the net-tools package and try again"
		return ""
	}

	set mac ""
	while {[gets $fp line] >= 0} {
		set mac [parse_mac_address_from_line $line]
		set device ""
		regexp {^([^ ]*)} $line dummy device
		if {$mac != ""} {
			# gotcha
			logger "no eth0 device, using $mac from device '$device'"
			break
		}
	}

	catch {close $fp}
	return $mac
}

#
# parse_mac_address_from_line - find a mac address free-from in a line and
#   return it or return the empty string
#
proc parse_mac_address_from_line {line} {
	if {[regexp {(([0-9a-fA-F]{2}[:-]){5}([0-9a-fA-F]{2}))} $line dummy mac]} {
		return $mac
	}
	return ""
}

#
# warn_once - issue a warning message but only once
#
proc warn_once {message args} {
    if {[info exists ::warnOnceWarnings($message)]} {
		return
    }
    set ::warnOnceWarnings($message) ""

    logger "WARNING $message"
}

package provide piaware 1.0

# vim: set ts=4 sw=4 sts=4 noet :
