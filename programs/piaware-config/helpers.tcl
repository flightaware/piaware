# -*- mode: tcl; tab-width: 4; indent-tabs-mode: t -*-
#
# fa_adept - config file manager and client manager
#
# Copyright (C) 2014 FlightAware LLC, All Rights Reserved
#

package require fa_piaware_config
package require tryfinallyshim

# speculatively try to load the extra FF config options
catch {package require fa_flightfeeder_config}

proc load_config {} {
	global config

	if {![info exists config]} {
		set config [::fa_piaware_config::new_combined_config #auto $::params(configfile)]
		set problems [$config read_config]
		foreach problem $problems {
			puts stderr "warning: $problem"
		}
	}
}

proc update_config_values {argv} {
	global config
	load_config

	set sentinel "!!!SENTINEL!!!"

	foreach {key val} [list {*}$argv $sentinel] {
		if {$key eq $sentinel} {
			continue
		}

		if {![$config metadata exists $key]} {
			puts stderr "warning: cannot set option '$key', it is not a known config option"
			continue
		}

		if {[$config metadata sdonly $key] && !([$config get image-type] eq "piaware")} {
			puts stderr "warning: cannot set option '$key', option only supported on PiAware SD card images"
			continue
		}

		if {[$config metadata protect $key]} {
			if {$val eq $sentinel} {
				set val [get_password "Enter a value for $key: "]
			}
			set displayVal "<hidden>"
		} else {
			if {$val eq $sentinel} {
				set val [get_value "Enter a value for $key: "]
			}
			set displayVal $val
		}

		if {$val ne "" && ![$config metadata validate $key $val]} {
			puts stderr "warning: could not set option '$key' to value '$displayVal': not a valid value for that key"
			continue
		}

		if {[catch {$config set_option $key $val} result]} {
			puts stderr "warning: could not set option '$key' to value '$displayVal': $result"
			continue
		}

		if {$result ne ""}  {
			if {$val eq ""} {
				puts stderr "Cleared setting for $key in [$result origin $key]"
			} else {
				puts stderr "Set $key to $displayVal in [$result origin $key]"
				if {[$config metadata network $key] && [$config get image-type] eq "piaware"} {
					puts stderr "Network configuration changes will take effect on reboot. Run \"piaware-restart-network\" to apply them immediately."
				}
			}
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

proc show_piaware_config {showAll keys} {
	global config
	load_config

	if {$keys eq ""} {
		set keys [lsort [$config metadata all_settings]]
		set verbose 1
	} else {
		set verbose 0
		set showAll 1
	}

	foreach key $keys {
		set val [$config get $key]
		set origin [$config origin $key]
		set defaultValue [$config metadata default $key]

		switch -- $origin {
			"" {
				if {!$showAll} {
					continue
				}

				set displayKey "#$key"
				set displayValue "<unset>"
				set displayOrigin "no value set and no default value"
			}

			"defaults" {
				if {!$showAll} {
					continue
				}

				set displayKey "#$key"
				set displayValue [::fa_piaware_config::ConfigFile::quote_value [$config metadata format $key $val]]
				set displayOrigin "using default value"
			}

			default {
				if {$val eq ""} {
					if {!$showAll} {
						continue
					}

					set displayKey "#$key"
					set displayValue "<unset>"
					set displayOrigin "value cleared at $origin"
				} else {
					set displayKey $key
					if {[$config metadata protect $key] && !$showAll} {
						set displayValue "<hidden>"
					} else {
						set displayValue [::fa_piaware_config::ConfigFile::quote_value [$config metadata format $key $val]]
					}
					set displayOrigin "value set at $origin"
				}
			}
		}

		if {$verbose} {
			puts stderr [format "%-30s %-30s # %s" $displayKey $displayValue $displayOrigin]
		} else {
			if {$val ne ""} {
				puts stdout [$config metadata format $key $val]
			}
		}
	}
}

# vim: set ts=4 sw=4 sts=4 noet :
