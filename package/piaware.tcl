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

set aptConfigDir [file join [file dirname [info script]] "apt"]
set aptRunScript [file join [file dirname [info script]] "helpers" "run-apt-get"]

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

	if {$pidProg eq ""} {
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

#
# reboot - reboot the machine
#
proc reboot {} {
    logger "rebooting..."
    system "/sbin/reboot"
}

#
# halt - halt the machine
#
proc halt {} {
	logger "halting..."
	system "/sbin/halt"
}

#
# update_package_lists
# runs apt-get update to update all package lists
#
proc update_package_lists {} {
	if {![run_apt_get setup-fa-repository [file join $::aptConfigDir "flightaware-archive-keyring.gpg"]]} {
		return 0
	}
	
    return [run_apt_get update]
}

#
# update_operating_system_and_packages 
#
# * upgrade raspbian (retain local changes, upgrade unchanged config files)
#
# * reboot
#
proc upgrade_all_packages {} {
    logger "*** attempting to upgrade all packages to the latest"

	# do these separately as they have different configfile requirements
	if {![upgrade_piaware]} {
		logger "aborting upgrade..."
		return 0
	}

	if {![upgrade_dump1090]} {
		logger "aborting upgrade..."
		return 0
	}

    if {![run_apt_get upgrade-raspbian]} {
		logger "aborting upgrade..."
		return 0
    }
    return 1
}

#
# run_apt_get - run the apt-get helper script as root
# and log all the output
#
proc run_apt_get {args} {
	run_command_as_root_log_output $::aptRunScript {*}$args
}

proc run_command_as_root_log_output {args} {
    logger "*** running command '$args' and logging output"
	if {[catch {set fp [::fa_sudo::popen_as -root -stdin "</dev/null" -stdout stdoutPipe -stderr stderrPipe -- {*}$args]} result]} {
		logger "*** error attempting to start command: $result"
		return 0
	}

	set name [file tail [lindex $args 0]]
	set childpid $result
	set ::pipesRunning($childpid) 2

	log_subprocess_output "${name}($childpid)" $stdoutPipe [list incr ::pipesRunning($childpid) -1]
	log_subprocess_output "${name}($childpid)" $stderrPipe [list incr ::pipesRunning($childpid) -1]

	while {$::pipesRunning($childpid) > 0} {
		vwait ::pipesRunning($childpid)
	}

	unset ::pipesRunning($childpid)

	if {[catch {wait $childpid} result]} {
		if {[lindex $::errorCode 0] eq "POSIX" && [lindex $::errorCode 1]  eq "ECHILD"} {
			logger "missed child termination status for pid $childpid, assuming all is OK"
			return 1
		} else {
			logger "unexpected error waiting for child: $::errorCode"
			return 0
		}
	}

	lassign $result deadpid type code
	if {$type eq "EXIT" && $code eq 0} {
		return 1
	} else {
		logger "child process $deadpid exited with status $type $code"
		return 0
	}
}


#
# upgrade_piaware - upgrade piaware via apt-get; install source lists / keys if missing
#
proc upgrade_piaware {} {
	return [single_package_upgrade "piaware"]
}


#
# upgrade_dump1090 - upgrade dump1090-fa via apt-get; install source lists / keys if missing
#
proc upgrade_dump1090 {} {
	return [single_package_upgrade "dump1090-fa"]
}

#
# single_package_upgrade: update a single FA package, force package config files
#
proc single_package_upgrade {pkg} {
	# run the update/upgrade
    if {![run_apt_get upgrade-fa $pkg]} {
		logger "aborting upgrade..."
		return 0
    }

	logger "upgrade of $pkg seemed to go OK"
	return 1
}

#
# restart_piaware - restart the piaware program, called from the piaware
# program, so it's a bit tricky
#
proc restart_piaware {} {
	# unlock the pidfile if we have a lock, so that the new piaware can
	# get the lock even if we're still running.
	unlock_pidfile

	logger "restarting piaware. hopefully i'll be right back..."
	invoke_service_action piaware restart

	# sleep apparently restarts on signals, we want to process them,
	# so use after/vwait so the event loop runs.
	after 10000 [list set ::die 1]
	vwait ::die

	logger "piaware failed to die, pid [pid], that's me, i'm gonna kill myself"
	exit 0
}

#
# console.tcl - Itcl class to generate a server socket on a specified port that
#  provides a console interface for the application that can be telnetted to.
#
#  requires inbound connections to come from localhost
#
# Usage:
#
#   IpConsole console
#   console setup_server -port 8888
#
#   telnet localhost 8888
#

catch {::itcl::delete class IpConsole}

::itcl::class IpConsole {
    public variable port 8888
    public variable connectedSockets ""

    protected variable serverSock

    constructor {args} {
		configure {*}$args
    }

    destructor {
        stop_server
    }

	method logger {message} {
		::logger "(console) $message"
	}

    #
    # handle_connect_request - handle a request to connect to the console
    #  port from a remote client
    #
    method handle_connect_request {socket ip port} {
		logger "connect from $socket $ip $port"
		if {$ip != "127.0.0.1"} {
			logger "ip not localhost, ignored"
			close $socket
			return
		}
		fileevent $socket readable "$this handle_remote_request $socket"
		fconfigure $socket -blocking 0 -buffering line

		puts $socket [list connect "$::argv0 - connect from $ip $port - help for help"]

		# add the socket to the list of connected sockets if it's not there already
	    set whichSock [lsearch -exact $connectedSockets $socket]
		if {$whichSock < 0} {
			lappend connectedSockets $socket
		}
    }

	#
	# close_client_socket - close a socket on a client connection, removing
	#  it from the list of connected sockets (if it can be found there)
	#  and making sure the close doesn't cause a traceback no matter what
	#
	method close_client_socket {sock} {
	    # remove the socket from the list of connected sockets
	    set whichSock [lsearch -exact $sock $connectedSockets]
		if {$whichSock >= 0} {
		    set connectedSockets [lreplace $connectedSockets $whichSock $whichSock]
		}

		if {[catch {close $sock} catchResult] == 1} {
		    logger "error closing $sock: $catchResult (ignored)"
		}
	}

    #
    # handle_remote_request - handle a request from a connected client
    #
    method handle_remote_request {sock} {
		if {[eof $sock]} {
			logger "EOF on $sock"
			close_client_socket $sock
			return
		}

		if {[gets $sock line] >= 0} {
			switch -- $line {
				"help" {
					puts $sock [list ok "quit, exit - disconnect, help - this help, !quit, !exit, !help - execute quit, exit or help on the server"]
					return
				}

				"quit" {
					puts $sock [list ok goodbye]
					close_client_socket $sock
					logger "client disconnected by 'quit' command"
					return
				}

				"exit" {
					puts $sock [list ok "goodbye, use !exit to exit the server"]
					close_client_socket $sock
					logger "client disconnected by 'exit' command"
					return
				}

				"!quit" {
					# they want us to send a quit to the server
					set line "quit"
				}

				"!exit" {
					# they want us to send "exit" to the server
					set line "exit"
				}

				"!help" {
					set line "help"
				}
			}

			if {[catch {uplevel #0 $line} result] == 1} {
				puts $sock [list error $result]
			} else {
				puts $sock [list ok $result]
			}
		}
    }

    #
    # setup_server - set up to accept connections on the server port
    #
    method setup_server {args} {
		eval configure $args

		stop_server

		if {[catch {socket -server [list $this handle_connect_request] $port} serverSocket] == 1} {
			logger "Error opening server socket: $port: $serverSocket"
			return 0
		}
		return 1
    }

    #
    # stop_server - stop accepting connections on the server socket
    #
    method stop_server {} {
		if {[info exists serverSock]} {
			if {[catch {close $serverSock} result] == 1} {
				logger "Error closing server socket '$serverSock': $result"
			}
			unset serverSock
		}
    }
}

package provide piaware 1.0

# vim: set ts=4 sw=4 sts=4 noet :
