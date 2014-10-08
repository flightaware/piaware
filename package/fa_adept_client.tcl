#
# fa_adept_client - Itcl class for connecting to an Open Aviation Data
# Exchange Protocol service
#
# Copyright (C) 2014 FlightAware LLC, All Rights Reserved
#
#

package require tls
package require Itcl

namespace eval ::fa_adept {

::itcl::class AdeptClient {
    public variable sock
    public variable host eyes.flightaware.com
    public variable port 1200
    public variable connectRetryIntervalSeconds 60
    public variable connected 0
    public variable loggedIn 0

	protected variable writabilityCheckAfterID
    protected variable connectTimerID
	protected variable aliveTimerID

    constructor {args} {
		configure {*}$args

		schedule_writability_check
    }


    #
    # logger - log a message
    #
    method logger {text} {
		puts stderr "[clock format [clock seconds] -format "%D %T" -gmt 1] $text"
    }

    #
    # tls_callback - routine called back during TLS negotiation
    #
    method tls_callback {args} {
		logger "tls_callback: $args"
    }

	#
	# cancel_connect_timer - cancel the timer we set at the start of attempting
	#  to connect that'll attempt to connect again.  intended to be called
	#  at the start of attempting to connect
	#
	method cancel_connect_timer {} {
		if {[info exists connectTimerID]} {
			after cancel $connectTimerID
			unset connectTimerID
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
		cancel_connect_timer

		# schedule a new connect attempt in the future
		# if we succeed to connect and login, we'll cancel this
		set connectTimerID [after [expr {$connectRetryIntervalSeconds * 1000}] $this connect]

		logger "connecting to FlightAware $host/$port"

		# attempt to connect with TLS negotiation.  Use the included
		# CA cert file to confirm the cert's signature on the certificate
		# the server sends us
		if {[catch {set sock [tls::socket \
			-cipher ALL \
			-cafile [::fa_adept::ca_crt_file] \
			-ssl2 0 \
			-ssl3 0 \
			-tls1 1 \
			$host $port]} catchResult] == 1} {
			logger "got '$catchResult' to adept server at $host/$port, will try again soon..."
			return 0
		}

			#-command [list $this tls_callback] \
			#-require 1  \
			#-request 1  
			#-command [list $this tls_callback] 

		# force the handshake to complete before proceeding
		# we can get errors from this.  catch them and return failure
		# if one occurs.
		if {[catch {::tls::handshake $sock} catchResult] == 1} {
			logger "error during tls handshake: $catchResult, will try again soon..."
			return 0
		}

		# obtain information about the TLS session we negotiated
		set tlsStatus [::tls::status $sock]
		#logger "TLS status: $tlsStatus"

		# validate the certificate.  error out if it fails.
		if {![validate_certificate_status $tlsStatus reason]} {
			error "certificate validation failed: $reason"
		}

		# tls local status are key-value pairs of number of bits
		# in the session key (sbits) and the cipher used, such
		# as DHE-RSA-AES256-SHA
		#logger "TLS local status: [::tls::status -local $sock]"
		logger "encrypted session established with FlightAware"

		# configure the socket nonblocking line-buffered and
		# schedule this object's server_data_available method
		# to be invoked when data is available on the socket

		fconfigure $sock -buffering line -blocking 0 -translation binary
		fileevent $sock readable [list $this server_data_available]
		set connected 1

		# ok, we're connected, now attempt to login
		# note that login reply will be asynchronous to us, i.e.
		# it will come in later
		login

		return 1
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
		foreach field "CN O L ST C" {
			if {![info exists subject($field)]} {
				set reason "required subject field '$field' is missing"
				return 0
			}
		}

		# crack issuer fields from the certificate and require some of them to be
		# present
		crack_certificate_fields $status(issuer) issuer
		#parray issuer
		foreach field "CN OU O C" {
			if {![info exists issuer($field)]} {
				set reason "required issuer field '$field' is missing"
				return 0
			}
		}

		# validate the common name
		if {$subject(CN) != "*.flightaware.com"} {
			set reason "subject CN is not '*.flightaware.com"
			return 0
		}

		# validate the organization
		if {$subject(O) != "FlightAware LLC"} {
			set reason "subject O is not 'FlightAware LLC'"
			return 0
		}

		# validate the state
		if {$subject(ST) != "Texas"} {
			set reason "subject ST is not 'Texas'"
		}

		# validate the country
		if {$subject(C) != "US"} {
			set reason "subject C is not 'US'"
			return 0
		}

		# validate the type of certificate
		if {![string match "DigiCert*High Assurance*" $issuer(CN)]} {
			set reason "issuer CN is not 'DigiCert High Assurance'"
			return 0
		}

		# validate the signer
		if {$issuer(O) != "DigiCert Inc"} {
			set reason "issuer O is not 'DigiCert Inc'"
			return 0
		}

		if {$issuer(C) != "US"} {
			set reason "issuer C is not 'US'"
			return 0
		}

		logger "FlightAware server SSL certificate validated"
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

    #
    # server_data_available - callback routine invoked when data is available 
	# from the server
    #
    method server_data_available {} {
		# if end of file on the socket, close the socket and attempt to reopen
		if {[eof $sock]} {
			reap_any_dead_children
			logger "lost connection to FlightAware, reconnecting..."
			close_socket_and_reopen
			return
		}

		# get a line of data from the socket.  if we get an error, close the
		# socket and attempt to reopen
		if {[catch {set size [gets $sock line]} catchResult] == 1} {
			logger "got '$catchResult' reading FlightAware socket, reconnecting... "
			close_socket_and_reopen
		}

		#
		# sometimes you get a callback with no data, that's OK but there's 
		# nothing to do
		#
		if {$size < 0} {
			return
		}

		#
		# we got a response, convert it to an array and send it to the
		# response handler
		#
		if {[catch {array set response [split $line "\t"]}] == 1} {
			logger "malformed message from server ('$line'), ignoring..."
			return
		}

		if {[catch {handle_response response} catchResult] == 1} {
			logger "error handling message '$line' from server ($catchResult), continuing..."
		}
    }

	#
	# handle_response - handle a response array from the server, invoked from
	#   server_data_available
	#
	method handle_response {_row} {
		upvar $_row row

		switch $row(type) {
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

			default {
				logger "unrecognized message type '$row(type)' from server, ignoring..."
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

			# if the login response contained a user, that's what we're
			# logged in as even if it's not what we might've said or
			# more likely we didn't say
			if {[info exists row(user)]} {
				set ::flightaware_user $row(user)
			}

			logger "logged in to FlightAware as user $::flightaware_user"
			cancel_connect_timer
		} else {
			# NB do more here, like UI stuff
			logger "*******************************************"
			logger "LOGIN FAILED: status '$row(status)': reason '$row(reason)'"
			logger "please correct this, possibly using piaware-config"
			logger "to set valid Flightaware user name and password."
			logger "piaware will now exit."
			logger "You can start it up again using 'sudo /etc/init.d/piaware start'"
			exit 4
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

		if {![info exists row(interval)]} {
			set row(interval) 300
		}
		set afterMS [expr {round($row(interval) * 1000 * 1.2)}]

		# cancel the current alive timeout timer if it exists
		if {![info exists aliveTimerID]} {
			logger "server is sending alive messages; we will expect them"
		} else {
			#logger "alive message received from FlightAware"
			cancel_alive_timer
		}

		# schedule alive_timeout to run in the future
		set aliveTimerID [after $afterMS [list $this alive_timeout]]
		#logger "handle_alive_message: alive timer ID is $aliveTimerID"
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

		cancel_alive_timer

		if {[info exists sock]} {
			# we don't care about why it didn't close if it doesn't
			# close cleanly...
			# we used to log this and it's just dumb and confusing
			catch {close $sock}
			unset sock
		}

		reap_any_dead_children
    }

    #
    # close_socket_and_reopen - close the socket and reopen it
    #
    method close_socket_and_reopen {} {
		close_socket
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

		set message(type) login

		foreach var "user password piaware_version image_type" globalVar "::flightaware_user ::flightaware_password ::piawareVersion ::imageType" {
			if {[info exists $globalVar]} {
				set message($var) [set $globalVar]
			}
		}

		catch {set message(uname) [exec /bin/uname --all]}

		if {[info exists ::netstatus(program_30005)]} {
			set message(adsbprogram) $::netstatus(program_30005)
		}

		if {[info exists ::netstatus(program_10001)]} {
			set message(transprogram) $::netstatus(program_10001)
		}

		set message(mac) [get_mac_address_or_quit]

		if {[get_default_gateway_interface_and_ip gateway iface ip]} {
			set message(local_ip) $ip
			set message(local_iface) $iface
		}

		send_array message
	}

	#
	# get_mac_address - return the mac address of eth0 as a unique handle
	#  to this device
	#
	method get_mac_address {} {
		set macFile /sys/class/net/eth0/address
		if {![file readable $macFile]} {
			set mac ""
		} else {
			set fp [open $macFile]
			gets $fp mac
			close $fp
		}
		return $mac
	}

	#
	# get_mac_address_or_quit - return the mac address of eth0 or if unable
	#  to, emit a message to stderr and exit
	#
	method get_mac_address_or_quit {} {
		set mac [get_mac_address]
		if {$mac == ""} {
			puts stderr "software failed to determine MAC address of the device.  cannot proceed without it."
			exit 6
		}
		return $mac
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
		if {[catch {puts $sock $text} catchResult] == 1} {
			logger "got '$catchResult' writing to FlightAware socket, reconnecting..."
			close_socket_and_reopen
		}
    }

	#
	# send_array - send an array as a message
	#
	method send_array {_row} {
		upvar $_row row

		set row(clock) [clock seconds]

		set message ""
		foreach field [lsort [array names row]] {
			append message "\t$field\t$row($field)"
		}

		send [string range $message 1 end]
	}

	#
	# schedule_writability_check - schedule periodically_check_writability
	#  to run one time after a delay
	#
	method schedule_writability_check {} {
		after 60000 [list $this periodically_check_writability]
	}

	#
	# periodically_check_writability - periodically see if the socket is
	#  writable
	#
	method periodically_check_writability {} {
		schedule_writability_check

		check_socket_writability
	}

	#
	# check_socket_writability - set up a timer and a writable file event.
	#  if we get the file event, the socket is writable.  if we get the
	#  timer event, it's dead.
	#
	method check_socket_writability {} {
		if {!$connected} {
			return
		}
		# create a timer event for a timeout and a writable file event.
		# if we get the file event callback then it's ok but if we get the
		# timer callback it isn't.
		set writabilityCheckAfterID [after 10000 [list $this writability_check_callback 0]]

		if {[catch {fileevent $sock writable [list $this writability_check_callback 1]} catchResult] == 1} {
			# failed to begin with, cancel the after script,
			# invoke the callback now, and we are done
			after cancel $writabilityCheckAfterID
			writability_check_callback 0
		}
		return
	}

	#
	# writability_check_callback
	#
	method writability_check_callback {state} {
		# if we got a fileevent callback, cancel the after time
		if {$state} {
			# success, we got called back by the writable event
			# cancel the timer event
			after cancel $writabilityCheckAfterID
		}

		# cancel the writable event either way but if it errors, force
		# state to not-writable
		if {[catch {fileevent $sock writable ""}] == 1} {
			set state 0
		}

		if {!$state} {
			logger "data isn't making it to FlightAware, reconnecting..."
			close_socket_and_reopen
		}
	}
}

#
# ca_crt_file - dig the location of the ca.crt file shipped inside the 
#  fa_adept_client package and return the path to the ca.crt file
#
proc ca_crt_file {} {
    set loadCommand [package ifneeded fa_adept_client [package require fa_adept_client]]

    if {![regexp {source (.*)} $loadCommand dummy path]} {
		error "software failure finding ca crt file"
    }

    return [file dir $path]/ca.crt
}

} ;# namespace fa_adept

package provide fa_adept_client 0.0

# vim: set ts=4 sw=4 sts=4 noet :

