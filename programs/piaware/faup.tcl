# -*- mode: tcl; tab-width: 4; indent-tabs-mode: t -*-

package require Itcl 3.4

#
# Class that handles connection between faup programs and adept
#
::itcl::class FaupConnection {
	public variable prettyName
	public variable receiverType
	public variable receiverHost
	public variable receiverPort
	public variable receiverLat
	public variable receiverLon
	public variable receiverDataFormat
	public variable adsbLocalPort
	public variable adsbDataService
	public variable adsbDataProgram
	public variable faupProgramPath

	# total message from faup program
	protected variable nfaupMessagesReceived 0
	# number of message from faup program since we last logged about is
	protected variable nfaupMessagesThisPeriod 0
	# total messages sent to adept
	protected variable nMessagesSent 0
	# last time we considered (re)starting faup program
	protected variable lastConnectAttemptClock 0
	# time of the last message from faup program
	protected variable lastFaupMessageClock [clock seconds]
	# time we were last connected to data port
	protected variable lastAdsbConnectedClock [clock seconds]
	# timer for traffic report
	protected variable faupMessagesPeriodStartClock
	# timer to start faup program connection
	protected variable adsbPortConnectTimer

	protected variable faupPipe
	protected variable faupPid

	constructor {args} {
		set prettyName [namespace tail $this]
		configure {*}$args
	}

	destructor {
		faup_disconnect
	}

	protected method program_args {} {
		return [list $faupProgramPath]
	}

	#
	# Connect to faup program and configure channel
	#
	method faup_connect {} {
		unset -nocomplain adsbPortConnectTimer

		# just in case..
		faup_disconnect

		set lastConnectAttemptClock [clock seconds]

		# Make sure ads-b program (i.e. dump1090, dump978, etc.) is alive and listening. Will attempt a restart if seen dead for a while
		if {[is_local_receiver $adsbLocalPort] && ![adsb_program_alive]} {
			return
		}

		set args [list $faupProgramPath {*}[program_args]]
		logger "Starting $prettyName: $args"

		if {[catch {::fa_sudo::popen_as -noroot -stdout faupStdout -stderr faupStderr {*}$args} result] == 1} {
			logger "got '$result' starting $prettyName, will try again in 5 minutes"
			schedule_adsb_connect_attempt 300
			return
		}

		if {$result == 0} {
			logger "could not start $prettyName: sudo refused to start the command, will try again in 5 minutes"
			schedule_adsb_connect_attempt 300
			return
		}


		logger "Started $prettyName (pid $result) to connect to $adsbDataProgram"
		fconfigure $faupStdout -buffering line -blocking 0 -translation lf
		fileevent $faupStdout readable [list $this data_available]

		log_subprocess_output "${prettyName}($result)" $faupStderr

		set faupPipe $faupStdout
		set faupPid $result

		# pretend we saw a message so we don't repeatedly restart
		set lastFaupMessageClock [clock seconds]
	}

	#
	# clean up faup pipe, don't schedule a reconnect
	#
	method faup_disconnect {} {
		if {![info exists faupPipe]} {
			# nothing to do.
			return
		}

		# record when we were last connected
		set lastAdsbConnectedClock [clock seconds]
		catch {kill HUP $faupPid}
		catch {close $faupPipe}

		catch {
			lassign [timed_waitpid 15000 $faupPid] deadpid why code
			if {$code ne "0"} {
				logger "$prettyName exited with $why $code"
			} else {
				logger "$prettyName exited normally"
			}
		}

		unset faupPipe
		unset faupPid
	}

	#
	# restart faup connection at scheduled time
	#
	method faup_restart {{delay 30}} {
		faup_disconnect

		if {$delay eq "now" || [clock seconds] - $lastConnectAttemptClock > $delay} {
			logger "reconnecting to $adsbDataProgram"
			schedule_adsb_connect_attempt 1
			return
		}

		logger "will reconnect to $adsbDataProgram in $delay seconds"
		schedule_adsb_connect_attempt $delay
	}

	#
	# schedule_adsb_connect_attempt - schedule an attempt to connect
	#  to the ADS-B port canceling the prior one if one was already scheduled
	#
	# support "idle" as an argument to do "after idle" else a number of seconds
	#
	method schedule_adsb_connect_attempt {inSeconds} {
		if {[info exists adsbPortConnectTimer]} {
			after cancel $adsbPortConnectTimer
			#logger "canceled prior adsb port connect attempt timer $adsbPortConnectTimer"
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

		set adsbPortConnectTimer [after $ms [list $this faup_connect]]
		#logger "scheduled FA-style ADS-B port connect attempt $explain as timer ID $adsbPortConnectTimer"
	}

	#
	# filevent callback routine when data available on socket
	#
	method data_available {} {
		# if eof, cleanly close the faup socket and reconnect...
		if {[eof $faupPipe]} {
			logger "lost connection to $adsbDataProgram via $prettyName"
			faup_restart
			return
		}

		# try to read, if that fails, disconnect and reconnect...
		if {[catch {set size [gets $faupPipe line]} catchResult] == 1} {
			logger "got '$catchResult' reading from $prettyName"
			faup_restart
			return
		}

		# sometimes you can get a notice of data available and not get any data.
		# it happens.  nothing to do? return.
		if {$size < 0} {
			return
		}

		incr nfaupMessagesReceived
		incr nfaupMessagesThisPeriod
		if {$nfaupMessagesReceived  == 1} {
			log_locally "piaware received a message from $adsbDataProgram!"
		}

		array set row [split $line "\t"]
		if {[info exists row(type)] && $row(type) eq "location_update"} {
			# we handle this directly
			handle_location_update "receiver" $row(lat) $row(lon) $row(alt) $row(altref)
			return
		}

		# require _v
		if {![info exists row(_v)]} {
			log_locally "$prettyName appears to be the wrong version, restarting"
			faup_restart
			return
		}

		# do any custom message handling
		custom_handler row

		#puts "faup data: $line"

		# if logged into flightaware adept, send the data
		send_if_logged_in row

		# also forward to pirehose, if running
		forward_to_pirehose $line

		set lastFaupMessageClock [clock seconds]
	}

	#
	# check_adsb_traffic - see if ADS-B messages are being received.
	# restart stuff as necessary
	#
	method check_traffic {} {
		set secondsSinceLastMessage [expr {[clock seconds] - $lastFaupMessageClock}]

		if {[info exists faupPipe]} {
			# faup program is running, check we are hearing some messages
			if {$secondsSinceLastMessage >= $::noMessageActionIntervalSeconds} {
				# force a restart
				logger "no new messages received in $secondsSinceLastMessage seconds, it might just be that there haven't been any aircraft nearby but I'm going to try to restart everything, just in case..."
				faup_disconnect
				if {$adsbDataService ne ""} {
					::fa_services::attempt_service_restart $adsbDataService restart
				}
				schedule_adsb_connect_attempt 10
			}
		} else {
			if {![info exists adsbPortConnectTimer]} {
				# faup program not running and no timer set! Bad doggie.
				logger "$prettyName not running, but no restart timer set! Fixing it.."
				schedule_adsb_connect_attempt 5
			}
		}

	}

	#
	# traffic_report - log a traffic report of messages received from the adsb
	#   program and messages sent to FlightAware
	#
	method traffic_report {} {
		set periodString ""
		if {[info exists faupMessagesPeriodStartClock]} {
			set minutesThisPeriod [expr {round(([clock seconds] - $faupMessagesPeriodStartClock) / 60.0)}]
			set periodString " ($nfaupMessagesThisPeriod in last ${minutesThisPeriod}m)"
		}
		set faupMessagesPeriodStartClock [clock seconds]
		set nfaupMessagesThisPeriod 0

		logger "$nfaupMessagesReceived msgs recv'd from $adsbDataProgram$periodString; $nMessagesSent msgs sent to FlightAware"

	}

	#
	# send_if_logged_in - send an adept message but only if logged in
	#
	method send_if_logged_in {_row} {
		upvar $_row row

		if {![adept is_logged_in]} {
			return
		}

		if {[catch {send_adsb_line row} catchResult] == 1} {
			log_locally "error uploading ADS-B message: $catchResult"
		}
	}

	#
	# send_adsb_line - send an ADS-B message to the adept server
	#
	method send_adsb_line {_row} {
		upvar $_row row

		adept send_array row

		incr nMessagesSent
		if {$nMessagesSent == 7} {
			log_locally "piaware has successfully sent several msgs to FlightAware!"
		}
	}

	#
	# Check whether adsb data program is alive and listening. Attempt to restart if seen dead for a while
	#
	method adsb_program_alive {} {
		inspect_sockets_with_netstat

		if {$::netstatus_reliable && ![is_adsb_program_running $adsbLocalPort]} {
			# still no listener, consider restarting
			set secondsSinceListenerSeen [expr {[clock seconds] - $lastAdsbConnectedClock}]
			if {$secondsSinceListenerSeen >= $::adsbNoProducerStartDelaySeconds && $adsbDataService ne ""} {
				logger "no ADS-B data program seen listening on port $adsbLocalPort for $secondsSinceListenerSeen seconds, trying to start it..."
				::fa_services::attempt_service_restart $adsbDataService start
				# pretend we saw it to reduce restarts if it's failing
				set lastAdsbConnectedClock [clock seconds]
				schedule_adsb_connect_attempt 10
			} else {
				logger "no ADS-B data program seen listening on port $adsbLocalPort for $secondsSinceListenerSeen seconds, next check in 60s"
				schedule_adsb_connect_attempt 60
			}

			return 0
		}

		set prog [adsb_local_program_name $adsbLocalPort]
		if {$prog ne ""} {
			set adsbDataProgram $prog
		}
		set lastAdsbConnectedClock [clock seconds]
		logger "ADS-B data program '$adsbDataProgram' is listening on port $adsbLocalPort, so far so good"

		return 1
	}

	#
	# custom_handler - overriden by derived classes to do any message-specific handling
	#
	method custom_handler {_row} {
		return
	}

	#
	# return 1 if connected to receiver, otherwise 0
	#
	method is_connected {} {
		return [info exists faupPid]
	}

	#
	# return time of last message received from faup
	#
	method last_message_received {} {
		if {$nfaupMessagesReceived == 0} {
			return 0
		} else {
			return $lastFaupMessageClock
		}
	}
}

#
# Returns whether given port number is local receiver
#
proc is_local_receiver {adsbLocalPort} {
	return [expr {$adsbLocalPort ne 0}]
}

#
# Return 1 if the adsb program is running on specified port, else 0
#
proc is_adsb_program_running {adsbLocalPort} {
	if {![is_local_receiver $adsbLocalPort]} {
		# not local, assume yes
		return 1
	}

	return [info exists ::netstatus($adsbLocalPort)]
}

#
# Return adsb program name running on specified port
#
proc adsb_local_program_name {adsbLocalPort} {
	if {![is_local_receiver $adsbLocalPort]} {
		return ""
	}

	if {![info exists ::netstatus($adsbLocalPort)]} {
		return ""
	}

	lassign $::netstatus($adsbLocalPort) prog pid
	if {$prog eq "unknown"} {
		return ""
	}

	return $prog
}

# Proc to record new receiver location and restart necessary programs
proc update_location {lat lon} {
	if {$lat eq $::receiverLat && $lon eq $::receiverLon} {
		# unchanged
		return
	}

	# only update the on-disk location & restart things
	# if the location moves by more than about 250m since
	# the last time we updated

	if {$::receiverLat ne "" && $::receiverLon ne ""} {
		# approx distances in km along lat/lon axes, don't bother with the full GC distance
		set dLat [expr {111 * ($::receiverLat - $lat)}]
		set dLon [expr {111 * ($::receiverLon - $lon) * cos($lat * 3.1415927 / 180.0)}]
		if {abs($dLat) < 0.250 && abs($dLon) < 0.250} {
			# Didn't change enough to care about restarting
			return
		}
	}

	# changed nontrivially; restart dump1090 / faup1090 / skyaware978 to use the new values
	set ::receiverLat $lat
	set ::receiverLon $lon

	# speculatively restart dump1090/skyaware978 even if we are not using it as a receiver;
	# it may be used for display.
	if {[save_location_info $lat $lon]} {
		logger "Receiver location changed, restarting dump1090 and skyaware978"
		::fa_services::attempt_service_restart dump1090 restart
		::fa_services::attempt_service_restart skyaware978 restart
	}

	if {[info exists ::faup1090] && [$::faup1090 is_connected]} {
		logger "Restarting faup1090"
		restart_faup1090 5
	}
}
