# -*- mode: tcl; tab-width: 4; indent-tabs-mode: t -*-
#
# fa_adept - config file manager and client manager
#
# Copyright (C) 2014 FlightAware LLC, All Rights Reserved
#

set configParams [list user password autoUpdate manualUpdate mlat]
set booleanConfigParams [list autoUpdate manualUpdate mlat]
#
# process_parameters - look at params array and do things 
#
proc process_parameters {_params} {
    upvar $_params params

	set saveAdeptConfig 0

	# process password special by morphing it into either
	# a password or an empty string so it will be like
	# the other variables
    if {$params(password)} {
		set params(password) [get_password]
    } else {
		set params(password) ""
	}

	foreach param $::configParams {
		if {[lsearch $::booleanConfigParams $param] >= 0} {
			if {![string is boolean $params($param)]} {
				puts stderr "$param must be 1 or 0 not '$params($param)'"
			}
		}

		if {$params($param) != ""} {
			set_adept_config $param $params($param)
			set saveAdeptConfig 1
		}
	}

	# if a config variable was set, save the adept config
	if {$saveAdeptConfig} {
		save_adept_config
	}

    if {$params(start)} {
		start_piaware
    }

    if {$params(stop)} {
		stop_piaware
    }

    if {$params(restart)} {
		restart_piaware
    }

    if {$params(status)} {
		piaware_status
    }

	if {$params(show)} {
		show_piaware_config
	}
}

#
# get_password - read a password with not showing it even though i'm not
#  too sure not showing it helps
#
proc get_password {} {
	if {![info exists ::adeptConfig(user)]} {
		set userString ""
	} else {
		set userString "$::adeptConfig(user)'s "
	}
	exec stty -echo echonl <@stdin
	puts -nonewline stdout "please enter flightaware user ${userString}password: "
	flush stdout
	gets stdin line
	exec stty echo -echonl <@stdin
	return $line
}

#
# user_check - ensure they're running as root
#
proc user_check {} {
	if {[id user] != "root"} {
		puts stderr "$::argv0 must be run as user 'root', try 'sudo $::argv0...'"
		exit 4
	}
}

#
# piaware_pid - get the pid of piaware or return 0
#
proc piaware_pid {} {
	if {![file readable $::pidFile]} {
		return 0
	}

	set fp [open $::pidFile]
	gets $fp pid
	close $fp

	return $pid
}

#
# is_piaware_running - see if piaware is running by finding its pid file and
#  seeing if that process is alive
#
proc is_piaware_running {} {
	set pid [piaware_pid]
	if {$pid == 0} {
		return 0
	}

	if {[catch {kill -0 $pid} catchResult] == 1} {
		return 0
	}

	return 1
}

#
# invoke - invoke a program, saying what we're going to invoke and reporting
#  any nonzero exit status
#
proc invoke {command} {
	puts "invoking: $command"
	set status [system $command]
	if {$status != 0} {
		puts "command return nonzero exit status of $status"
	}
	return $status
}

#
# start_piware
#
proc start_piaware {} {
       invoke "/etc/init.d/piaware start"
}

#
# stop_piware
#
proc stop_piaware {} {
       invoke "/etc/init.d/piaware stop"
}

#
# restart_piware
#
proc restart_piaware {} {
       invoke "/etc/init.d/piaware restart"
}

#
# piaware_status
#
proc piaware_status {} {
	if {[is_piaware_running]} {
		puts "piaware is running"
	} else {
		puts "piaware is not running"
	}
}

proc show_piaware_config {} {
	if {[catch {set fp [open $::adeptConfigFile]} catchResult] == 1} {
		if {[lindex $::errorCode 1] == "ENOENT"} {
			puts "piaware config file '$::adeptConfigFile' doesn't exist"
		} else {
			puts "error opening piaware config file '$::adeptConfigFile': $catchResult"
		}
		return
	}

	puts "contents of piaware config file '$::adeptConfigFile':"
	while {[gets $fp line] >= 0} {
		puts $line
	}
	close $fp
}

# vim: set ts=4 sw=4 sts=4 noet :
