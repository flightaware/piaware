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
	start_mlat_client
}

proc disable_mlat {} {
	if {$::mlatEnabled} {
		logger "multilateration data no longer required, disabling mlat client"
		set ::mlatEnabled 0
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
	unset ::mlatPipe
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
			logger "no ADS-B data program is serving on port 30005, not starting multilateration client yet"
			schedule_mlat_client_restart
			return
		}
	}

	set command $::mlatClientPath
	lappend command "--input-connect" "${::receiverHost}:${::receiverPort}"

	switch $::receiverType {
		rtlsdr {
			set inputType "dump1090"
		}

		beast - radarcape {
			set inputType $::receiverType
		}

		default {
			set inputType "auto"
		}
	}

	lappend command "--input-type" $inputType

	if {[piawareConfig get mlat-results]} {
		foreach r [piawareConfig get mlat-results-format] {
			lappend command "--results" $r
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

	fconfigure $mlatStdin -buffering line -blocking 0 -translation lf

	fconfigure $mlatStdout -buffering line -blocking 0 -translation lf
	fileevent $mlatStdout readable mlat_data_available

	log_subprocess_output "mlat-client($result)" $mlatStderr
	set ::mlatReady 0
	set ::mlatPipe [list $mlatStdout $mlatStdin]
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

	adept send_array row
}

# vim: set ts=4 sw=4 sts=4 noet :
