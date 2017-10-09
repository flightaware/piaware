# -*- mode: tcl; tab-width: 4; indent-tabs-mode: t -*-

# piaware - multilateration client handling
# This bridges multilateration messages between a
# mlat-client subprocess and the adept server.

package require fa_sudo

# does the server want mlat data?
set ::mlatEnabled 0
# is our client ready for data?
set ::mlatReady 0
# interval between client restarts
set ::mlatRestartMillis 60000
# UDP transport info
set ::mlatUdpTransport {}
# path to fa-mlat-client
set ::mlatClientPath [auto_execok "/usr/lib/piaware/helpers/fa-mlat-client"]
# current mlat status for the statusfile, one of:
#   not_enabled
#   not_running
#   initializing
#   or a status value returned by the server (ok / no_sync / unstable)
set ::mlatStatus "not_enabled"

proc mlat_is_configured {} {
	if {![piawareConfig get allow-mlat]} {
		logger "multilateration support disabled by local configuration ([piawareConfig origin allow-mlat])"
		return 0
	}

	# check for existence of fa-mlat-client
	if {$::mlatClientPath eq ""} {
		logger "multilateration support disabled (no fa-mlat-client found)"
		return 0
	}

	# all ok
	return 1
}

proc enable_mlat {udp_transport} {
	logger "multilateration data requested"

	if {![mlat_is_configured]} {
		return
	}

	if {$::mlatEnabled} {
		# already enabled
		return
	}

	set ::mlatEnabled 1
	set ::mlatUdpTransport $udp_transport
	set ::mlatStatus "not_running"
	start_mlat_client
}

proc disable_mlat {} {
	if {$::mlatEnabled} {
		logger "multilateration data no longer required, disabling mlat client"
		set ::mlatEnabled 0
		set ::mlatStatus "not_enabled"
		close_mlat_client
		if {[info exists ::mlatRestartTimer]} {
			catch {after cancel $::mlatRestartTimer}
			unset ::mlatRestartTimer
		}
	}
}

proc close_mlat_client {} {
	if {![info exists ::mlatPipe]} {
		return
	}

	if ($::mlatReady) {
		set message(type) mlat_event
		set message(event) notready
		adept send_array message
	}

	set ::mlatReady 0
	lassign $::mlatPipe mlatRead mlatWrite
	catch {close $mlatRead}
	catch {close $mlatWrite}

	catch {
		lassign [timed_waitpid 15000 $::mlatPid] deadpid why code
		if {$code ne "0"} {
			logger "fa-mlat-client exited with $why $code"
		} else {
			logger "fa-mlat-client exited normally"
		}
	}

	unset ::mlatPid
	unset ::mlatPipe
	set ::mlatStatus "not_running"
}

proc start_mlat_client {} {
	if {[info exists ::mlatRestartTimer]} {
		after cancel $::mlatRestartTimer
		unset ::mlatRestartTimer
	}

	if {!$::mlatEnabled} {
		return
	}

	if {[info exists ::mlatPipe]} {
		return
	}

	if {[is_local_receiver]} {
		inspect_sockets_with_netstat

		if {![is_adsb_program_running]} {
			logger "no ADS-B data program is serving on port $::adsbLocalPort, not starting multilateration client yet"
			schedule_mlat_client_restart
			return
		}
	}

	set command $::mlatClientPath
	lappend command "--input-connect" "${::receiverHost}:${::receiverPort}"
	lappend command "--input-type" $::receiverDataFormat

	if {[piawareConfig get mlat-results]} {
		foreach r [piawareConfig get mlat-results-format] {
			lappend command "--results" $r
		}

		if {![piawareConfig get mlat-results-anon]} {
			lappend command "--no-anon-results"
		}

		if {![piawareConfig get allow-modeac]} {
			lappend command "--no-modeac-results"
		}
	}

	if {$::mlatUdpTransport ne ""} {
		lassign $::mlatUdpTransport udp_host udp_port udp_key
		lappend command "--udp-transport" "$udp_host:$udp_port:$udp_key"
	}

	logger "Starting multilateration client: $command"

	if {[catch {::fa_sudo::popen_as -noroot -stdin mlatStdin -stdout mlatStdout -stderr mlatStderr {*}$command} result]} {
		logger "got '$result' starting multilateration client"
		schedule_mlat_client_restart
		return
	}

	if {$result == 0} {
		logger "could not start multilateration client: sudo refused to start the command"
		schedule_mlat_client_restart
		return
	}

	fconfigure $mlatStdin -buffering line -blocking 0 -translation lf

	fconfigure $mlatStdout -buffering line -blocking 0 -translation lf
	fileevent $mlatStdout readable mlat_data_available

	log_subprocess_output "mlat-client($result)" $mlatStderr
	set ::mlatReady 0
	set ::mlatPipe [list $mlatStdout $mlatStdin]
	set ::mlatPid $result
	set ::mlatStatus "initializing"
}


