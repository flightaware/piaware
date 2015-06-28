# -*- mode: tcl; tab-width: 4; indent-tabs-mode: t -*-
#
# piaware - aviation data exchange protocol ADS-B client
#
# Copyright (C) 2014 FlightAware LLC, All Rights Reserved
#

#
# setup_faup1090_vars - setup vars but don't start faup1090
#
proc setup_faup1090_vars {} {
	# total message from faup1090
	set ::nfaupMessagesReceived 0
	# number of message from faup1090 since we last logged about is
	set ::nfaupMessagesThisPeriod 0
	# total messages sent to adept
	set ::nMessagesSent 0
	# last time we considered (re)starting faup1090
	set ::lastConnectAttemptClock 0
	# time of the last message from faup1090
	set ::lastFaupMessageClock [clock seconds]
	# time we were last connected to port 30005
	set ::lastAdsbConnectedClock [clock seconds]
	# what the producer is called
	set ::adsbDataProgram "the ADS-B data program"
}

#
# schedule_adsb_connect_attempt - schedule an attempt to connect
#  to the ADS-B port canceling the prior one if one was already scheduled
#
# support "idle" as an argument to do "after idle" else a number of seconds
#
proc schedule_adsb_connect_attempt {inSeconds} {
	if {[info exists ::adsbPortConnectTimer]} {
		after cancel $::adsbPortConnectTimer
		#logger "canceled prior adsb port connect attempt timer $::adsbPortConnectTimer"
	}

	if {$inSeconds == "idle"} {
		set ms "idle"
		set explain "when idle"
	} elseif {[string is integer -strict $inSeconds]} {
		set ms [expr {$inSeconds * 1000}]
		set explain "in $inSeconds seconds"
	} else {
		error "argument must be an integer or 'idle'"
	}

	set ::adsbPortConnectTimer [after $ms connect_adsb_via_faup1090]
	#logger "scheduled FA-style ADS-B port connect attempt $explain as timer ID $::adsbPortConnectTimer"
}

#
# connect_adsb_via_faup1090 - connect to port 30005 using faup1090 as an intermediary;
# if it fails, schedule another attempt later
#
proc connect_adsb_via_faup1090 {} {
	unset -nocomplain ::adsbPortConnectTimer

	# just in case..
	stop_faup1090

	set ::lastConnectAttemptClock [clock seconds]
	inspect_sockets_with_netstat

	if {![is_adsb_program_running]} {

		# still no listener, consider restarting
		set secondsSinceListenerSeen [expr {[clock seconds] - $::lastAdsbConnectedClock}]
		if {$secondsSinceListenerSeen >= $::adsbNoProducerStartDelaySeconds} {
			logger "no ADS-B data program seen listening on port 30005 for $secondsSinceListenerSeen seconds, trying to start it..."
			attempt_dump1090_restart start
			# pretend we saw it to reduce restarts if it's failing
			set ::lastAdsbConnectedClock [clock seconds]
			schedule_adsb_connect_attempt 10
		} else {
			logger "no ADS-B data program seen listening on port 30005 for $secondsSinceListenerSeen seconds, next check in 60s"
			schedule_adsb_connect_attempt 60
		}

		return
	}

	set ::adsbDataProgram $::netstatus(program_30005)
	set ::lastAdsbConnectedClock [clock seconds]
	logger "ADS-B data program '$::adsbDataProgram' is listening on port 30005, so far so good"
	set args [auto_execok faup1090]
	if {$args eq ""} {
		logger "No faup1090 in PATH, will try again in 10 minutes"
		schedule_adsb_connect_attempt 600
		return
	}

	lappend args "--net-bo-ipaddr" "localhost" "--net-bo-port" "30005"
	if {$::receiverLat ne "" && $::receiverLon ne ""} {
		lappend args "--lat" [format "%.3f" $::receiverLat] "--lon" [format "%.3f" $::receiverLon]
	}

	logger "Starting faup1090: $args"
	if {[catch {set ::faupPipe [open |$args]} catchResult] == 1} {
		logger "got '$catchResult' starting faup1090, will try again in 60s"
		schedule_adsb_connect_attempt 60
		return
	}

	logger "Started faup1090 (pid [pid $::faupPipe]) to connect to $::adsbDataProgram"
	fconfigure $::faupPipe -buffering line -blocking 0 -translation binary
	fileevent $::faupPipe readable faup1090_data_available

	# pretend we saw a message so we don't repeatedly restart
	set ::lastFaupMessageClock [clock seconds]
}

