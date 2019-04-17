# -*- mode: tcl; tab-width: 4; indent-tabs-mode: t -*-
#
# fa_adept_client - Itcl class for connecting to and communicating with
#  an Open Aviation Data Exchange Protocol service
#
# Copyright (C) 2014 FlightAware LLC, All Rights Reserved
#
# open source in accordance with the Berkeley license
#

package require tls
package require Itcl 3.4
package require fa_adept_codecs 2.1

namespace eval ::fa_adept {

set caDir [file join [file dirname [info script]] "ca"]

::itcl::class AdeptClient {
	public variable sock
	public variable hosts [list piaware.flightaware.com piaware.flightaware.com [list 70.42.6.197 70.42.6.198 70.42.6.191 70.42.6.225 70.42.6.224 70.42.6.156]] shuffle_hosts
	public variable port 1200
	public variable loginTimeoutSeconds 30
	public variable connectRetryIntervalSeconds 60
	public variable showTraffic 0
	public variable mac

	# configuration hooks for actions the client wants to trigger
	public variable logCommand "puts stderr"
	public variable updateLocationCommand
	public variable mlatCommand
	public variable updateCommand
	public variable loginCommand
	public variable loginResultCommand

	protected variable shuffledHosts
	protected variable host
	protected variable connected 0
	protected variable loggedIn 0
	protected variable writabilityTimerID
	protected variable wasWritable 0
	protected variable loginTimerID
	protected variable reconnectTimerID
	protected variable aliveTimerID
	protected variable nextHostIndex 0
	protected variable codec
	protected variable flushPending 0
	protected variable deviceLocation ""
	protected variable lastReportedLocation ""

	constructor {args} {
		configure {*}$args
		shuffle_hosts
	}

    #
    # logger - log a message
    #
    method logger {text} {
		catch { {*}$logCommand $text }
    }

	# shuffle - random shuffle of a list, used to randomize the order of fallback IPs
	# we just brute-force this since the lists are small
	proc shuffle {l} {
		set result [list]
		while {[llength $l] > 0} {
			set i [expr {int(rand() * [llength $l])}]
			lappend result [lindex $l $i]
			set l [lreplace $l $i $i]
		}
		return $result
	}

	# shuffle_hosts - populate shuffledHosts from hosts
	method shuffle_hosts {} {
		set shuffledHosts [list]
		foreach hostList $hosts {
			lappend shuffledHosts {*}[shuffle $hostList]
		}
	}

	#
	# next_host - return the next host in the list of hosts
	#
	method next_host {} {
		set host [lindex $shuffledHosts $nextHostIndex]
		incr nextHostIndex
		if {$nextHostIndex >= [llength $shuffledHosts]} {
			set nextHostIndex 0
			shuffle_hosts
		}
		return $host
	}

    #
    # tls_callback - routine called back during TLS negotiation
    #
    method tls_callback {cmd channel args} {
		switch $cmd {
			verify {
				lassign $args depth cert status err
				if {!$status} {
					logger "TLS verify failed: $err"
					logger "Failing certificate:"
					foreach {k v} $cert {
						logger "  $k: $v"
					}
				}
				return $status
			}

			error {
				lassign $args message
				logger "TLS error: $message"
			}

			info {
				lassign $args major minor message
				if {$major eq "alert" && $message ne "close notify"} {
					logger "TLS alert ($minor): $message"
				} elseif {$major eq "error"} {
					logger "TLS error ($minor): $message"
				}
			}

			default {
				logger "unhandled TLS callback: $cmd $channel $args"
			}
		}
    }

	#
	# cancel_timers - cancel all outstanding connect/alive timers
	#
	method cancel_timers {} {
		cancel_alive_timer
		cancel_login_timer
		cancel_reconnect_timer
		cancel_writability_timer
	}

	#
	# cancel_login_timer - cancel the timer that aborts the connection
	# if we have not successfully logged in after a while
	#
	method cancel_login_timer {} {
		if {[info exists loginTimerID]} {
			after cancel $loginTimerID
			unset loginTimerID
		}
	}

	#
	# cancel_reconnect_timer - cancel the timer that schedules a
	# reconnection
	#
	method cancel_reconnect_timer {} {
		if {[info exists reconnectTimerID]} {
			after cancel $reconnectTimerID
			unset reconnectTimerID
		}
	}

    #
    # connect - close socket if open, then make a TLS connection, then validate
	#  the certificate, then try to login
    #
    method connect {} {
		# close the connection if already connected and cancel the reconnect
		# event timer if there is one
		close_socket
		cancel_timers
		next_host

		logger "Connecting to FlightAware adept server at $host/$port"

		# start the connection attempt
		if {[catch {set sock [socket -async $host $port]} catchResult]} {
			logger "Connection to adept server at $host/$port failed: $catchResult"
			close_socket_and_reopen
			return 0
		}

		# schedule a timer that gives up if the login doesn't succeed for a while
		set loginTimerID [after [expr {$loginTimeoutSeconds * 1000}] $this abort_login_attempt]

		fileevent $sock writable [list $this connect_completed]
		return 1
	}

	method connect_completed {} {
		if {![info exists sock]} {
			# we raced with a close for some other reason
			return
		}

		# turn off the writability check now
		fileevent $sock writable ""

		set error [fconfigure $sock -error]
		if {$error ne ""} {
			logger "Connection to adept server at $host/$port failed: $error"
			close_socket_and_reopen
			return
		}

		logger "Connection with adept server at $host/$port established"

		# attempt to connect with TLS negotiation.  Use the included
		# CA cert file to confirm the cert's signature on the certificate
		# the server sends us
		if {[catch {tls::import $sock \
						-cipher ALL \
						-cadir $::fa_adept::caDir \
						-ssl2 0 \
						-ssl3 0 \
						-tls1 1 \
						-require 1 \
						-command [list $this tls_callback]} catchResult] == 1} {
			logger "TLS initialization with adept server at $host/$port failed: $catchResult"
			close_socket_and_reopen
			return
		}

		# go nonblocking immediately, so we do not block on the handshake
		fconfigure $sock -blocking 0

		# kick off a nonblocking handshake
		$this try_to_handshake
	}

	method try_to_handshake {} {
		# force the handshake to complete before proceeding
		# we can get errors from this.  catch them and return failure
		# if one occurs.
		if {[catch {::tls::handshake $sock} result] == 1} {
			if {[lindex $::errorCode 0] == "POSIX" && [lindex $::errorCode 1] == "EAGAIN"} {
				# not completed yet
				set result 0
			} else {
				# a real error
				logger "TLS handshake with adept server at $host/$port failed: $result"
				close_socket_and_reopen
				return
			}
		}

		if {!$result} {
			# handshake is not done yet, try again later
			fileevent $sock readable [list $this try_to_handshake]
			return
		}

		logger "TLS handshake with adept server at $host/$port completed"
		fileevent $sock readable ""

		# obtain information about the TLS session we negotiated
		set tlsStatus [::tls::status $sock]
		#logger "TLS status: $tlsStatus"

		# validate the certificate.  error out if it fails.
		if {![validate_certificate_status $tlsStatus reason]} {
			logger "Certificate validation with adept server at $host/$port failed: $reason"
			close_socket_and_reopen
			return
		}

		# tls local status are key-value pairs of number of bits
		# in the session key (sbits) and the cipher used, such
		# as DHE-RSA-AES256-SHA
		#logger "TLS local status: [::tls::status -local $sock]"
		logger "encrypted session established with FlightAware"

		# configure the socket nonblocking full-buffered and
		# schedule this object's server_data_available method
		# to be invoked when data is available on the socket
		# we arrange to call flush periodically while output is pending,
		# to get better batching of data while still getting it out
		# promptly

		fconfigure $sock -buffering full -buffersize 4096 -translation binary
		fileevent $sock readable [list $this server_data_available]
		set connected 1
		set flushPending 0

		# reset the codec until we have sent our login message
		set codec [::fa_adept_codec::new_codec none]

		schedule_writability_check

		# ok, we're connected, now attempt to login
		# note that login reply will be asynchronous to us, i.e.
		# it will come in later
		login
    }

    #
    # validate_certificate_status - return 1 if the certificate looks cool,
	#  else 0
    #
    method validate_certificate_status {statusList _reason} {
        upvar $_reason reason

		array set status $statusList

		# require expected fields
		foreach field "subject issuer notBefore notAfter" {
			if {![info exists status($field)]} {
				set reason "required field '$field' is missing"
				return 0
			}
		}

		# make sure the notBefore time has passed
		set notBefore [clock scan $status(notBefore)]
		set now [clock seconds]

		if {$now < $notBefore} {
			set reason "now is before certificate start time"
			return 0
		}

		# make sure the notAfter time has yet to occur
		set notAfter [clock scan $status(notAfter)]
		if {$now > $notAfter} {
			set reason "certificate expired"
			return 0
		}

		# crack fields in the certificate and require some of them to be present
		crack_certificate_fields $status(subject) subject
		#parray subject

		# validate the common name
		if {![info exist subject(CN)] || ($subject(CN) != "*.flightaware.com" && $subject(CN) != "piaware.flightaware.com" && $subject(CN) != "adept.flightaware.com" && $subject(CN) != "eyes.flightaware.com")} {
			set reason "subject CN is not valid"
			return 0
		}

		logger "FlightAware server certificate validated"
		return 1
    }

    #
    # crack_certificate_fields - given a string like CN=foo,O=bar,L=Houston,
	#  crack the key-value pairs into the named array
    #
    method crack_certificate_fields {string _array} {
		upvar $_array array

		foreach pair [split $string ",/"] {
			lassign [split $pair "="] key value
			set array($key) $value
		}

		return
    }

	method abort_login_attempt {} {
		if {![is_connected]} {
			logger "Connection attempt with adept server at $host/$port timed out"
		} else {
			logger "Login attempt with adept server at $host/$port timed out"
		}
		close_socket_and_reopen
	}

    #
    # server_data_available - callback routine invoked when data is available
	# from the server
    #
    method server_data_available {} {
		# if end of file on the socket, close the socket and attempt to reopen
		if {[eof $sock]} {
			logger "Lost connection to adept server at $host/$port: server closed connection"
			close_socket_and_reopen
			return
		}

		# get a line of data from the socket.  if we get an error, close the
		# socket and attempt to reopen
		if {[catch {set size [gets $sock line]} catchResult] == 1} {
			logger "Lost connection to adept server at $host/$port: $catchResult"
			close_socket_and_reopen
			return
		}

		#
		# sometimes you get a callback with no data, that's OK but there's nothing to do
		#
		if {$size < 0} {
			return
		}

		if {$showTraffic} {
			puts "< $line"
		}

		#
		# we got a response, convert it to an array and send it to the
		# response handler
		#
		if {[catch {array set response [split $line "\t"]}] == 1} {
			logger "malformed message from server ('$line'), disconnecting and reconnecting..."
			close_socket_and_reopen
			return
		}

		if {[catch {handle_response response} catchResult] == 1} {
			logger "error handling message '[string map {\n \\n \t \\t} $line]' from server: $catchResult, disconnecting and reconnecting.."
			logger "traceback: [string range $::errorInfo 0 1000]"
			close_socket_and_reopen
			return
		}
    }

	#
	# handle_response - handle a response array from the server, invoked from
	#   server_data_available
	#
	method handle_response {_row} {
		upvar $_row row

		switch -glob $row(type) {
			"login_response" {
				handle_login_response_message row
			}

			"notice" {
				handle_notice_message row
			}

			"alive" {
				handle_alive_message row
			}

			"shutdown" {
				handle_shutdown_message row
			}

			"request_auto_update" {
				if {[info exists updateCommand]} {
					{*}$updateCommand auto row
				}
			}

			"request_manual_update" {
				if {[info exists updateCommand]} {
					{*}$updateCommand manual row
				}
			}

			"mlat_*" {
				if {[info exists mlatCommand]} {
					{*}$mlatCommand row
				}
			}

			"update_location" {
				handle_update_location row
			}

			default {
				logger "unrecognized message type '$row(type)' from server, ignoring..."
				incr ::nUnrecognizedServerMessages
				if {$::nUnrecognizedServerMessages > 20} {
					logger "that's too many, i'm disconnecting and reconnecting..."
					close_socket_and_reopen
					set ::nUnrecognizedServerMessages 0
				}
			}
		}
	}

	#
	# handle_login_response_message - handle a login_response message from the
	#  server
	#
	method handle_login_response_message {_row} {
		upvar $_row row

		if {$row(status) == "ok"} {
			set loggedIn 1

			# we got far enough to call this a successful connection, so
			# start again from the start of the host list next time.
			set nextHostIndex 0

			# if we received lat/lon data, handle it
			handle_update_location row

			cancel_login_timer

			# modern adept servers always send alive messages within the first
			# 60 seconds
			if {![info exists aliveTimerID]} {
				set aliveTimerID [after 90000 [list $this alive_timeout]]
			}
		} else {
			# failed, do not reconnect
			close_socket
			cancel_timers
		}

		if {[info exists loginResultCommand]} {
			{*}$loginResultCommand [array get row]
		} else {
			# better log something at least..
			if {[info exists row(reason)]} {
				logger "login: $row(status); $row(reason)"
			} else {
				logger "login: $row(status)"
			}
		}
	}

	#
	# handle_update_location - handle a location-update notification from the server
	#
	method handle_update_location {_row} {
		upvar $_row row

		if {[info exists row(recv_lat)] && [info exists row(recv_lon)] && [info exists updateLocationCommand]} {
			if {[info exists row(recv_alt)] && [info exists row(recv_altref)]} {
				set alt $row(recv_alt)
				set altref $row(recv_altref)
			} else {
				set alt 0
				set altref ""
			}

			{*}$updateLocationCommand $row(recv_lat) $row(recv_lon) $alt $altref
		}
	}

	#
	# handle_notice_message - handle a notice message from the server
	#
	method handle_notice_message {_row} {
		upvar $_row row

		if {[info exists row(message)]} {
			logger "NOTICE from adept server: $row(message)"
		}
	}

	#
	# handle_shutdown_message - handle a message from the server telling us
	#   that it is shutting down
	#
	method handle_shutdown_message {_row} {
		upvar $_row row

		if {![info exists row(reason)]} {
			set row(reason) "unknown"
		}
		logger "NOTICE adept server is shutting down.  reason: $row(reason)"
	}

	#
	# handle_alive_message - handle an alive message from the server
	#
	method handle_alive_message {_row} {
		upvar $_row row

		# get the system clock on the local pi
		set now [clock seconds]

		if {![info exists row(interval)]} {
			set row(interval) 300
		}
		set afterMS [expr {round($row(interval) * 1000 * 1.2)}]

		# cancel the current alive timeout timer if it exists
		cancel_alive_timer

		# schedule alive_timeout to run in the future
		set aliveTimerID [after $afterMS [list $this alive_timeout]]

		if {[info exists row(clock)]} {
			set ::myClockOffset [expr {$now - $row(clock)}]

			# update the adept server with our new offset
			set message(clock) $now
			set message(offset) $::myClockOffset
			set message(type) alive
			send_array message
		}
	}

	#
	# cancel_alive_timer - cancel the alive timer if it exists
	#
	method cancel_alive_timer {} {
		if {![info exists aliveTimerID]} {
			#logger "cancel_alive_timer: no extant timer ID, doing nothing..."
		} else {
			if {[catch {after cancel $aliveTimerID} catchResult] == 1} {
				#logger "cancel_alive_timer: cancel failed: $catchResult"
			} else {
				#logger "cancel_alive_timer: canceled $aliveTimerID"
			}
			unset aliveTimerID
		}
	}

	#
	# alive_timeout - this is called if the alive timer isn't canceled before
	#  it goes off
	#
	method alive_timeout {} {
		logger "timed out waiting for alive message from FlightAware, reconnecting..."
		close_socket_and_reopen
	}

    #
    # close_socket - close the socket, forcibly if necessary
    #
    method close_socket {} {
		set connected 0
		set loggedIn 0

		if {[info exists sock]} {
			# we don't care about why it didn't close if it doesn't
			# close cleanly...
			# we used to log this and it's just dumb and confusing
			catch {close $sock}
			unset sock
		}

		disable_mlat
    }

    #
    # close_socket_and_reopen - close the socket and reopen it
    #
    method close_socket_and_reopen {} {
		close_socket
		cancel_timers

		set interval [expr {round(($connectRetryIntervalSeconds * (0.8 + rand() * 0.4)))}]
		logger "reconnecting in $interval seconds..."

		set reconnectTimerID [after [expr {$interval * 1000}] [list $this connect]]
    }

	#
	# reconnect - close any existing connection and immediately reconnect
	#
	method reconnect {} {
		close_socket
		cancel_timers
		connect
	}

	#
	# login - attempt to login
	#
	# invoked from connect after successful TLS negotiation
	#
	method login {} {
		if {![is_connected]} {
			error "tried to login while not connected"
		}

		# create the new codec so we can get the codec version,
		# but don't install it until after sending the login message
		set newcodec [::fa_adept_codec::new_codec adept]

		set message(type) login
		set message(mac) $mac
		set message(compression_version) [$newcodec version]

		if {$deviceLocation ne ""} {
			lassign $deviceLocation message(receiverlat) message(receiverlon) message(receiveralt) message(receiveraltref)
		}
		set lastReportedLocation $deviceLocation

		# gather additional login info
		{*}$loginCommand message

		send_array message

		set codec $newcodec
	}

	#
	# send_log_message - upload log message if connected
	#
	method send_log_message {text} {
		if {![is_connected]} {
			return
		}

		set message(type) log
		set message(message) [string map {\n \\n \t \\t} $text]
		set message(mac) $mac

		if {[info exists ::myClockOffset]} {
			set message(offset) $::myClockOffset
		}

		send_array message
	}

	#
	# send_health_message - upload health message if connected
	#
	method send_health_message {_data} {
		upvar $_data data

		array set row [array get data]

		# fill in device location, clock
		if {$deviceLocation ne ""} {
			lassign $deviceLocation row(receiverlat) row(receiverlon) row(receiveralt) row(receiveraltref)
			set lastReportedLocation $deviceLocation
		}

		set row(type) health
		send_array row
	}

    #
    # is_connected - return 1 if the session is connected, otherwise 0
    #
    method is_connected {} {
		return $connected
    }

    #
    # is_logged_in - return 1 if the session is logged in, otherwise 0
    #
    method is_logged_in {} {
		return $loggedIn
    }

    #
    # send - send the message to the server.  if puts returns an error,
	#  disconnects and schedules reconnection shortly in the future
    #
    method send {text} {
		if {![is_connected]} {
			# we might be halfway through a reconnection.
			# drop data on the floor
			return
		}

		if {$showTraffic} {
			puts "> $text"
		}

		if {[catch {puts $sock $text} catchResult] == 1} {
			logger "got '$catchResult' writing to FlightAware socket, reconnecting..."
			close_socket_and_reopen
			return
		}

		if {!$flushPending} {
			set flushPending 1
			after 200 [list $this flush_output]
		}
    }

	# flush any buffered output
	method flush_output {} {
		set flushPending 0
		if {[info exists sock]} {
			if {[catch {flush $sock} catchResult] == 1} {
				logger "got '$catchResult' writing to FlightAware socket, reconnecting..."
				close_socket_and_reopen
				return
			}
		}
	}

	#
	# send_array - send an array as a message
	#
	method send_array {_row} {
		upvar $_row row

		if {[info exists row(clock)]} {
			set now [clock seconds]
			if {abs($now - $row(clock)) > 1} {
				set row(sent_at) $now
			}
		} else {
			set row(clock) [clock seconds]
		}

		$codec encode row

		set message ""
		foreach field [lsort [array names row]] {
			# last ditch effort to remove characters that are going to interfere with the message structure
			set value [string map {\n \\n \t \\t} $row($field)]
			append message "\t$field\t$value"
		}

		send [string range $message 1 end]
	}

	#
	# schedule_writability_check:
	#   every 10 seconds, set up a fileevent callback to check for socket writability
	#   if/when the fileevent callback fires, remove the callback and set a flag
	#   when the timer next fires, if the flag isn't set, then give up and abort
	#
	method schedule_writability_check {} {
		cancel_writability_timer
		set wasWritable 0
		set writabilityTimerID [after 10000 [list $this check_writability]]
		catch {fileevent $sock writable [list $this socket_was_writable]}
	}

	method socket_was_writable {} {
		set wasWritable 1
		fileevent $sock writable ""
	}

	method check_writability {} {
		if {!$wasWritable} {
			logger "data isn't making it to FlightAware, reconnecting..."
			close_socket_and_reopen
		} else {
			schedule_writability_check
		}
	}

	method cancel_writability_timer {} {
		if {[info exists writabilityTimerID]} {
			after cancel $writabilityTimerID
			unset writabilityTimerID
		}
	}

	method set_location {loc} {
		set deviceLocation $loc
	}

	method last_reported_location {} {
		return $lastReportedLocation
	}
}

} ;# namespace fa_adept

package provide fa_adept_client 0.0

# vim: set ts=4 sw=4 sts=4 noet :

