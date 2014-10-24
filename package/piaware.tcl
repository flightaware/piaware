#
# piaware package - Copyright (C 2014 FlightAware LLC
#
# Berkeley license
#

set piawarePidFile /var/run/piaware.pid
set piawareConfigFile /etc/piaware

#
# load_piaware_config - load the piaware config file.  don't stop if it
#  doesn't exist
#
# return 1 if it loaded cleanly, 0 if it had a problem or didn't exist
#
proc load_piaware_config {} {
    if {[catch [list uplevel #0 source $::piawareConfigFile]] == 1} {
	return 0
    }
    return 1
}

#
# query_piaware_pkg - Figure out piaware package name and version
#
# Find a package that has piaware in the name.  There will about for sure
# be only one.
#
# Parse out the name and version into passed-in variables and return
#  1 if successful or 0 if unsuccessful
#
proc query_piaware_pkg {_packageName _packageVersion} {
    upvar $_packageName packageName $_packageVersion packageVersion

    if {[catch {set fp [open "|dpkg-query --show *piaware* 2>/dev/null"]} ] } {
        logger "unable to run dpkg-query! can't determine piaware package info"
        return 0
    }
    gets $fp line

    if {[catch {close $fp}] == 1} {
	return 0
    }

    if {![regexp {([^\t]*)\t(.*)} $line dummy packageName packageVersion]} {
	return 0
    }

    return 1
}

#
# load_piaware_config_and_stuff - invoke load_piaware_config and if it
#   doesn't define imageType then see if the piaware package is installed
#   and if it is then set imageType to package
#
proc load_piaware_config_and_stuff {} {
    load_piaware_config

    if {![info exists ::imageType]} {
	if {[query_piaware_pkg packageName packageVersion]} {
	    set ::imageType "${packageName}_package"
	}
    }
}

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

#
# reap_any_dead_children - wait without delay until we reap no children
#
proc reap_any_dead_children {} {
    # try to reap any dead children
    while {true} {
	if {[catch {wait -nohang} catchResult] == 1} {
	    # got an error, probably no children
	    return
	}

	# didn't get an error
	if {$catchResult == ""} {
	    # and it didn't return anything, we have extant children but
	    # none have exited (or died from a signal) right now
	    return
	}

	#logger "reaped child $catchResult"

	lassign $catchResult pid type code

	switch $type {
	    "EXIT" {
		switch $code {
		    default {
			logger "the system told us that process $pid exited due to some general error"
		    }
		    98 {
			logger "the system confirmed that process $pid exited.  the exit status of $code tells us that faup1090 couldn't open the listening port because something else already has it open"
		    }

		    0 {
			logger "the system told us that process $pid exited cleanly"
		    }
		}
		logger "the system confirmed that process $pid exited with an exit status of $code"
	    }

	    "SIG" {
		if {$code == "SIGHUP"} {
		    logger "the system confirmed that process $pid exited after receiving a hangup signal"
		} else {
		    logger "this is a little unexpected: the system told us that process $pid exited after receiving a $code signal"
		}
	    }

	    default {
		logger "the system told us one of our child processes exited but i didn't understand what it said: $catchResult"
	    }
	}
    }
}

#
# get_local_device_ip_address - figure out the specified device's IP address
#
# note - does not cache, returns empty string if the machine doesn't
#  have one
#
proc get_local_device_ip_address {dev} {
    set fp [open "|ip address show dev $dev"]
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

    set fp [open "|netstat -rn"]
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
# reboot - reboot
#
proc reboot {} {
    logger "rebooting..."
    system "/sbin/reboot"
}

#
# update_operating_system_and_packages 
#
# * upgrade raspbian
#
# * upgrade piaware
#
# * reboot
#
proc update_operating_system_and_packages {} {
    upgrade_raspbian
    upgrade_piaware
    reboot
}

#
# run_program_log_output - run command with stderr redirected to stdout and
#   log all the output of the command
#
proc run_program_log_output {command} {
    logger "*** running command '$command' and logging output"

    if {[catch {set fp [open "|$command 2>&1"]} catchResult] == 1} {
	logger "*** error attempting to start command: $catchResult"
	return 0
    }

    while {[gets $fp line] >= 0} {
	logger "> $line"
    }

    if {[catch {close $fp} catchResult] == 1} {
	logger "*** error closing pipeline to command: $catchResult, continuing..."
    } else {
	logger "command '$command' completed"
    }
    return 1
}

#
# upgrade_raspbian - upgrade raspbian to the latest packages, kernel,
#  libraries, boot files and whatnot
#
proc upgrade_raspbian {} {
    logger "*** attempting to upgrade raspbian to the latest"

    if {![run_program_log_output "apt-get --yes update"]} {
	logger "aborting upgrade..."
	return 0
    }

    if {![run_program_log_output "apt-get --yes upgrade"]} {
	logger "aborting upgrade..."
	return 0
    }

    if {![run_program_log_output "rpi-update"]} {
	logger "aborting upgrade..."
	return 0
    }

    return 1
}

#
# upgrade_piaware - fetch file information about the latest version of piaware
#
# check it for reasonability
#
# compare it to the version we're running and if it's not current, update
# the current site
#
proc upgrade_piaware {} {
    if {[catch {set fp [open "|wget --output-document=- https://flightaware.com/adsb/piaware/files/latest"]} catchResult] == 1} {
	logger "unable to upgrade piaware: got '$catchResult' trying to fetch the name of the latest version"
	return 0
    }

    set version [gets $fp line]
    close $fp

    if {[string first / $version] >= 0} {
	logger "unable to upgrade piaware: illegal character in version '$version'"
	return 0
    }

    if {[string match "*$piawareVersion*" $version]} {
	logger "already running the latest version of piaware"
	return 0
    }

    set url https://flightaware.com/adsb/piaware/files/$version
    logger "fetching latest piaware version from $url"

    set outputFile /tmp/$version
    set exitStatus [system "wget --output-document=$outputFile https://flightaware.com/adsb/piaware/files/$version"]

    logger "installing piaware..."
    run_program_log_output "dpkg -i $outputFile"

    logger "installing any required dependencies"
    run_program_log_output "apt-get install -fy"

    return 1

}

package provide piaware 1.0
