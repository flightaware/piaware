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
	# initially retry after this many seconds
	set ::faup1090ConnectRetryInterval 10
	set ::nfaupMessagesThisPeriod 0

	#
	set ::lastAdsbClock [clock seconds]
	set ::lastConnectAttempt 0

	set ::priorFaupMessagesReceived -1
	set_prior_messages_received 0

	# we didn't really see it but we have to start the time from somewhere
	# and if we initialize it to 0 that's pretty far in the past, i.e. 1970
	saw_adsb_producer_program
}

#
# schedule_fa_style_adsb_port_connect_attempt - schedule an attempt to connect
#  to the fa-style ADS-B port (FA dump1090-provided for FA-faup1090 provided),
#  canceling the prior one if one was already scheduled
#
# support "idle" as an argument to do "after idle" else a number of seconds
#
proc schedule_fa_style_adsb_port_connect_attempt {inSeconds} {
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

	set ::adsbPortConnectTimer [after $ms connect_fa_style_adsb_port]
	#logger "scheduled FA-style ADS-B port connect attempt $explain as timer ID $::adsbPortConnectTimer"
}

#
# connect_fa_style_adsb_port - setup a client socket that connects to faup1090
#  fa "baked" port 10001
#
proc connect_fa_style_adsb_port {} {
	set ::lastConnectAttempt [clock seconds]

	inspect_sockets_with_netstat

	if {![is_adsb_program_running]} {
		logger "no ADS-B data program is serving on port 30005, next check in 60s"
		schedule_fa_style_adsb_port_connect_attempt 60
		return
	}

	logger "ADS-B data program '$::netstatus(program_30005)' is listening on port 30005, so far so good"

	if {[info exists ::netstatus(status_10001)] && $::netstatus(status_10001)} {
		logger "i see $::netstatus(program_10001) serving on port 10001"
		set serverProgram $::netstatus(program_10001)
	} else {
		logger "i see nothing serving on port 10001, starting faup1090..."
		start_faup1090
		set serverProgram "faup1090"
	}

	logger "connecting to $serverProgram on port $::faup1090Port..."
    if {[catch {socket 127.0.0.1 $::faup1090Port} ::faup1090Socket] == 1} {
		if {[lindex $::errorCode 0] == "POSIX" && [lindex $::errorCode 1] == "ECONNREFUSED"} {
			logger "connection refused on $serverProgram port 10001, retrying in ${::faup1090ConnectRetryInterval}s..."
		} else {
			logger "error opening connection to $serverProgram : $::faup1090Socket, retrying in ${::faup1090ConnectRetryInterval}s..."
		}
		unset ::faup1090Socket
		schedule_fa_style_adsb_port_connect_attempt $::faup1090ConnectRetryInterval
		set ::faup1090ConnectRetryInterval 60
		return
    }

	fconfigure $::faup1090Socket -buffering line -translation binary -blocking 0
    fileevent $::faup1090Socket readable [list faup1090_data_available $::faup1090Socket]
    logger "$::argv0 is connected to $serverProgram on port $::faup1090Port"
	set ::connected1090 1
}

#
# close_faup1090_socket - cleanly close the faup1090 socket
#
proc close_faup1090_socket {{sock ""}} {
	if {$sock == ""} {
		if {![info exists ::faup1090Socket]} {
			logger "close_faup1090_socket called with no socket argument and no faup1090 global socket"
			return
		}
		set sock $::faup1090Socket
	}

	if {[catch {close $sock} catchResult]} {
		logger "got '$catchResult' closing client socket $ock continuing..."
	}

	unset -nocomplain ::faup1090Socket
	set ::connected1090 0
	set ::presumed1090 0
}

#
# close_faup1090_socket_and_reopen - pretty self-explanatory
#
proc close_faup1090_socket_and_reopen {{sock ""}} {
	close_faup1090_socket $sock

	if {[clock seconds] - $::lastConnectAttempt > 60} {
		schedule_fa_style_adsb_port_connect_attempt idle
		return
	}

	logger "will attempt to connect to faup1090 in 60s..."
	schedule_fa_style_adsb_port_connect_attempt 60
}

