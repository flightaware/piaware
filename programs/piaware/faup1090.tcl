#
# piaware - aviation data exchange protocol ADS-B client
#
# Copyright (C) 2014 FlightAware LLC, All Rights Reserved
#

# initially retry after this long
set ::faup1090ConnectRetryInterval 10

#
set ::lastAdsbClock 0
set ::lastConnectAttempt 0
#
# connect_fa_style_adsb_port - setup a client socket that connects to faup1090
#  fa "baked" port 10001
#
proc connect_fa_style_adsb_port {} {
	set ::lastConnectAttempt [clock seconds]

	inspect_sockets_with_netstat

	if {![is_adsb_program_running]} {
		logger "no ADS-B data program is serving on port 30005, next check in 60s"
		after 60000 connect_fa_style_adsb_port
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
		after [expr {$::faup1090ConnectRetryInterval * 1000}] connect_fa_style_adsb_port
		set ::faup1090ConnectRetryInterval 60
		return
    }

	fconfigure $::faup1090Socket -buffering line -translation binary -blocking 0
    fileevent $::faup1090Socket readable faup1090_data_available
    logger "$::argv0 is connected to $serverProgram on port $::faup1090Port"
	set ::connected1090 1
}

#
# close_faup1090_socket - cleanly close the faup1090 socket
#
proc close_faup1090_socket {} {
    if {[info exists ::faup1090Socket]} {
		if {[catch {close $::faup1090Socket} catchResult]} {
			logger "got '$catchResult' closing client socket $::faup1090Socket, continuing"
		}

		unset ::faup1090Socket
		set ::connected1090 0
		set ::presumed1090 0
    }
}

#
# close_faup1090_socket_and_reopen - pretty self-explanatory
#
proc close_faup1090_socket_and_reopen {} {
	close_faup1090_socket

	if {[clock seconds] - $::lastConnectAttempt > 60} {
		after idle connect_fa_style_adsb_port
		return
	}

	logger "close_faup1090_socket_and_reopen: connecting in 60s..."
	after 60000 connect_fa_style_adsb_port
}

#
# faup1090_data_available - callback routine when data is available from the
#  socket to faup1090
#
proc faup1090_data_available {} {
	# if eof, cleanly close the faup1090 socket
    if {[eof $::faup1090Socket]} {
		close_faup1090_socket_and_reopen
		return
    }

    if {[catch {set size [gets $::faup1090Socket line]} catchResult] == 1} {
		logger "faup1090_data_available: got '$catchResult' reading $::faup1090Socket"
		close_faup1090_socket_and_reopen
		return
    }

	# sometimes you can get a notice of data available and not get any data.
	# it happens.  nothing to do? return.
    if {$size < 0} {
		return
    }

	incr ::nfaupMessagesReceived
	if {$::nfaupMessagesReceived == 1} {
		logger "piaware received a message from the ADS-B source!"
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
    if {[adept is_logged_in]} {
		send_line $line
    }
}

#
# send_line - send a line to the adept server
#
proc send_line {line} {
	adept send $line
	incr ::nMessagesSent
	if {$::nMessagesSent == 7} {
		logger "piaware has successfully sent several msgs to FlightAware!"
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

	if {[catch {kill HUP $::faup1090Pid} catchResult] == 1} {
		logger "kill HUP on faup1090 pid $::faup1090Pid failed: $catchResult, continuing..."
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
	logger "start_faup1090: started faup1090 (pid $::faup1090Pid)"
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
# faup1090_messages_being_received_check - by faup1090_running_periodic_check
#  to see if we have received messages in the last few minutes
#
proc faup1090_messages_being_received_check {} {
	if {!$::connected1090} {
		# we are saying keep going, not that it is really ok
		return 1
	}

	if {[info exists ::priorFaupMessagesReceived]} {
		set secondsSinceLast [expr {[clock seconds] - $::priorFaupClock}]
		if {$secondsSinceLast < 3600} {
			return 1
		}
		set nNewMessagesReceived [expr {$::::nfaupMessagesReceived - $::priorFaupMessagesReceived}]
		if {$nNewMessagesReceived == 0} {
			logger "no new messages received in $secondsSinceLast seconds, it might just be that there haven't been any aircraft nearby but I'm going to possibly restart faup1090 and definitely reconnect, just in case there's a problem with the current connection..."
			stop_faup1090_close_faup1090_socket_and_reopen
			return 0
		}
	}
	set ::priorFaupMessagesReceived $::nfaupMessagesReceived
	set ::priorFaupClock [clock seconds]
	return 1
}

#
# periodically_check_adsb_traffic - periodically check to see if faup1090 is
#  running and if it is not, start it up again
#
proc periodically_check_adsb_traffic {} {
	after 300000 periodically_check_adsb_traffic

	reap_any_dead_children

	if {![faup1090_messages_being_received_check]} {
		return
	}

	if {[is_faup1090_running]} {
		#logger "periodically_check_adsb_traffic: faup1090 is running"
		return
	}

	inspect_sockets_with_netstat

	if {![is_adsb_program_running]} {
		logger "periodically_check_adsb_traffic: no ads-b producer appears to be listening for connections on port 30005, next check in 5m"
		return
	}

	if {$::netstatus(status_10001)} {
		logger "periodically_check_adsb_traffic: $::netstatus(program_10001) is listening for connections on FA-style port 10001"
		return
	}

	logger "periodically_check_adsb_traffic: starting faup1090 to translate 30005 beast to 10001 flightaware"
	start_faup1090
}

proc stop_faup1090_close_faup1090_socket_and_reopen {} {
	stop_faup1090

	close_faup1090_socket_and_reopen
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
		set who "not-connected-yet"
	}
	logger "$::nfaupMessagesReceived msgs recv'd from $who; $::nMessagesSent msgs sent to FlightAware"
}

#
# periodically_issue_a_traffic_report - issue a traffic report every so often
#
proc periodically_issue_a_traffic_report {} {
	after 300000 periodically_issue_a_traffic_report

	traffic_report
}

# vim: set ts=4 sw=4 sts=4 noet :

