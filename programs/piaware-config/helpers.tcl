# -*- mode: tcl; tab-width: 4; indent-tabs-mode: t -*-
#
# fa_adept - config file manager and client manager
#
# Copyright (C) 2014 FlightAware LLC, All Rights Reserved
#

package require fa_piaware_config
package require tryfinallyshim

proc load_config {} {
	global config

	if {![info exists config]} {
		set config [::fa_piaware_config::new_combined_config #auto]
		set problems [$config read_config]
		foreach problem $problems {
			puts stderr "warning: $problem"
		}
	}
}

proc update_config_values {argv} {
	global config
	load_config

	foreach {key val} $argv {
		if {$key eq ""} {
			puts stderr "warning: ignoring '$keyval': it should be in the form config-option=new-value"
			continue
		}

		if {![$config metadata exists $key]} {
			puts stderr "warning: cannot set option '$key', it is not a known config option"
			continue
		}

		if {[$config metadata protect $key]} {
			if {$val eq ""} {
				set val [get_password "Enter a value for $key: "]
			}
			set displayVal "<hidden>"
		} else {
			if {$val eq ""} {
				set val [get_value "Enter a value for $key: "]
			}
			set displayVal $val
		}

		if {![$config metadata validate $key $val]} {
			puts stderr "warning: could not set option '$key' to value '$displayVal': not a valid value for that key"
			continue
		}

		if {[catch {$config set_option $key $val} result]} {
			puts stderr "warning: could not set option '$key' to value '$displayVal': $result"
			continue
		}

		if {$result ne ""}  {
			puts stderr "Set $key to $displayVal in [$result origin $key]"
		} else {
			puts stderr "$key is unchanged"
		}
	}

	if {[catch {$config write_config} result]} {
		puts stderr "could not write new config files: $result"
	}
}

#
# get_password - read a password with not showing it even though i'm not
#  too sure not showing it helps
#
proc get_password {prompt} {
	exec stty -echo echonl <@stdin
	try {
		puts -nonewline stdout $prompt
		flush stdout
		gets stdin line
		return $line
	} finally {
		exec stty echo -echonl <@stdin
	}
}

proc get_value {prompt} {
	puts -nonewline stdout $prompt
	flush stdout
	gets stdin line
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

proc show_piaware_config {{showProtected 0}} {
	global config
	load_config

	puts "# Current piaware settings:"
	foreach key [lsort [$config metadata all_settings]] {
		if {[$config exists $key]} {
			set displayKey $key
			set val [$config metadata format $key [$config get $key]]
			set origin "from [$config origin $key]"
		} elseif {[$config metadata default $key] ne ""} {
			set displayKey $key
			set val [$config metadata format $key [$config get $key]]
			set origin "using default value"
		} else {
			set displayKey "#$key"
			set val ""
			set origin "not set, no default"
		}

		if {[$config metadata protect $key] && !$showProtected} {
			set val "<hidden>"
		}

		puts stderr [format "%-30s %-30s # %s" $displayKey $val $origin]
	}
}

# vim: set ts=4 sw=4 sts=4 noet :
