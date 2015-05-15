# -*- mode: tcl; tab-width: 4; indent-tabs-mode: t -*-

# piaware - multilateration client handling
# This bridges multilateration messages between a
# mlat-client subprocess and the adept server.

set ::mlatWanted 0
set ::mlatLoggedIn 0
set ::mlatRestartMillis 60000

proc mlat_is_configured{} {
    if {![info exists ::adeptConfig(mlat)]} {
		return 0
	}

	if {![string is boolean $::adeptConfig(mlat)]} {
		return 0
	}

	if {$::adeptConfig(mlat)} {
		return 1
	} else {
		return 0
	}
}

proc start_providing_mlat {} {
	if {![mlat_is_configured]} {
		logger "Ignoring request for multilateration data - disabled or missing from config file"
		return
	}

	if {$::mlatWanted} {
		# already enabled
		return
	}

	logger "enabling multilateration client.."
	set ::mlatWanted 1
	start_mlat_client
}

proc stop_providing_mlat {} {
	set ::mlatWanted 0
	close_mlat
	if {[info exists ::mlatRestartTimer]} {
		catch {after cancel $::mlatRestartTimer}
		unset ::mlatRestartTimer
	}
}

proc close_mlat_client {} {
	if ($::mlatLoggedIn) {
		set message(type) mlat_logout
		adept send_array message
	}

	set ::mlatLoggedIn 0
	catch {close $::mlatPipe}
	unset ::mlatPipe
	reap_any_dead_children
}

proc start_mlat_client {} {
	unset -nocomplain ::mlatRestartTimer

	if {!$::mlatWanted} {
		return
	}

	if {[info exists ::mlatPipe]} {
		return
	}

	inspect_sockets_with_netstat

	if {![is_adsb_program_running]} {
		logger "no ADS-B data program is serving on port 30005, not starting multilateration client yet"
		schedule_mlat_client_restart
		return
	}

	set ::mlatPipe [open "|fa-mlat-client --input-host localhost --input-port 30005" r+]
	set ::mlatLoggedIn 0
	fconfigure $::mlatPipe -buffering line -blocking 0 -translation binary
	fileevent $::mlatPipe readable mlat_data_available
}

proc schedule_mlat_client_restart {} {
	set ::mlatRestartTimer [after $::mlatRestartMillis start_mlat_client]
}

proc close_and_restart_mlat_client {} {
	close_mlat_client
	schedule_mlat_client_restart
}

proc forward_to_mlat_client {_row} {
	if {! $::mlatLoggedIn} {
		return
	}

	upvar $_row row

	set message ""
	foreach field [lsort [array names row]] {
		append message "\t$field\t$row($field)"
	}

	set message [string range $message 1 end]
	if {[catch {puts $::mlatPipe $message} catchResult] == 1} {
		logger "got '$catchResult' writing to multilateration client, restarting.."
		close_and_restart_mlat_client
		return
	}
}

proc mlat_data_available {} {
	if ([eof $::mlatPipe]) {
		logger "got EOF from multilateration client"
		close_and_restart_mlat_client
		return
	}

	if {[catch {set size [gets $::mlatPipe line]} catchResult] == 1} {
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
		logger "error handling message '[string map {\n \\n \t \\t} $line]' from multilateration client ($catchResult), ([string map {\n \\n \t \\t} [string range $::errorInfo 0 1000]]), restarting.."
		close_and_restart_mlat_client
		return
	}
}

proc process_mlat_message {_row} {
	upvar $_row row

	if {$::mlatLoggedIn} {
		adept send_array row
		return
	}

	# not started yet
	# wait for mlat_event / connected then tell adept everything is go
	if {$message(type) == "mlat_event" && $message(event) == "connected"} {
		logger "multilateration client successfully connected to ADS-B producer"
		set login(type) mlat_login
		adept send_array login
		set ::mlatLoggedIn 1
		adept send_array row
	}
}
