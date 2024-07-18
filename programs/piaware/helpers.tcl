# -*- mode: tcl; tab-width: 4; indent-tabs-mode: t -*-
#
# fa_adept_client - open data exchange protocol server
#
# Copyright (C) 2014 FlightAware LLC, All Rights Reserved
#

package require tls
package require fa_piaware_config
package require fa_services
package require fa_sudo
package require fa_sysinfo

# speculatively try to load the extra FF config options
catch {package require fa_flightfeeder_config}

#
# logger - log a message
#
proc logger {text} {
	#::bsd::syslog log info $text
	log_locally $text
	if {[llength [info commands "adept"]] < 1} {
	     # adept client has not yet loaded
	     return 0
	}
	adept send_log_message $text
}

#
# debug - log a debug message locally if enabled
#
proc debug {text} {
	if {$::params(debug)} {
		log_locally $text
	}
}

#
# log_locally - log a message locally
#
proc log_locally {text} {
	#::bsd::syslog log info $text
	if {!$::params(plainlog)} {
		puts stderr "[clock format [clock seconds] -format "%Y-%m-%d %H:%M:%SZ" -gmt 1] $text"
	} else {
		puts stderr $text
	}
}

proc log_bgerror {message _options} {
	array set options $_options
	logger "Caught background error: $options(-errorinfo)"
}

#
# greetings - issue a startup message
#
proc greetings {} {
	log_locally "****************************************************"
	log_locally "piaware version $::piawareVersionFull is running, process ID [pid]"
	log_locally "your system info is: [::fa_sudo::exec_as /bin/uname --all]"
}

#
# setup_adept_client - adept client-side setup
#
proc setup_adept_client {} {
    ::fa_adept::AdeptClient adept \
		-mac [get_mac_address] \
		-showTraffic $::params(showtraffic) \
		-logCommand ::log_locally \
		-loginCommand ::gather_login_info \
		-loginResultCommand ::handle_login_result \
		-updateLocationCommand ::adept_location_changed \
		-mlatCommand ::forward_to_mlat_client \
		-updateCommand ::handle_update_request \
		-faupCommand ::handle_faup_command

	if {$::params(serverhosts) ne ""} {
		adept configure -hosts $::params(serverhosts)
	} else {
		adept configure -hosts [piawareConfig get adept-serverhosts]
	}

	if {$::params(serverport) ne ""} {
		adept configure -port $::params(serverport)
	} else {
		adept configure -port [piawareConfig get adept-serverport]
	}
}

#
# load_config - set up our config files
#
proc setup_config {} {
	::fa_piaware_config::new_combined_config piawareConfig $::params(configfile)

	lassign [load_location_info] ::receiverLat ::receiverLon
	reread_piaware_config
}

proc reread_piaware_config {} {
	set problems [piawareConfig read_config]
	foreach problem $problems {
		log_locally "warning: $problem"
	}
}

proc create_legacy_logfile {where} {
	# create a dummy logfile in /tmp/piaware.out
	# so that users who expect the old behavior
	# know where to look for the new logfile
	if {![file exists "/tmp/piaware.out"]} {
		set f [open "/tmp/piaware.out" "w"]
		try {
			puts $f "PiAware now writes logging information $where"
			puts $f "Please see that file for PiAware logs."
		} finally {
			close $f
		}
	}
}

# reopen_logfile - open a logfile (for append) and redirect stdout and stderr there,
# closing the old stdout/stderr
proc reopen_logfile {} {
	if {$::params(debug)} {
		# not logging to a file
		return
	}

	if {$::params(plainlog)} {
		# we assume this is going to syslog
		catch {create_legacy_logfile "via syslog to /var/log/piaware.log"}
		# nothing more to do
		return
	}

	catch {create_legacy_logfile "to [file normalize $::params(logfile)]"}
	if {[catch {set fp [open $::params(logfile) a]} result]} {
		logger "failed to reopen $::params(logfile): $result"
		return
	}

	fconfigure $fp -buffering line
	dup $fp stdout
	dup $fp stderr
	close $fp
}

proc create_named_pidfile {path} {
	log_locally "creating pidfile $path"

	set f [open $path "a+"]
	set ok 0
	try {
		if {![flock -write -nowait $f]} {
			error "$path is locked by another process"
		}

		chan seek $f 0 start
		chan truncate $f 0
		puts $f [pid]
		flush $f

		set ::pidfiles($path) $f
		set ok 1
	} finally {
		if {!$ok} {
			catch {close $f}
		}
	}
}

proc unlock_named_pidfile {path} {
	if {![info exists ::pidfiles($path)]} {
		return
	}

	log_locally "unlocking pidfile $path"

	# closing releases our lock
	close $::pidfiles($path)
	unset ::pidfiles($path)
}

proc cleanup_named_pidfile {path} {
	if {![info exists ::pidfiles($path)]} {
		return
	}

	log_locally "removing pidfile $path"

	# delete before unlocking to avoid a race with a
	# concurrent process
	catch {file delete $path}

	# closing releases our lock
	close $::pidfiles($path)
	unset ::pidfiles($path)
}


#
# create_pidfile - create a pidfile for this process if possible if so
#   configured
#
proc create_pidfile {} {
	set file $::params(p)
	if {$file == ""}  {
		return
	}

	if {[catch {create_named_pidfile $file} result]} {
		log_locally "unable to create pidfile $file ($result); is another piaware instance running?"
		exit 2
	}
}

#
# unlock_pidfile - release any lock on the pidfile,
# but otherwise leave the file alone
proc unlock_pidfile {} {
	set file $::params(p)
	if {$file == ""}  {
		return
	}

	unlock_named_pidfile $file
}