proc schedule_mlat_client_restart {} {
	if [info exists ::mlatRestartTimer] {
		after cancel $::mlatRestartTimer
	}
	set ::mlatRestartTimer [after $::mlatRestartMillis start_mlat_client]
}

proc close_and_restart_mlat_client {} {
	close_mlat_client
	schedule_mlat_client_restart
}

proc forward_to_mlat_client {_row} {
	upvar $_row row

	# handle messages intended for piaware
	switch -exact $row(type) {
		"mlat_enable" {
			if {[info exists row(udp_transport)]} {
				enable_mlat $row(udp_transport)
			} else {
				enable_mlat {}
			}
			return
		}

		"mlat_disable" {
			disable_mlat
			return
		}

		"mlat_result" {
			# remember we got a mlat result for this hexid
			# so we can filter any spurious looped-back results
			# for a while
			set ::mlatSawResult($row(hexid)) [clock seconds]
		}

		"mlat_status" {
			# monitor this for the status file
			set ::mlatStatus $row(status)
		}
	}

	# anything else goes to the client

	if {! $::mlatReady} {
		return
	}

	set message ""
	foreach field [lsort [array names row]] {
		append message "\t$field\t$row($field)"
	}

	set message [string range $message 1 end]

	lassign $::mlatPipe mlatRead mlatWrite
	if {[catch {puts $mlatWrite $message} catchResult] == 1} {
		logger "got '$catchResult' writing to multilateration client, restarting.."
		close_and_restart_mlat_client
		return
	}

	# also forward results to pirehose, if enabled
	if {$row(type) eq "mlat_result"} {
		forward_to_pirehose $message
	}
}

proc mlat_data_available {} {
	lassign $::mlatPipe mlatRead mlatWrite

	if ([eof $mlatRead]) {
		logger "got EOF from multilateration client"
		close_and_restart_mlat_client
		return
	}

	if {[catch {set size [gets $mlatRead line]} catchResult] == 1} {
		logger "got '$catchResult' reading from multilateration client, restarting.."
		close_and_restart_mlat_client
		return
	}

	if {$size < 0} {
		# don't have a full line yet
		return
	}

	if {[catch {array set message [split $line "\t"]}] == 1} {
		logger "Malformed message from multilateration client ('$line'), restarting.."
		close_and_restart_mlat_client
		return
	}

	if {[catch {process_mlat_message message}] == 1} {
		logger "error handling message '[string map {\n \\n \t \\t} $line]' from multilateration client ($catchResult), restarting client.."
		logger "traceback: [string range $::errorInfo 0 1000]"
		close_and_restart_mlat_client
		return
	}
}

proc process_mlat_message {_row} {
	upvar $_row row

	if {$row(type) eq "mlat_event" && $row(event) eq "ready"} {
		set ::mlatReady 1
	}

	if {$row(type) eq "mlat_location_update" } {
		# turn this into a local location update,
		# we will then tell adept as needed,
		# don't forward to mlat servers directly
		handle_location_update "mlat" $row(lat) $row(lon) $row(alt) $row(altref)
		return
	}

	adept send_array row
}

# vim: set ts=4 sw=4 sts=4 noet :
