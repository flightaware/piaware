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
	} elseif {[info exists ::feederID] && [info exists ::loggedInUser]} {
		set data(feeder_id) [::json::write string $::feederID]
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

	# 1090 status
	if {[receiver_enabled piawareConfig ES]} {
		set data(modes_enabled) true

		# radio: status of the connection to the Mode S receiver process
		if {[info exists ::faup1090] && [$::faup1090 is_connected]} {
			if {([clock seconds] - [$::faup1090 last_message_received]) < 60} {
				set data(radio) [status_entry "green" "Received Mode S data recently"]
			} else {
				set data(radio) [status_entry "amber" "Connected to Mode S receiver, but no recent data seen"]
			}
		} else {
			set data(radio) [status_entry "red" "Not connected to Mode S receiver"]
		}

		# mlat: status of mlat; only show if 1090 mode is enabled
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
	} else {
		# No Mode S configured
		set data(modes_enabled) false
	}

	# 978 status
	if {[receiver_enabled piawareConfig UAT]} {
		set data(uat_enabled) true

		# uat_radio: status of the connection to the UAT receiver process
		if {[info exists ::faup978] && [$::faup978 is_connected]} {
			if {([clock seconds] - [$::faup978 last_message_received]) < 60} {
				set data(uat_radio) [status_entry "green" "Received UAT data recently"]
			} else {
				set data(uat_radio) [status_entry "amber" "Connected to UAT receiver, but no recent data seen"]
			}
		} else {
			set data(uat_radio) [status_entry "red" "Not connected to UAT receiver"]
		}
	} else {
		# No UAT configured
		set data(uat_enabled) false
	}

	# Complain if neither radio is enabled
	if {![receiver_enabled piawareConfig ES] && ![receiver_enabled piawareConfig UAT]} {
		set data(no_radio) [status_entry "red" "No receivers configured"]
	}

	# gps: GPS fix status
	# only report this if we actually got a gpsd connection at least,
	# as most installs won't have GPS.
	if {[info exists ::gpsd] && [$::gpsd is_connected]} {
		if {[info exists ::locationData(gpsd)]} {
			lassign $::locationData(gpsd) lat lon alt altref
			set data(gps) [status_entry "green" [format "GPS 3D fix at %.3f,%.3f" $lat $lon]]
		} else {
			set data(gps) [status_entry "red" "GPS position information not available"]
		}
	}

	# System information
	catch {set data(piaware_version) [::json::write string $::piawareVersionFull]}
	set dump1090_version [query_dpkg_names_and_versions "*dump1090-fa*"]
	catch {set data(dump1090_version) [::json::write string $dump1090_version]}
	catch {set data(cpu_temp_celcius) [::fa_sysinfo::cpu_temperature]}
	catch {set data(cpu_load_percent) [::fa_sysinfo::cpu_load]}
	catch {set data(system_uptime) [::fa_sysinfo::uptime]}

	return [::json::write object {*}[array get data]]
}
