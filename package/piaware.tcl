

set piawarePidFile /var/run/piaware.pid

#
# is_pid_running - return 1 if the specified process ID is running, else 0
#
proc is_pid_running {pid} {
    if {[catch {kill -0 $pid} catchResult] == 1} {
	switch [lindex $::errorCode 1] {
	    "EPERM" {
		return 1
	    }

	    "ESRCH" {
		return 0
	    }

	    default {
		error "is_pid_running unexpectedly got '$catchResult' $::errorCode"
	    }
	}
    }
    return 1
}

#
# is_process_running - return 1 if at least one process named "name" is
#  running, else 0
#
proc is_process_running {name} {
    set fp [open "|ps -C $name -o pid="]
    while {[gets $fp line] >= 0} {
	set pid [string trim $line]
	if {[is_pid_running $pid]} {
	    catch {close $fp}
	    return 1
	}
    }
    catch {close $fp}
    return 0
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

    return [is_piaware_running]
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


proc process_netstat_socket_line {line} {
    lassign $line proto recvq sendq localAddress foreignAddress state pidProg
    lassign [split $pidProg "/"] pid prog

    if {$localAddress == "*:30005" && $state == "LISTEN"} {
	set ::netstatus(program_30005) $prog
	set ::netstatus(status_30005) 1
    }

    if {$localAddress == "*:10001" && $state == "LISTEN"} {
	set ::netstatus(program_10001) $prog
	set ::netstatus(status_10001) 1
    }


    switch $prog {
	"faup1090" {
	    if {$foreignAddress == "localhost:30005" && $state == "ESTABLISHED"} {
		set ::netstatus(faup1090_30005) 1
	    }
	}

	"piaware" {
	    set ::running(piaware) 1
	    if {$foreignAddress == "localhost:10001" && $state == "ESTABLISHED"} {
		set ::netstatus(piaware_10001) 1
	    }

	    if {$foreignAddress == "eyes.flightaware.com:1200" && $state == "ESTABLISHED"} {
		set ::netstatus(piaware_1200) 1
	    }
	}
    }
}

#
# inspect_sockets_with_netstat - run netstat and make a report
#
proc inspect_sockets_with_netstat {} {
    set ::running(dump1090) 0
    set ::running(faup1090) 0
    set ::running(piaware) 0
    set ::netstatus(status_30005) 0
    set ::netstatus(status_10001) 0
    set ::netstatus(faup1090_30005) 0
    set ::netstatus(piaware_10001) 0
    set ::netstatus(piaware_1200) 0

    set fp [open "|netstat --program --protocol=inet --tcp --wide --all"]
    # discard two header lines
    gets $fp
    gets $fp
    while {[gets $fp line] >= 0} {
	process_netstat_socket_line $line
    }
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
    if {[id user] != "root"} {
	puts "run 'sudo $::argv0' to get a more detailed report"
	return
    }

    inspect_sockets_with_netstat

    foreach port "30005 10001" {
	set statusvar "status_$port"
	set programvar "program_$port"

	if {!$::netstatus($statusvar)} {
	    puts "no program appears to be listening for connections on port $port."
	} else {
	    puts "$::netstatus($programvar) is listening for connections on port $port."
	}
    }

    if {$::netstatus(faup1090_30005)} {
	puts "faup1090 is connected to port 30005"
    }

    puts "[subst_is_or_is_not "piaware %s connected to port 10001." $::netstatus(piaware_10001)]"

    puts "[subst_is_or_is_not "piaware %s connected to FlightAware." $::netstatus(piaware_1200)]"
}

package provide piaware 1.0