#
# remove_pidfile - remove the pidfile if it exists
#
proc remove_pidfile {} {
	set file $::params(p)
	if {$file == ""}  {
		return
	}

	cleanup_named_pidfile $file
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
	::fa_services::invoke_service_action piaware restart

	# sleep apparently restarts on signals, we want to process them,
	# so use after/vwait so the event loop runs.
	after 10000 [list set ::die 1]
	vwait ::die

	logger "piaware failed to die, pid [pid], that's me, i'm gonna kill myself"
	exit 0
}


#
# setup_signals - arrange for common signals to shutdown the program
#
proc setup_signals {} {
	signal trap HUP reload_config
	signal trap USR1 reopen_logfile
	signal trap TERM "shutdown %S"
	signal trap INT "shutdown %S"
}

#
# shutdown - shutdown signal handler
#
proc shutdown {{reason ""}} {
	logger "$::argv0 (process [pid]) is shutting down because it received a shutdown signal ($reason) from the system..."
	cleanup_and_exit
}

#
# cleanup_and_exit - stop faup1090 if it is running and remove the pidfile if
#  we created one
#
proc cleanup_and_exit {} {
	stop_faup1090
	stop_faup978
	disable_mlat
	remove_pidfile
	logger "$::argv0 (process [pid]) is exiting..."
	exit 0
}

#
# load lat/lon info from /var/lib if available
#
proc load_location_info {} {
	if {$::params(cachedir) eq ""} {
		return [list "" ""]
	}

	if {[catch {set ll [try_load_location_info]}] == 1} {
		return [list "" ""]
	}

	return $ll
}

proc try_load_location_info {} {
	set fp [open "$::params(cachedir)/location" r]
	set data [read $fp]
	close $fp

	lassign [split $data "\n"] lat lon
	if {![string is double $lat] || ![string is double $lon]} {
		error "lat/lon missing or not numeric"
	}

	return [list $lat $lon]
}

# save location info
proc save_location_info {lat lon} {
	if {$::params(cachedir) eq ""} {
		return 0
	}

	if {[catch {try_save_location_info $lat $lon} catchResult] == 1} {
		log_locally "got '$catchResult' trying to update location files"
		return 0
	}

	return 1
}

proc create_cache_dir {} {
	# mkdir is a no-op if the dir is already there (no error)
	if {[catch {file mkdir $::params(cachedir)}]} {
		return 0
	}

	return 1
}

proc try_save_location_info {lat lon} {
	create_cache_dir

	if {$lat eq "" || $lon eq ""} {
		file delete -- $::params(cachedir)/location
		file delete -- $::params(cachedir)/location.env
		return
	}

	set fp [open "$::params(cachedir)/location.new" w]
	puts $fp $lat
	puts $fp $lon
	close $fp
	file rename -force -- "$::params(cachedir)/location.new" "$::params(cachedir)/location"

	set fp [open "$::params(cachedir)/location.env.new" w]
	puts $fp "PIAWARE_LAT=\"$lat\""
	puts $fp "PIAWARE_LON=\"$lon\""
	puts $fp "PIAWARE_DUMP1090_LOCATION_OPTIONS=\"--lat $lat --lon $lon\""
	close $fp
	file rename -force -- "$::params(cachedir)/location.env.new" "$::params(cachedir)/location.env"
}


#
# get_mac_address - return mac address regardless if empty or valid
#
proc get_mac_address {} {
	return [::fa_sysinfo::mac_address]
}

#
# run the given command and log any output to our logfile
# return 1 if it ran OK, 0 if there was a problem
#
proc run_command_as_root_log_output {args} {
    logger "*** running command '$args' and logging output"
	if {[catch {set fp [::fa_sudo::popen_as -root -stdin "</dev/null" -stdout stdoutPipe -stderr stderrPipe -- {*}$args]} result]} {
		logger "*** error attempting to start command: $result"
		return 0
	}

	if {$result == 0} {
		logger "*** sudo refused to start command"
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
# read from the given channel (which should be a child process stderr)
# and log the output via our logger
#
proc log_subprocess_output {name channel {closeScript ""}} {
	fconfigure $channel -buffering line -blocking 0
	fileevent $channel readable [list subprocess_logger $name $channel $closeScript]
}

proc subprocess_logger {name channel closeScript} {
	while 1 {
		if {[catch {set size [gets $channel line]}] == 1} {
			catch {close $channel}
			if {$closeScript ne ""} {
				{*}$closeScript
			}
			return
		}

		if {$size < 0} {
			break
		}

		if {$line ne ""} {
			logger "$name: $line"
		}
	}

	if {[eof $channel]} {
		catch {close $channel}
		if {$closeScript ne ""} {
			{*}$closeScript
		}
	}
}

# wait for a child to die with a timeout
proc timed_waitpid {timeout childpid} {
	set deadline [expr {[clock milliseconds] + $timeout}]
	while {[clock milliseconds] < $deadline} {
		if {[catch {wait -nohang $childpid} result options]} {
			lassign $::errorCode type subtype
			if {$type eq "POSIX" && $subtype eq "ECHILD"} {
				# child went missing
				return "$childpid EXIT unknown"
			}

			# reraise error
			return -options $options $result
		}

		if {$result ne ""} {
			# child status available
			return $result
		}

		# still waiting
		sleep 1
	}
}

# called on SIGUSR1
proc reload_config {} {
	logger "Reloading configuration and reconnecting."

	# load new config values
	reread_piaware_config

	# re-init derived values
	::fa_sudo::clear_sudo_cache
	setup_faup1090_vars

	# shut down existing stuff and reconnect
	reopen_logfile
	disable_mlat
	adept reconnect
	restart_faup1090 now
	restart_faup978 now
	stop_pirehose
	start_pirehose
}

# vim: set ts=4 sw=4 sts=4 noet :