#
# stop_faup1090 - clean up faup1090 pipe, don't schedule a reconnect
#
proc stop_faup1090 {} {
	if {![info exists ::faupPipe]} {
		# nothing to do.
		return
	}

	# record when we were last connected
	set ::lastAdsbConnectedClock [clock seconds]
	catch {kill HUP [pid $::faupPipe]}
	catch {close $::faupPipe}
	unset ::faupPipe
}

#
# restart_faup1090 - pretty self-explanatory
#
proc restart_faup1090 {{delay 30}} {
	stop_faup1090

	if {$delay eq "now" || [clock seconds] - $::lastConnectAttemptClock > $delay} {
		logger "reconnecting to $::adsbDataProgram"
		schedule_adsb_connect_attempt idle
		return
	}

	logger "will reconnect to $::adsbDataProgram in $delay seconds"
	schedule_adsb_connect_attempt $delay
}

#
# faup1090_data_available - callback routine when data is available from the
#  socket to faup1090
#
proc faup1090_data_available {} {
	# if eof, cleanly close the faup1090 socket and reconnect...
    if {[eof $::faupPipe]} {
		logger "lost connection to $::adsbDataProgram via faup1090"
		restart_faup1090
		return
    }

	# try to read, if that fails, disconnect and reconnect...
    if {[catch {set size [gets $::faupPipe line]} catchResult] == 1} {
		logger "got '$catchResult' reading from faup1090"
		restart_faup1090
		return
    }

	# sometimes you can get a notice of data available and not get any data.
	# it happens.  nothing to do? return.
    if {$size < 0} {
		return
    }

	incr ::nfaupMessagesReceived
	incr ::nfaupMessagesThisPeriod
	if {$::nfaupMessagesReceived == 1} {
		log_locally "piaware received a message from $::adsbDataProgram!"
	}

    #puts "faup1090 data: $line"
	# if logged into flightaware adept, send the data
	send_if_logged_in $line
	set ::lastFaupMessageClock [clock seconds]
}

#
# send_if_logged_in - send an adept message but only if logged in
#
proc send_if_logged_in {line} {
    if {![adept is_logged_in]} {
		return
    }

	if {[catch {send_adsb_line $line} catchResult] == 1} {
		log_locally "error uploading ADS-B message: $catchResult"
	}
}

#
# send_adsb_line - send an ADS-B message to the adept server
#
proc send_adsb_line {line} {
	array set row [split $line "\t"]
	adept send_array row

	incr ::nMessagesSent
	if {$::nMessagesSent == 7} {
		log_locally "piaware has successfully sent several msgs to FlightAware!"
	}
}

#
# periodically_check_adsb_traffic - periodically perform checks to see if
# we are receiving data and possibly start/restart faup1090
#
# also issue a traffic report
#
proc periodically_check_adsb_traffic {} {
	after [expr {$::adsbTrafficCheckIntervalSeconds * 1000}] periodically_check_adsb_traffic

	check_adsb_traffic

	after 30000 traffic_report
}

#
# check_adsb_traffic - see if ADS-B messages are being received.
# restart stuff as necessary
#
proc check_adsb_traffic {} {
	reap_any_dead_children

	set secondsSinceLastMessage [expr {[clock seconds] - $::lastFaupMessageClock}]

	if {[info exists ::faupPipe]} {
		# faup1090 is running, check we are hearing some messages
		if {$secondsSinceLastMessage >= $::noMessageActionIntervalSeconds} {
			# force a restart
			logger "no new messages received in $secondsSinceLastMessage seconds, it might just be that there haven't been any aircraft nearby but I'm going to try to restart dump1090, just in case..."
			stop_faup1090
			attempt_dump1090_restart restart
			schedule_adsb_connect_attempt 10
		}
	} else {
		if {![info exists ::adsbPortConnectTimer]} {
			# faup1090 not running and no timer set! Bad doggie.
			logger "faup1090 not running, but no restart timer set! Fixing it.."
			schedule_adsb_connect_attempt 5
		}
	}
}

