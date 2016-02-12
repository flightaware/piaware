#
# piaware - status file creation
#
# Copyright (C) 2016 FlightAware LLC, All Rights Reserved
#

package require json::write
package require tryfinallyshim

set ::statusFileInterval 5000

proc periodically_update_status_file {} {
	if {$::params(statusfile) ne ""} {
		after $::statusFileInterval update_status_file
	}
}

proc update_status_file {} {
	periodically_update_status_file

	if {[catch {write_status_file} result]} {
		logger "failed to write status file: $result"
		logger "traceback: $::errorInfo"
	}
}

proc write_status_file {} {
	set contents [build_status]
	set newfile "${::params(statusfile)}.new"

	try {
		set f [open $newfile "w"]
		puts $f $contents
		close $f
		unset f

		file rename -force -- $newfile $::params(statusfile)
		unset newfile
	} finally {
		if {[info exists f]} {
			close $f
		}

		if {[info exists newfile]} {
			file delete -- $newfile
		}
	}
}

proc status_entry {color message} {
	set data(status) [::json::write string $color]
	set data(message) [::json::write string $message]
	return [::json::write object {*}[array get data]]
}

proc build_status {} {
	set data(time) [clock milliseconds]
	set data(interval) $::statusFileInterval
	set data(expiry) [expr {$data(time) + $::statusFileInterval * 2 + 1000}]

	# piaware: our own health
	set data(piaware) [status_entry "green" "Piaware $::piawareVersionFull is running"]

	# adept: status of the connection to the adept server
	if {[adept is_logged_in]} {
		set data(adept) [status_entry "green" "Connected to FlightAware and logged in"]
	} elseif {[adept is_connected]} {
		set data(adept) [status_entry "amber" "Connected to FlightAware, but not logged in"]
	} else {
		set data(adept) [status_entry "red" "Not connected to FlightAware"]
	}

	# radio: status of the connection to the receiver process
	if {[info exists ::faupPid]} {
		if {([clock seconds] - $::lastFaupMessageClock) < 60} {
			set data(radio) [status_entry "green" "Received Mode S data recently"]
		} else {
			set data(radio) [status_entry "amber" "Connected to receiver, but no recent data seen"]
		}
	} else {
		set data(radio) [status_entry "red" "Not connected to receiver"]
	}

	# mlat: status of mlat
	if {!$::mlatEnabled} {
		set data(mlat) [status_entry "red" "Multilateration not enabled"]
	} elseif {!$::mlatReady} {
		set data(mlat) [status_entry "red" "Multilateration enabled, but client not running"]
	} else {
		# TODO: should work out if it's actually working
		# by looking for server status messages
		set data(mlat) [status_entry "green" "Multilateration enabled"]
	}

	return [::json::write object {*}[array get data]]
}
