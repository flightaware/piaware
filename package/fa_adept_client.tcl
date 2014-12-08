#
# fa_adept_client - Itcl class for connecting to and communicating with
#  an Open Aviation Data Exchange Protocol service
#
# Copyright (C) 2014 FlightAware LLC, All Rights Reserved
#
# open source in accordance with the Berkeley license
#

package require tls
package require Itcl

namespace eval ::fa_adept {

::itcl::class AdeptClient {
    public variable sock
    public variable host
    public variable hosts [list eyes.flightaware.com 70.42.6.203]
    public variable port 1200
    public variable connectRetryIntervalSeconds 60
    public variable connected 0
    public variable loggedIn 0
	public variable showTraffic 0

	protected variable writabilityCheckAfterID
    protected variable connectTimerID
	protected variable aliveTimerID
	protected variable nextHostIndex 0

    constructor {args} {
		configure {*}$args

		schedule_writability_check
    }

    #
    # logger - log a message
    #
    method logger {text} {
		# can also log $this
		::logger $text
    }

	#
	# next_host - return the next host in the list of hosts
	#
	method next_host {} {
		set host [lindex $hosts $nextHostIndex]
		incr nextHostIndex
		if {$nextHostIndex >= [llength $hosts]} {
			set nextHostIndex 0
		}
		return $host
	}

    #
    # tls_callback - routine called back during TLS negotiation
    #
    method tls_callback {args} {
		log_locally "tls_callback: $args"
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
		next_host

		# schedule a new connect attempt in the future
		# if we succeed to connect and login, we'll cancel this
		set connectTimerID [after [expr {round(($connectRetryIntervalSeconds * (1 + rand())) * 1000)}] $this connect]

		log_locally "connecting to FlightAware $host/$port"

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
			log_locally "got '$catchResult' to adept server at $host/$port, will try again soon..."
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
			log_locally "error during tls handshake: $catchResult, will try again soon..."
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
		log_locally "encrypted session established with FlightAware"

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

		log_locally "FlightAware server SSL certificate validated"
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
			log_locally "lost connection to FlightAware, reconnecting..."
			close_socket_and_reopen
			return
		}

		# get a line of data from the socket.  if we get an error, close the
		# socket and attempt to reopen
		if {[catch {set size [gets $sock line]} catchResult] == 1} {
			log_locally "got '$catchResult' reading FlightAware socket, reconnecting... "
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
			log_locally "malformed message from server ('$line'), disconnecting and reconnecting..."
			close_socket_and_reopen
			return
		}

		if {[catch {handle_response response} catchResult] == 1} {
			log_locally "error handling message '[string map {\n \\n \t \\t} $line]' from server ($catchResult), ([string map {\n \\n \t \\t} [string range $::errorInfo 0 1000]]), disconnecting and reconnecting..."
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

			"request_auto_update" {
				handle_update_request auto row
			}

			"request_manual_update" {
				handle_update_request manual row
			}

			default {
				log_locally "unrecognized message type '$row(type)' from server, ignoring..."
				incr ::nUnrecognizedServerMessages
				if {$::nUnrecognizedServerMessages > 20} {
					log_locally "that's too many, i'm disconnecting and reconnecting..."
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

			# if the login response contained a user, that's what we're
			# logged in as even if it's not what we might've said or
			# more likely we didn't say
			if {[info exists row(user)]} {
				set ::flightaware_user $row(user)
			}

			log_locally "logged in to FlightAware as user $::flightaware_user"
			cancel_connect_timer
		} else {
			# NB do more here, like UI stuff
			log_locally "*******************************************"
			log_locally "LOGIN FAILED: status '$row(status)': reason '$row(reason)'"
			log_locally "please correct this, possibly using piaware-config"
			log_locally "to set valid Flightaware user name and password."
			log_locally "piaware will now exit."
			log_locally "You can start it up again using 'sudo /etc/init.d/piaware start'"
			exit 4
		}
	}

	#
	# handle_notice_message - handle a notice message from the server
	#
	method handle_notice_message {_row} {
		upvar $_row row

		if {[info exists row(message)]} {
			log_locally "NOTICE from adept server: $row(message)"
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
		log_locally "NOTICE adept server is shutting down.  reason: $row(reason)"
	}

	#
	# update_check - see if the requested update type (manualUpdate or
	#   autoUpdate) is allowed.
	#
	#   you should be able to inspect this and handle_update_request
	#   and how they're invoked to assure yourself that if there is
	#   no autoUpdate or manualUpdate in /etc/piaware configured true
	#   or by piaware-config configured true, the update cannot occur.
	#
	method update_check {varName} {
		# if there is no matching update variable in the adept config or
		# a global variable set by /etc/piaware, bail
		if {![info exists ::adeptConfig($varName)] && ![info exists ::$varName]} {
			logger "$varName is not configured in /etc/piaware or by piaware-config"
			return 0
		}

		#
		# if there is a var in the adept config and it's not a boolean or
		# it's false, bail.
		#
		if {[info exists ::adeptConfig($varName)]} {
			if {![string is boolean $::adeptConfig($varName)]} {
				logger "$varName in adept config isn't a boolean, bailing on update request"
				return 0
			}

			if {!$::adeptConfig($varName)} {
				return 0
			} else {
				# the var is there and set to true, we proceed with the update
				logger "$varName in adept config is enabled, allowing update"
				return 1
			}
		}

		if {[info exists ::$varName]} {
			set val [set ::$varName]
			if {![string is boolean $val]} {
				logger "$varName in /etc/piaware isn't a boolean, bailing on update request"
				return 0
			} else {
				# the var is there and true, proceed
				logger "$varName in /etc/piaware is enabled, allowing update"
				return 1
			}
		}

		# this shouldn't happen
		error "software error in handle_shutdown_message"
	}

	#
	# handle_update_request - handle a message from the server requesting
	#   that we update the software
	#
	method handle_update_request {type _row} {
		upvar $_row row

		# force piaware config and adept config reload in case user changed
		# config since we last looked
		load_piaware_config
		load_adept_config

		switch $type {
			"auto" {
				logger "auto update (flightaware-initiated) requested by adept server"
			}

			"manual" {
				logger "manual update (user-initiated via their flightaware control page) requested by adept server"
			}

			default {
				logger "update request type must be 'auto' or 'manual', ignored..."
				return
			}
		}

		# see if we are allowed to do this
		if {![update_check ${type}Update]} {
			# no
			return
		}

		if {![info exists row(action)]} {
			error "no action specified in update request"
		}

		logger "performing $type update, action: $row(action)"

		set restartPiaware 0
		foreach action [split $row(action) " "] {
			switch $action {
				"full" {
					update_operating_system_and_packages
				}

				"packages" {
					upgrade_raspbian_packages
				}

				"piaware" {
					# only restart piaware if upgrade_piaware said it upgraded
					# successfully
					set restartPiaware [upgrade_piaware]
				}

				"restart_piaware" {
					set restartPiaware 1
				}

				"dump1090" {
					# try to upgrade dump1090 and if successful, restart it
					if {[upgrade_dump1090]} {
						attempt_dump1090_restart
					}
				}

				"restart_dump1090" {
					attempt_dump1090_restart
				}

				"reboot" {
					reboot
				}

				"halt" {
					halt
				}

				default {
					logger "unrecognized update action '$action', ignoring..."
				}
			}
		}

		logger "update request complete"

		if {$restartPiaware} {
			restart_piaware
		}
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
			log_locally "server is sending alive messages; we will expect them"
		} else {
			#log_locally "alive message received from FlightAware"
			cancel_alive_timer
		}

		# schedule alive_timeout to run in the future
		set aliveTimerID [after $afterMS [list $this alive_timeout]]
		#log_locally "handle_alive_message: alive timer ID is $aliveTimerID"
	}

	#
	# cancel_alive_timer - cancel the alive timer if it exists
	#
	method cancel_alive_timer {} {
		if {![info exists aliveTimerID]} {
			#log_locally "cancel_alive_timer: no extant timer ID, doing nothing..."
		} else {
			if {[catch {after cancel $aliveTimerID} catchResult] == 1} {
				#log_locally "cancel_alive_timer: cancel failed: $catchResult"
			} else {
				#log_locally "cancel_alive_timer: canceled $aliveTimerID"
			}
			unset aliveTimerID
		}
	}

	#
	# alive_timeout - this is called if the alive timer isn't canceled before
	#  it goes off
	#
	method alive_timeout {} {
		log_locally "timed out waiting for alive message from FlightAware, reconnecting..."
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
		log_locally "reconnecting after 60s..."
		after 60000 [list adept connect]
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

		# construct some key-value pairs to be included.
		#
		# note that there are two possible sources for piaware_version_full.
		# the last one found will be used.
		#
		foreach var "user password piaware_version image_type piaware_version_full piaware_version_full" globalVar "::flightaware_user ::flightaware_password ::piawareVersion ::imageType ::piawareVersionFull ::fullVersionID" {
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

		set message(local_auto_update_enable) [update_check autoUpdate]
		set message(local_manual_update_enable) [update_check manualUpdate]

		send_array message
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
		set message(mac) [get_mac_address_or_quit]

		foreach var "user" globalVar "::flightaware_user" {
			if {[info exists $globalVar]} {
				set message($var) [set $globalVar]
			}
		}

		send_array message
	}


	#
	# get_mac_address - return the mac address of eth0 as a unique handle
	#  to this device.
	#
	#  if there is no eth0 tries to find another mac address to use that it
	#  can hopefully repeatably find in the future
	#
	#  if we can't find any mac address at all then return an empty string
	#
	method get_mac_address {} {
		if {[info exists ::macAddress]} {
			return $::macAddress
		}

		set macFile /sys/class/net/eth0/address
		if {[file readable $macFile]} {
			set fp [open $macFile]
			gets $fp mac
			set ::macAddress $mac
			close $fp
			return $mac
		}

		# well, that didn't work, look at the entire output of ifconfig
		# for a MAC address and use the first one we find

		if {[catch {set fp [open "|ifconfig"]} catchResult] == 1} {
			puts stderr "ifconfig command not found on this version of Linux, you may need to install the net-tools package and try again"
			return ""
		}

		set mac ""
		while {[gets $fp line] >= 0} {
			set mac [::fa_adept::parse_mac_address_from_line $line]
			set device ""
			regexp {^([^ ]*)} $line dummy device
			if {$mac != ""} {
				# gotcha
				set ::macAddress $mac
				log_locally "no eth0 device, using $mac from device '$device'"
				break
			}
		}

		catch {close $fp}
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
		if {$showTraffic} {
			puts "> $text"
		}

		if {[catch {puts $sock $text} catchResult] == 1} {
			log_locally "got '$catchResult' writing to FlightAware socket, reconnecting..."
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
			log_locally "data isn't making it to FlightAware, reconnecting..."
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

#
# parse_mac_address_from_line - find a mac address free-from in a line and
#   return it or return the empty string
#
proc parse_mac_address_from_line {line} {
	if {[regexp {(([0-9a-fA-F]{2}[:-]){5}([0-9a-fA-F]{2}))} $line dummy mac]} {
		return $mac
	}
	return ""
}

} ;# namespace fa_adept

package provide fa_adept_client 0.0

# vim: set ts=4 sw=4 sts=4 noet :