proc has_invoke_rcd {} {
	if {![info exists ::invoke_rcd_path]} {
		set ::invoke_rcd_path [auto_execok invoke-rc.d]
	}

	if {$::invoke_rcd_path ne ""} {
		return 1
	} else {
		return 0
	}
}

proc can_invoke_service_action {service action} {
	# try to decide if we should invoke the given service/action
	if {![has_invoke_rcd]} {
		# no invoke-rc.d, just see if we can run the script
		if {[auto_execok "/etc/init.d/$service"] eq ""} {
			return 0
		} else {
			return 1
		}
	}

	set status [system invoke-rc.d --query $service $action]
	switch $status {
		104 -
		105 -
		106 {
			return 1
		}

		default {
			return 0
		}
	}
}

proc invoke_service_action {service action} {
	if {![has_invoke_rcd]} {
		# no invoke-rc.d, just run the script
		set command [list /etc/init.d/$service $action]
	} else {
		# use invoke-rc.d
		set command [list invoke-rc.d $service $action]
	}

	logger "attempting to $action $service using '$command'..."
	return [system $command]
}


#
# attempt_dump1090_restart - restart dump1090 if we can figure out how to
#
proc attempt_dump1090_restart {{action restart}} {
	set scripts [glob -nocomplain -directory /etc/init.d -tails -types {f r x} *dump1090*]

	foreach script $scripts {
		switch -glob $script {
			*.dpkg*	-
			*.rpm* -
			*.ba* -
			*.old -
			*.org -
			*.orig -
			*.save -
			*.swp -
			*.core -
			*~ {
				# Skip this
			}

			default {
				# check invoke-rc.d etc
				if {[can_invoke_service_action $script $action]} {
					lappend acceptableScripts $script
				}
			}
		}
	}

	if { [info exists acceptableScripts] } {
		set service [lindex $acceptableScripts 0]
		if { [llength $acceptableScripts] > 1 } {
			logger "warning, more than one enabled dump1090 script in /etc/init.d, proceding with '$service'..."
		}

		set exitStatus [invoke_service_action $service $action]

		if {$exitStatus == 0} {
			logger "dump1090 $action appears to have been successful"
		} else {
			logger "got exit status $exitStatus while trying to $action dump1090"
		}
	} else { 
		logger "can't $action dump1090, no enabled dump1090 script in /etc/init.d"
	}
}

#
# traffic_report - log a traffic report of messages received from the adsb
#   program and messages sent to FlightAware
#
proc traffic_report {} {
	set periodString ""
	if {[info exists ::faupMessagesPeriodStartClock]} {
		set minutesThisPeriod [expr {round(([clock seconds] - $::faupMessagesPeriodStartClock) / 60.0)}]
		set periodString " ($::nfaupMessagesThisPeriod in last ${minutesThisPeriod}m)"
	}
	set ::faupMessagesPeriodStartClock [clock seconds]
	set ::nfaupMessagesThisPeriod 0

	logger "$::nfaupMessagesReceived msgs recv'd from $::adsbDataProgram$periodString; $::nMessagesSent msgs sent to FlightAware"

}

# when adept tells us the receiver location,
# record it and maybe restart dump1090 / faup1090
proc update_location {lat lon} {
	if {$lat eq $::receiverLat && $lon eq $::receiverLon} {
		# unchanged
		return
	}

	# nb: we always save the new location, but the globals
	# reflect what dump1090 was last started with and
	# are only updated if we decide to restart dump1090.
	# This handles the case where the location walks in
	# small steps.

	save_location_info $lat $lon

	if {$::receiverLat ne "" && $::receiverLon ne ""} {
		if {abs($::receiverLat - $lat) < 0.1 && abs($::receiverLon - $lon) < 0.1} {
			# Didn't change enough to care about restarting
			return
		}
	}

	# changed nontrivially; restart faup1090 to use the new values
	set ::receiverLat $lat
	set ::receiverLon $lon
	if {[info exists ::faupPipe]} {
		logger "Receiver location changed, restarting faup1090"
		restart_faup1090 now
	}
}

# vim: set ts=4 sw=4 sts=4 noet :
