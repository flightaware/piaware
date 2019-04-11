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
		try {
			close $f
		} finally {
			unset f
		}

		file rename -force -- $newfile $::params(statusfile)
		unset newfile
	} finally {
		if {[info exists f]} {
			catch {close $f}
		}

		if {[info exists newfile]} {
			catch {file delete -- $newfile}
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

	# site URL, if available
	if {[info exists ::siteURL]} {
		set data(site_url) [::json::write string $::siteURL]
	}

	# site UUID, if unclaimed
	if {[info exists ::feederID] && [info exists ::loggedInUser] && $::loggedInUser eq "guest"} {
		set data(unclaimed_feeder_id) [::json::write string $::feederID]
	}

	# piaware: our own health
	set data(piaware) [status_entry "green" "PiAware $::piawareVersionFull is running"]

	# adept: status of the connection to the adept server
	if {[adept is_logged_in]} {
		set data(adept) [status_entry "green" "Connected to FlightAware and logged in"]
	} elseif {[adept is_connected]} {
		set data(adept) [status_entry "amber" "Connected to FlightAware, but not logged in"]
	} else {
		set data(adept) [status_entry "red" "Not connected to FlightAware"]
	}

	# radio: status of the connection to the receiver process
	array set reasons {}
	foreach {faupvar name} {::faup1090 "Mode S" ::faup978 "UAT"} {
		if {![info exists $faupvar]} {
			continue
		}

		set faup [set $faupvar]
		if {[$faup is_connected]} {
			if {([clock seconds] - [$faup last_message_received]) < 60} {
				lappend reasons(green) "Received $name data recently"
			} else {
				lappend reasons(amber) "Connected to $name receiver, but no recent data seen"
			}
		} else {
			lappend reasons(red) "Not connected to $name receiver"
		}
	}

	foreach status {red amber green} {
		if {[info exists reasons($status)]} {
			set data(radio) [status_entry $status [join $reasons($status) "; "]]
			break
		}
	}
	if {![info exists data(radio)]} {
		set data(radio) [status_entry "red" "No receivers configured"]
	}

	# adsb program enabled status
	foreach {program name} {::faup1090 "MODES_enabled" ::faup978 "UAT_enabled"} {
		# set enabled to true if connected to receiver
		if {[info exists $program] && [$program is_connected]} {
			set data($name) true
		} else {
			set data($name) false
		}
	}

	# mlat: status of mlat
	switch $::mlatStatus {
		not_enabled {
			set data(mlat) [status_entry "red" "Multilateration is not enabled"]
		}

		not_running {
			set data(mlat) [status_entry "red" "Multilateration enabled, but client is not running"]
		}

		initializing {
			set data(mlat) [status_entry "amber" "Multilateration initializing"]
		}

		no_sync {
			set data(mlat) [status_entry "amber" "No clock synchronization with nearby receivers"]
		}

		unstable {
			set data(mlat) [status_entry "amber" "Local clock source is unstable"]
		}

		ok {
			set data(mlat) [status_entry "green" "Multilateration synchronized"]
		}

		default {
			set data(mlat) [status_entry "amber" "Unexpected multilateration status $::mlatStatus, please report this"]
		}
	}

	# gps: GPS fix status
	# only report this if we actually got a gpsd connection at least,
	# as most installs won't have GPS.
	if {[info exists gpsd] && [gpsd is_connected]} {
		if {[info exists ::locationData(gpsd)]} {
			lassign $::locationData(gpsd) lat lon alt altref
			set data(gps) [status_entry "green" [format "GPS 3D fix at %.3f,%.3f" $lat $lon]]
		} else {
			set data(gps) [status_entry "red" "GPS position information not available"]
		}
	}

	return [::json::write object {*}[array get data]]
}
