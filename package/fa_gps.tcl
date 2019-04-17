# -*- mode: tcl; tab-width: 4; indent-tabs-mode: t -*-
#
# gps - Itcl class for talking to gpsd for position information
#
# Copyright (C) 2015 FlightAware LLC, All Rights Reserved
#
# open source in accordance with the Berkeley license
#

package require Itcl 3.4
package require json

namespace eval ::fa_gps {
	::itcl::class GpsdClient {
		public variable host "localhost"
		public variable port 2947
		public variable callback
		public variable reconnectInterval 120000

		# last seen position
		public variable lat ""
		public variable lon ""
		public variable alt ""

		protected variable sock
		protected variable connected 0
		protected variable reconnectTimerID

		constructor {args} {
			configure {*}$args
		}

		method debug {msg} {
			::debug "GPS: $this: $msg"
		}

		method logger {msg} {
			::logger "GPS: $msg"
		}

		#
		# connect - start trying to connect
		#   will generate callbacks if it gets a connection,
		#   otherwise it is pretty silent
		#
		method connect {} {
			# close the connection if already connected and cancel the reconnect
			# event timer if there is one
			close_socket
			cancel_timers

			# start the connection attempt
			if {[catch {set sock [socket -async $host $port]} catchResult]} {
				# nope, we will retry
				debug "could not connect to gpsd at $host/$port: $catchResult"
				close_socket_and_reopen
				return
			}

			# wait for the connect to finish
			fileevent $sock writable [list $this _connect_completed]
			return 1
		}

		method _connect_completed {} {
			debug "connect_completed"

			if {![info exists sock]} {
				# we raced with a close for some other reason
				return
			}

			# turn off the writability check now
			fileevent $sock writable ""

			set error [fconfigure $sock -error]
			if {$error ne ""} {
				# nope.
				debug "connection to gpsd at $host/$port failed: $error"
				close_socket_and_reopen
				return
			}

			debug "connection established to gpsd at $host/$port"

			fconfigure $sock -buffering line -blocking 0 -encoding ascii -translation lf
			fileevent $sock readable [list $this _data_available]
		}

		method _data_available {} {
			debug "data_available"

			if {![info exists sock]} {
				debug "sock closed under us"
				return
			}

			# if end of file on the socket, close the socket and attempt to reopen
			if {[eof $sock]} {
				logger "Lost connection to gpsd at $host/$port: server closed connection"
				close_socket_and_reopen
				return
			}

			# get a line of data from the socket.  if we get an error, close the
			# socket and attempt to reopen
			if {[catch {set size [gets $sock line]} catchResult] == 1} {
				logger "Lost connection to gpsd at $host/$port: $catchResult"
				close_socket_and_reopen
				return
			}

			#
			# sometimes you get a callback with no data, that's OK but there's nothing to do
			#
			if {$size < 0} {
				debug "gets returned $size, no data yet"
				return
			}

			debug "received line: $line"

			# parse it as json
			if {[catch {set j [::json::json2dict $line]} catchResult] == 1} {
				logger "Malformed line from gpsd, reconnecting: $catchResult"
				close_socket_and_reopen
				return
			}

			if {[catch {handle_message $j} catchResult] == 1} {
				logger "Got '$catchResult' handling a message from gpsd: $::errorInfo"
				close_socket_and_reopen
				return
			}
		}

		protected method handle_message {_j} {
			debug "handle_message: $_j"

			# add j_ to all keys so they don't collide with any other vars
			set j [dict create]
			dict for {k v} $_j {
				dict set j j_$k $v
			}

			dict with j {
				if {![info exists j_class]} {
					debug "no 'class' key, skipping message"
					return
				}

				switch -exact $j_class {
					"VERSION" {
						# we get this on initial connect
						# send a ?WATCH command to request data
						logger "Connected to gpsd $j_release at $host/$port"
						set connected 1
						puts $sock {?WATCH={"enable":true,"json":true};}
					}

					"TPV" {
						# we want this!
						debug "processing TPV"
						switch -exact $j_mode {
							"0" - "1" {
								debug "no fix"
								set lat ""
								set lon ""
								set alt ""
							}

							"2" {
								if {[info exists j_lat] && [info exists j_lon]} {
									debug "2D fix at $j_lat $j_lon"
									set lat $j_lat
									set lon $j_lon
									set alt ""
								}
							}

							"3" {
								if {[info exists j_lat] && [info exists j_lon] && [info exists j_alt]} {
									debug "3D fix at $j_lat $j_lon $j_alt"
									set lat $j_lat
									set lon $j_lon
									set alt $j_alt
								}
							}

							default {
								debug "didn't understand that TPV message"
							}
						}

						do_callback
					}

					default {
						debug "skipping message with class $j_class"
					}
				}
			}
		}

		method close {} {
			close_socket
			cancel_timers
		}

		protected method close_socket {} {
			if {[info exists sock]} {
				catch {::close $sock} catchResult
				unset sock
			}
			set connected 0
		}

		protected method cancel_timers {} {
			if {[info exists reconnectTimerID]} {
				after cancel $reconnectTimerID
				unset reconnectTimerID
			}
		}

		protected method close_socket_and_reopen {} {
			set wasConnected $connected

			debug "closing gpsd socket, scheduling reconnect"

			# reset position
			set lat ""
			set lon ""
			set alt ""

			close_socket
			cancel_timers
			set reconnectTimerID [after $reconnectInterval [list $this connect]]

			# tell the callback we lost the gps
			if {$wasConnected} {
				do_callback
			}
		}

		method is_connected {} {
			return $connected
		}

		protected method do_callback {} {
			if {![info exists callback]} {
				return
			}

			if {[catch {{*}$callback $lat $lon $alt} catchResult] == 1} {
				logger "error invoking position callback: $catchResult: $::errorInfo"
			}
		}
	}

} ;# namespace fa_gps

package provide fa_gps 0.0

# vim: set ts=4 sw=4 sts=4 noet :