#
# faup1090_data_available - callback routine when data is available from the
#  socket to faup1090
#
proc faup1090_data_available {sock} {
	# if eof, cleanly close the faup1090 socket and reconnect...
    if {[eof $sock]} {
		logger "lost connection to faup1090, reconnecting..."
		close_faup1090_socket_and_reopen $sock
		return
    }

	# try to read, if that fails, disconnect and reconnect...
    if {[catch {set size [gets $sock line]} catchResult] == 1} {
		logger "faup1090_data_available: got '$catchResult' reading $::faup1090Socket"
		close_faup1090_socket_and_reopen $sock
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
		log_locally "piaware received a message from the ADS-B source!"
	}

    #puts "faup1090 data: $line"
	# if logged into flightaware adept, send the data
	send_if_logged_in $line
	set ::lastAdsbClock [clock seconds]
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
# setup_fa_style_adsb_client - client-side setup
#
proc setup_fa_style_adsb_client {} {
	set ::connected1090 0
	set ::presumed1090 0
	set ::nfaupMessagesReceived 0
	set ::nMessagesSent 0
    connect_fa_style_adsb_port
}

#
# stop_faup1090 - stop faup1090 if it is running
#
proc stop_faup1090 {} {
	if {![info exists ::faup1090Pid]} {
		logger "stop_faup1090: no need to stop faup1090, it's not running"
		return
	}

	logger "sending a hangup signal (SIGHUP) to faup1090 (process $::faup1090Pid) to shut it down..."

	if {[catch {kill HUP $::faup1090Pid} catchResult] == 1} {
		logger "sending signal to faup process $::faup1090Pid failed: $catchResult, continuing..."
		unset ::faup1090Pid
		return
	}

	set pid [is_faup1090_running]
	if {$pid != 0} {
		logger "stopping faup1090 (pid $pid)"
		kill HUP $pid
		sleep 3
	}
}

#
# start_faup1090 - start faup1090, killing it if it is already running
#
proc start_faup1090 {} {
	set ::faup1090Pid [exec /usr/bin/faup1090 &]
	logger "started faup1090 (process ID $::faup1090Pid)"
	sleep 3
}

# is_faup1090_running - return the pid of faup1090 if it is running, else 0
#
proc is_faup1090_running {} {
	reap_any_dead_children

	if {![info exists ::faup1090Pid]} {
		return 0
	}

	if {[is_pid_running $::faup1090Pid]} {
		return $::faup1090Pid
	}
	return 0
}

#
# adsb_messages_being_received_check - by faup1090_running_periodic_check
#  to see if we have received messages in the last few minutes
#
#  return 1 if it's up or enough time hasn't elapsed that we should do
#  something about it
#
#  return 0 if we've not received any messages for quite a while and we
#  attempted to restart (0 return indicates don't proceed with
#  other checks)
#
proc adsb_messages_being_received_check {} {
	set secondsSinceLast [expr {[clock seconds] - $::lastAdsbClock}]
	if {$secondsSinceLast < $::noMessageActionIntervalSeconds} {
		if {$secondsSinceLast > 300} {
			logger "seconds since last message or startup ($secondsSinceLast) less than threshold for action ($::noMessageActionIntervalSeconds), waiting..."
		}
		return 1
	}
	set nNewMessagesReceived [expr {$::::nfaupMessagesReceived - $::priorFaupMessagesReceived}]
	if {$nNewMessagesReceived == 0} {
		logger "no new messages received in $secondsSinceLast seconds, it might just be that there haven't been any aircraft nearby but I'm going to try to restart dump1090, possibly restart faup1090 and definitely reconnect, just in case..."
		attempt_dump1090_restart
		stop_faup1090_close_faup1090_socket_and_reopen
		return 0
	}

	set_prior_messages_received $::nfaupMessagesReceived
	return 1
}

#
# set_prior_messages_received - set the count of prior messages received and
#  when we set it
#
proc set_prior_messages_received {quantity} {
	if {$quantity != $::priorFaupMessagesReceived} {
		set ::priorFaupMessagesReceived $quantity
		set ::priorFaupClock [clock seconds]
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
#
# see if messages are being received, what's feeding if they are, make
# sure faup1090 is up if we're using it, start/restart if necessary
#
proc check_adsb_traffic {} {
	reap_any_dead_children

	# perform the messages-being-received check and don't go on if
	# it tells us not to
	if {![adsb_messages_being_received_check]} {
		return
	}

	#
	# if faup1090 is running, we're done
	#
	if {[is_faup1090_running]} {
		#logger "check_adsb_traffic: faup1090 is running"
		return
	}

	# see what's hooked up to what
	inspect_sockets_with_netstat

	# if nothing's there to feed us, we're done
	if {![is_adsb_program_running]} {
		if {[adsb_producer_force_start_check]} {
			return
		}
		logger "no ADS-B producer (dump1090, modesmixer, etc) appears to be running or is not listening for connections on port 30005, next check in 5m"
		return
	}

	# if something's there to feed us, we're done, but report what's hooked
	# up if we haven't received any ADS-B messages this period

	if {$::netstatus(status_10001)} {
		if {$::nfaupMessagesThisPeriod == 0} {
			# report what program is providing data on port 10001 but only
			# if there hasn't been recent traffic, just to keep the noise
			# down
			logger "$::netstatus(program_10001) is listening for connections on FA-style port 10001"
		}
		saw_adsb_producer_program
		return
	}

	# nothing's feeding us, try to start faup1090
	logger "starting faup1090 to translate 30005 beast to 10001 flightaware"
	start_faup1090
}

#
# saw_adsb_producer_program - mark that we saw there is a producer program
#  running, specifically the current time
#
proc saw_adsb_producer_program {} {
	set ::sawAdsbProducerProgramAtClock [clock seconds]
}

#
# adsb_producer_force_start_check - if enough time has elapsed then try
#  to start the ADS-B producer program (dump1090 probably) and return 1,
#  else return 0
#
proc adsb_producer_force_start_check {} {
	set secondsSinceSawProgram [expr {[clock seconds] - $::sawAdsbProducerProgramAtClock}]
	if {$secondsSinceSawProgram >= $::adsbNoProducerStartDelaySeconds} {
		logger "no ADS-B producer program seen for $secondsSinceSawProgram seconds, trying to start it..."
		attempt_dump1090_restart start
		return 1
	} else {
		logger "no ADS-B producer program seen for $secondsSinceSawProgram seconds (or since piaware started), will attempt to start it next check after $::adsbNoProducerStartDelaySeconds seconds..."
	}

	return 0
}

#
# stop_faup1090_close_faup1090_socket_and_reopen - can you guess?
#
#  stop faup1090, close the faup1090 socket, and then reopen the socket
#
proc stop_faup1090_close_faup1090_socket_and_reopen {} {
	stop_faup1090

	close_faup1090_socket_and_reopen
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
	if {![info exists ::netstatus(program_10001)]} {
		inspect_sockets_with_netstat
	}

	if {[info exists ::netstatus(program_10001)]} {
		if {$::netstatus(program_30005) == $::netstatus(program_10001)} {
			set who "$::netstatus(program_30005)"
		} else {
			set who "$::netstatus(program_30005) via $::netstatus(program_10001)"
		}
	} else {
		set who "(not currently connected to an adsb source)"
	}

	set periodString ""
	if {[info exists ::faupMessagesPeriodStartClock]} {
		set minutesThisPeriod [expr {round(([clock seconds] - $::faupMessagesPeriodStartClock) / 60.0)}]
		set periodString " ($::nfaupMessagesThisPeriod in last ${minutesThisPeriod}m)"
	}
	set ::faupMessagesPeriodStartClock [clock seconds]
	set ::nfaupMessagesThisPeriod 0

	logger "$::nfaupMessagesReceived msgs recv'd from $who$periodString; $::nMessagesSent msgs sent to FlightAware"

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
		logger "Receiver location changed, restarting dump1090"
		attempt_dump1090_restart
	}
}

# vim: set ts=4 sw=4 sts=4 noet :
