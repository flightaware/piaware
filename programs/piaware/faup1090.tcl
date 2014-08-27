#
# piaware - aviation data exchange protocol ADS-B client
#
# Copyright (C) 2014 FlightAware LLC, All Rights Reserved
#

# initially retry after this long
set ::faup1090ConnectRetryInterval 10

#
# connect_faup1090 - setup a client socket that connects to faup1090
#  fa "baked" port 10001
#
proc connect_faup1090 {} {
	if {![is_dump1090_running]} {
		logger "connect_faup1090: dump1090 isn't running"
		after 60000 connect_faup1090
		return
	}

	logger "connect_faup1090: dump1090 is running"

	if {![is_faup1090_running]} {
		logger "connect_faup1090: faup1090 isn't running but i'll try connecting anyway in case you're running FA dump1090"
		#return
	}

    if {[catch {socket 127.0.0.1 $::faup1090Port} ::faup1090Socket] == 1} {
		if {[lindex $::errorCode 0] == "POSIX" && [lindex $::errorCode 1] == "ECONNREFUSED"} {
			logger "connection refused on faup1090 / dump090 port 10001, retrying in ${::faup1090ConnectRetryInterval}s..."
		} else {
			logger "error opening connection to faup1090 / FA dump1090: $::faup1090Socket, retrying in ${::faup1090ConnectRetryInterval}s..."
		}
		unset ::faup1090Socket
		after [expr {$::faup1090ConnectRetryInterval * 1000}] connect_faup1090
		set ::faup1090ConnectRetryInterval 60
		return
    }

	fconfigure $::faup1090Socket -buffering line -translation binary -blocking 0
    fileevent $::faup1090Socket readable faup1090_data_available
    logger "$::argv0 is connected to faup1090 / FA dump1090"
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

proc close_faup1090_socket_and_reopen {} {
	close_faup1090_socket

	after 60000 connect_faup1090
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
		if {$::presumed1090} {
			logger "piaware is receiving messages from the FA version of dump1090!"
		} else {
			logger "faup1090 is decoding messages from dump1090 and piaware is receiving them!"
		}
	}

    #puts "faup1090 data: $line"
	# if logged into flightaware adept, send the data
	send_if_logged_in $line
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
# setup_faup1090_client - client-side setup
#
proc setup_faup1090_client {} {
	set ::connected1090 0
	set ::presumed1090 0
	set ::nfaupMessagesReceived 0
	set ::nMessagesSent 0
    connect_faup1090
}

#
# stop_faup1090 - stop faup1090 if it is running
#
proc stop_faup1090 {} {
	if {![info exists ::faup1090Pid]} {
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
	logger "start_faup1090: starting faup1090"
	set ::faup1090Pid [exec /usr/bin/faup1090 &]
	sleep 3
}

#
# is_faup1090_running - return the pid of faup1090 if it is running, else 0
#
proc is_faup1090_running {} {
	if {![info exists ::faup1090Pid]} {
		return 0
	}

	# try to reap any dead children
	if {[catch {wait -nohang} catchResult] == 1} {
		# probably no children
	} else {
		if {$catchResult != ""} {
			if {[lindex $catchResult 0] == $::faup1090Pid} {
				logger "is_faup_running: faup1090 process exited: $catchResult"
				unset ::faup1090Pid
				return 0
			} else {
				logger "reaped some non-faup1090 process??? $catchResult"
			}
		}
	}

	return [is_pid_running $::faup1090Pid]
}

#
# faup1090_running_periodic_check - periodically check to see if faup1090 is
#  running and if it is not, start it up again
#
proc faup1090_running_periodic_check {} {
	after 60000 faup1090_running_periodic_check

	if {[is_faup1090_running]} {
		#logger "faup1090_running_periodic_check: faup1090 is running"
		return
	}

	if {![is_dump1090_running]} {
		logger "dump1090 does not appear to be running, next check in 60s"
		logger "please invoke 'ps ax | grep dump1090' to check for yourself."
		return
	}

	# if we are connected to dump1090 but faup1090 isn't running then they
	# are probably running our version of dump1090
	if {$::connected1090} {
		if {!$::presumed1090} {
			logger "i presume you are running the FA version of dump1090 because i am connected to port 10001 yet faup1090 isn't running"
			set ::presumed1090 1
		}
		return
	}

	logger "faup1090_running_periodic_check: starting faup1090"
	start_faup1090
}

#
# traffic_report - log a traffic report of messages received from dump1090
#   and messages sent to FlightAware
#
proc traffic_report {} {
	logger "$::nfaupMessagesReceived msgs recv'd from dump1090; $::nMessagesSent msgs sent to FlightAware"
}

#
# periodically_issue_a_traffic_report - issue a traffic report every so often
#
proc periodically_issue_a_traffic_report {} {
	after 300000 periodically_issue_a_traffic_report

	traffic_report
}

# vim: set ts=4 sw=4 sts=4 noet :

