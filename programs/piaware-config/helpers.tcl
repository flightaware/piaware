#
# fa_adept - config file manager and client manager
#
# Copyright (C) 2014 FlightAware LLC, All Rights Reserved
#

#
# process_parameters - look at params array and do things 
#
proc process_parameters {_params} {
    upvar $_params params

    if {$params(user) != ""} {
		set_adept_config user $params(user)
		save_adept_config
    }

    if {$params(password)} {
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
		set_adept_config password $line
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

# vim: set ts=4 sw=4 sts=4 noet :
