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
		puts stderr "[clock format [clock seconds] -format "%D %T" -gmt 1] $text"
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
		-mac [get_mac_address_or_quit] \
		-showTraffic $::params(showtraffic) \
		-logCommand ::log_locally \
		-loginCommand ::gather_login_info \
		-updateLocationCommand ::adept_location_changed \
		-mlatCommand ::forward_to_mlat_client \
		-updateCommand ::handle_update_request

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
	::fa_piaware_config::new_combined_config piawareConfig
	lassign [load_location_info] ::receiverLat ::receiverLon
	reread_piaware_config
}

proc reread_piaware_config {} {
	set problems [piawareConfig read_config]
	foreach problem $problems {
		log_locally "warning: $problem"
	}
}

# reopen_logfile - open a logfile (for append) and redirect stdout and stderr there,
# closing the old stdout/stderr
proc reopen_logfile {} {
	if {$::params(debug) || $::params(plainlog)} {
		# not logging to a file
		return
	}

	if {[catch {set fp [open $::params(logfile) a]} result]} {
		logger "failed to reopen $::params(logfile): $result"
		return
	}

	fconfigure $fp -buffering line
	dup $fp stdout
	dup $fp stderr
	close $fp
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

	log_locally "creating pidfile $file"

	# a+ so we have write access but don't fail on missing files and don't clobber existing data
	set ::pidfile [open $file "a+"]
	if {![flock -write -nowait $::pidfile]} {
		close $::pidfile
		unset ::pidfile
		log_locally "unable to lock pidfile $file; is another piaware instance running?"
		exit 2
	}
	chan seek $::pidfile 0 start
	chan truncate $::pidfile 0
	puts $::pidfile [pid]
	flush $::pidfile
	set ::pidfileIsMine 1

	# keep the pidfile open so we maintain the lock
}

#
# unlock_pidfile - release any lock on the pidfile,
# but otherwise leave the file alone
proc unlock_pidfile {} {
	if {![info exists ::pidfile]} {
		return
	}

	# closing releases our lock
	close $::pidfile
	unset ::pidfile

	# no longer safe to delete the pidfile
	# as someone else may overwrite it
	unset -nocomplain ::pidfileIsMine
}

#
# remove_pidfile - remove the pidfile if it exists
#
proc remove_pidfile {} {
	if {![info exists ::pidfileIsMine]} {
		return
	}

	# delete before unlocking to avoid a race with a concurrently starting
	# piaware
	log_locally "removing pidfile $::params(p)"
	if {[catch {file delete $::params(p)} catchResult] == 1} {
		log_locally "failed to remove pidfile: $catchResult, continuing..."
	}

	unset ::pidfileIsMine
	unlock_pidfile
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
	disable_mlat
	remove_pidfile
	logger "$::argv0 (process [pid]) is exiting..."
	exit 0
}

#
# load lat/lon info from /var/lib if available
#
proc load_location_info {} {
	if {[catch {set ll [try_load_location_info]}] == 1} {
		return [list "" ""]
	}

	return $ll
}

proc try_load_location_info {} {
	set fp [open $::locationFile r]
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
	if {[catch {try_save_location_info $lat $lon} catchResult] == 1} {
		log_locally "got '$catchResult' trying to update $::locationFile"
	}
}

proc try_save_location_info {lat lon} {
	set dir [file dirname $::locationFile]
	if {![file exists $dir]} {
		file mkdir $dir
	}

	set fp [open $::locationFile w]
	puts $fp $lat
	puts $fp $lon
	close $fp

	set fp [open $::locationFileEnv w]
	puts $fp "PIAWARE_LAT=\"$lat\""
	puts $fp "PIAWARE_LON=\"$lon\""
	puts $fp "PIAWARE_DUMP1090_LOCATION_OPTIONS=\"--lat $lat --lon $lon\""
	close $fp
}


#
# get_mac_address_or_quit - return the mac address of eth0 or if unable
#  to, emit a message to stderr and exit
#
proc get_mac_address_or_quit {} {
	set mac [::fa_sysinfo::mac_address]
	if {$mac == ""} {
		puts stderr "software failed to determine MAC address of the device.  cannot proceed without it."
		exit 6
	}
	return $mac
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
		if {![catch {wait -nohang $childpid} result options]} {
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

# periodically try to reap a particular background process
proc reap_child_later {childpid} {
	after 5000 [list try_to_reap_child $childpid]
}

proc try_to_reap_child {childpid} {
	if {[catch {wait -nohang $childpid} result]} {
		# I guess we missed it.
		logger "child pid $childpid exited with unknown status"
		return
	}

	if {$result eq ""} {
		# I'm not dead!
		after 5000 [list try_to_reap_child $childpid]
		return
	}

	# died
	lassign $result deadpid status code
	switch $status {
		EXIT {
			if {$code != 0} {
				logger "child pid $deadpid exited with status $code"
			}
		}

		SIG {
			logger "child pid $deadpid killed by signal $code"
		}

		default {
			logger "child pid $deadpid exited with unexpected status $status $code"
		}
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
}

# vim: set ts=4 sw=4 sts=4 noet :
