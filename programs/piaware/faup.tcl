# -*- mode: tcl; tab-width: 4; indent-tabs-mode: t -*-

package require Itcl 3.4

#
# Class that handles connection between faup programs and adept
#
::itcl::class FaupConnection {
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
	private variable nfaupMessagesReceived 0
	# number of message from faup program since we last logged about is
	private variable nfaupMessagesThisPeriod 0
	# total messages sent to adept
	private variable nMessagesSent 0
	# last time we considered (re)starting faup program
	private variable lastConnectAttemptClock 0
	# time of the last message from faup program
	private variable lastFaupMessageClock [clock seconds]
	# time we were last connected to data port
	private variable lastAdsbConnectedClock [clock seconds]
	# timer for traffic report
	private variable faupMessagesPeriodStartClock
	# last banner tsv_version we saw - REVISIT!
	#private variable tsvVersion ""
	# timer to start faup program connection
	private variable adsbPortConnectTimer

	private variable faupPipe
	private variable faupPid

	constructor {args} {
		configure {*}$args
	}

	destructor {
		faup_disconnect
	}

	#
	# Connect to faup program and configure channel
	#
        method faup_connect {} {
		unset -nocomplain adsbPortConnectTimer

		# just in case..
		faup_disconnect

		set lastConnectAttemptClock [clock seconds]

		if {[is_local_receiver]} {
			inspect_sockets_with_netstat

			if {$::netstatus_reliable && ![is_adsb_program_running]} {
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

				return
			}

			set prog [adsb_local_program_name]
			if {$prog ne ""} {
				set adsbDataProgram $prog
			}
			set lastAdsbConnectedClock [clock seconds]
			logger "ADS-B data program '$adsbDataProgram' is listening on port $adsbLocalPort, so far so good"
		}

		set args $faupProgramPath
		lappend args "--net-bo-ipaddr" $receiverHost "--net-bo-port" $receiverPort "--stdout"
		if {$receiverLat ne "" && $receiverLon ne ""} {
			lappend args "--lat" [format "%.3f" $receiverLat] "--lon" [format "%.3f" $receiverLon]
		}

		logger "Starting $this: $args"

		if {[catch {::fa_sudo::popen_as -noroot -stdout faupStdout -stderr faupStderr {*}$args} result] == 1} {
			logger "got '$result' starting $this, will try again in 5 minutes"
			schedule_adsb_connect_attempt 300
			return
		}

		if {$result == 0} {
			logger "could not start $this: sudo refused to start the command, will try again in 5 minutes"
			schedule_adsb_connect_attempt 300
			return
		}


		logger "Started $this (pid $result) to connect to $adsbDataProgram"
		fconfigure $faupStdout -buffering line -blocking 0 -translation lf
		fileevent $faupStdout readable [list $this data_available]

		log_subprocess_output "${this}($result)" $faupStderr

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
                                logger "$this exited with $why $code"
                        } else {
                                logger "$this exited normally"
                        }
                }

                unset faupPipe
                unset faupPid
	}

	#
	#
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
			logger "lost connection to $adsbDataProgram via $this"
			faup_restart
			return
		}

		# try to read, if that fails, disconnect and reconnect...
		if {[catch {set size [gets $faupPipe line]} catchResult] == 1} {
			logger "got '$catchResult' reading from $this"
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

		# TODO : PROCESS 1090 VS 978 MESSAGE APPROPRIATELY AND SEND TO ADEPT/PIREHOSE
		#puts $line

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
				logger "$this not running, but no restart timer set! Fixing it.."
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
			logger "faupMessagesPeriodStartClock: $faupMessagesPeriodStartClock"
			set minutesThisPeriod [expr {round(([clock seconds] - $faupMessagesPeriodStartClock) / 60.0)}]
			set periodString " ($nfaupMessagesThisPeriod in last ${minutesThisPeriod}m)"
		}
		set faupMessagesPeriodStartClock [clock seconds]
		set nfaupMessagesThisPeriod 0

		logger "$nfaupMessagesReceived msgs recv'd from $adsbDataProgram$periodString; $nMessagesSent msgs sent to FlightAware"

	}

	method is_local_receiver {} {
		return [expr {$adsbLocalPort ne 0}]
	}

	#
	# is_adsb_program_running - return 1 if the adsb program
	# is running, else 0
	#
	method is_adsb_program_running {} {
		if {![is_local_receiver]} {
			# not local, assume yes
			return 1
		}

		return [info exists ::netstatus($adsbLocalPort)]
	}

	method adsb_local_program_name {} {
		if {![is_local_receiver]} {
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
}
