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
package require fa_sudo

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

	set queryargs [list dpkg-query --showformat {${binary:Package} ${Version} ${Status}\n} --show $pattern]
	if {[catch {set pipe [::fa_sudo::open_as "|$queryargs" "r"]}]} {
		# silently swallow
		return $results
	}

	while {[gets $pipe line] >= 0} {
		lassign [split $line " "] pkg version status_want status_eflag status_status
		if {$status_want eq "install" || $status_status eq "installed"} {
			lappend results $pkg $version
		}
	}

	catch {close $pipe}
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
proc test_port_for_traffic {host port callback {waitSeconds 60}} {
    if {[catch {set sock [socket $host $port]} catchResult] == 1} {
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
		set prog "unknown process"
	} else {
		lassign [split $pidProg "/"] pid prog
	}

	if {$state == "LISTEN" && [regexp {(.*):(\d+)} $localAddress -> addr port]} {
		set ::netstatus($port) [list $prog $pid]
    }

    switch $prog {
		"faup1090" {
			if {$state == "ESTABLISHED"} {
				set ::netstatus_faup1090 1
			}
		}

		"faup978" {
			if {$state == "ESTABLISHED"} {
				set ::netstatus_faup978 1
			}
		}

		"piaware" {
			if {[string match "*:1200" $foreignAddress] && $state == "ESTABLISHED"} {
				set ::netstatus_piaware 1
			}
		}
    }
}

#
# inspect_sockets_with_netstat - run netstat and make a report
#
proc inspect_sockets_with_netstat {} {
	array unset ::netstatus
	set ::netstatus_faup1090 0
	set ::netstatus_faup978 0
	set ::netstatus_piaware 0
	set ::netstatus_reliable 0

	# try to run as root if we can, to get the program names
	if {[catch {
		set command [list netstat --program --tcp --wide --all --numeric]
		if {[::fa_sudo::can_sudo root {*}$command]} {
			set ::netstatus_reliable 1
			set fp [open_nolocale -root "|$command 2>/dev/null"]
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
	} result]} {
		logger "failed to run netstat: $result"
		set ::netstatus_reliable 0
	}
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


# return the local receiver port for message type (ES or UAT), or 0 if it is remote
proc receiver_local_port {config message_type} {
	lassign [receiver_host_and_port $config $message_type] host port
	if {$host eq "localhost" || [string match "127.*" $host]} {
		return $port
	} else {
		return 0
	}
}

# return the local service name for message type (ES or UAT), or "" if unknown
proc receiver_local_service {config message_type} {
	switch -- $message_type {
		# 1090
		ES {
			switch -- [$config get receiver-type] {
				sdr - rtlsdr { return "dump1090" }
				bladerf    { return "dump1090" }
				beast      { return "beast-splitter" }
				relay      { return "beast-splitter" }
				radarcape  { return "beast-splitter" }
				radarcape-local  { return "" }
				other      { return "" }
				none   	   { return "" }
				default    { error "unknown receiver type configured: [$config get receiver-type]" }
			}
		}

		# 978
		UAT {
			switch -- [$config get uat-receiver-type] {
				sdr - rtlsdr { return "dump978" }
				none   	   { return "" }
				default	   { error "unknown UAT receiver type configured: [$config get uat-receiver-type]" }
			}
		}

		default {
			error "invalid message_type supplied"
		}
	}
}

# return a brief description of what we receive data from
proc receiver_description {config message_type} {
	switch -- $message_type {
		# 1090
		ES {
			switch -- [$config get receiver-type] {
				sdr - rtlsdr - bladerf {
					return "dump1090"
				}
				beast {
					return "the Mode-S Beast serial port"
				}
				relay - other {
					return "the ADS-B data program at [$config get receiver-host]/[$config get receiver-port]"
				}
				radarcape {
					return "the Radarcape at [$config get radarcape-host]"
				}
				radarcape-local {
					return "the local Radarcape"
				}
				none {
					return ""
				}
				default {
					error "unknown receiver type configured: [$config get receiver-type]"
				}
			}
		}

		# 978
		UAT {
			switch -- [$config get uat-receiver-type] {
				sdr {
					return "dump978"
				}
				none {
					return ""
				}
				default {
					error "unknown UAT receiver type configured: [$config get uat-receiver-type]"
				}
			}
		}

		default {
			error "invalid message type supplied"
		}
	}
}

# return the receiver host and port we fetch data from as a list
# (if we are configured to relay, this returns the relay host/port,
# not the actual receiver host/port)
proc receiver_host_and_port {config message_type} {
	switch -- $message_type {
		# 1090
		ES {
			switch -- [$config get receiver-type] {
				sdr - rtlsdr { return [list localhost 30005] }
				bladerf    { return [list localhost 30005] }
				beast      { return [list localhost 30005] }
				relay      { return [list localhost 30005] }
				radarcape  { return [list localhost 30005] }
				radarcape-local  { return [list localhost 10006] }
				other      { return [list [$config get receiver-host] [$config get receiver-port]] }
				none       { return [list localhost 30005] }
				default    { error "unknown receiver type configured: [$config get receiver-type]" }
			}
		}

		# 978
		UAT {
			switch -- [$config get uat-receiver-type] {
				sdr    	   { return [list localhost 30978] }
				none       { return [list localhost 30978] }
				default    { error "unknown UAT receiver type configured [$config get uat-receiver-type]" }
			}
		}

		default {
			error "invalid message_type supplied"
		}
	}
}

# return the underlying receiver host and port as a list
# (if we are configured to relay, this returns the actual receiver host/port,
# not the host/port of our relay)
proc receiver_underlying_host_and_port {config message_type} {
	switch -- $message_type {
		# 1090
		ES {
			switch -- [$config get receiver-type] {
				sdr - rtlsdr { return [list localhost 30005] }
				bladerf    { return [list localhost 30005] }
				beast      { return [list localhost 30005] }
				relay      { return [list [$config get receiver-host] [$config get receiver-port]] }
				radarcape  { return [list [$config get radarcape-host] 10003] }
				radarcape-local  { return [list localhost 10006] }
				other      { return [list [$config get receiver-host] [$config get receiver-port]] }
				none       { return [list localhost 30005] }
				default    { error "unknown receiver type configured: [$config get receiver-type]" }
			}
		}

		# 978
		UAT {
			switch -- [$config get uat-receiver-type] {
				sdr	       { return [list localhost 30978] }
				none       { return [list localhost 30978] }
				default	   { error "unknown UAT receiver type configured: [$config get uat-receiver-type]" }
			}
		}

		default {
			error "invalid message_type supplied"
		}
	}
}

# return the data format expected from the receiver
# (in the form that mlat-client understands)
proc receiver_data_format {config message_type} {
	switch -- $message_type {
		# 1090
		ES {
			switch -- [$config get receiver-type] {
				sdr - rtlsdr { return "dump1090" }
				bladerf    { return "dump1090" }
				beast      { return "beast" }
				relay      { return "auto" }
				radarcape  { return "radarcape" }
				radarcape-local  { return "radarcape" }
				other      { return "auto" }
				none       { return "auto" }
				default    { error "unknown receiver type configured: [$config get receiver-type]" }
			}
		}

		UAT {
			switch -- [$config get uat-receiver-type] {
				sdr	       { return "dump978" }
				none       { return "auto" }
				default    { error "Unknown UAT receiver type configured: [$config get uat-receiver-type]" }
			}
		}

		default {
			error "invalid message_type supplied"
		}
	}
}

package provide piaware 1.0

# vim: set ts=4 sw=4 sts=4 noet :
