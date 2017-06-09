# -*- mode: tcl; tab-width: 4; indent-tabs-mode: t -*-
#
# login.tcl - populates the adept login message with various bits of metadata
#
# Copyright (C) 2014-2016 FlightAware LLC, All Rights Reserved
#

package require fa_sudo
package require tryfinallyshim

# populates the initial login message
proc gather_login_info {_message} {
	upvar $_message message

	# message type, mac are already populated by the adept client

	# refresh everything so we're up to date
	reread_piaware_config
	inspect_sockets_with_netstat

	# construct some key-value pairs to be included.
	catch {set message(uname) [::fa_sudo::exec_as /bin/uname --all]}

	# from config.tcl
	set message(piaware_version) $::piawareVersion
	set message(piaware_version_full) $::piawareVersionFull

	foreach {packageName packageVersion} [query_dpkg_names_and_versions "*piaware*"] {
		switch -glob -- $packageName {
			"piaware-release" - "piaware-support" - "piaware-repository*" {
				# ignore
			}

			"piaware" {
				# exact match, override any fuzzy match earlier
				set message(piaware_package_version) $packageVersion
				set message(image_type) "${packageName}_package"
				break
			}

			default {
				# fuzzy match, only use if not already set
				if {![info exists message(piaware_package_version)]} {
					set message(piaware_package_version) $packageVersion
					set message(image_type) "${packageName}_package"
				}
			}
		}
	}

	set message(dump1090_packages) [query_dpkg_names_and_versions "*dump1090*"]

	if {[info exists ::netstatus(program_30005)]} {
		set message(adsbprogram) $::netstatus(program_30005)
	}

	set message(transprogram) "faup1090"

	catch {
		if {[::fa_sysinfo::route_to_flightaware gateway iface ip]} {
			set message(local_ip) $ip
			set message(local_iface) $iface
		}
	}

	catch {
		array set rel [::fa_sysinfo::os_release_info]
		foreach {k1 k2} {ID os_id VERSION_ID os_version_id VERSION os_version} {
			if {[info exists rel($k1)]} {
				set message($k2) $rel($k1)
			}
		}
	}

	set feederId [read_feeder_id]
	if {$feederId ne ""} {
		set message(feeder_id) $feederId
	}

	set message(local_auto_update_enable) [piawareConfig get allow-auto-updates]
	set message(local_manual_update_enable) [piawareConfig get allow-manual-updates]
	set message(local_mlat_enable) [piawareConfig get allow-mlat]

	foreach {msgVar configKey} {
		user flightaware-user
		password flightaware-password
		image_type image-type
		local_auto_update_enable allow-auto-updates
		local_manual_update_enable allow-manual-updates
		local_mlat_enable allow-mlat
		forced_mac force-macaddress
	} {
		if {[piawareConfig exists $configKey]} {
			set message($msgVar) [piawareConfig get $configKey]
		}
	}
}

proc handle_login_result {data} {
	array set row $data

	if {$row(status) == "ok"} {
		logger "logged in to FlightAware as user $row(user)"
		set ::loggedInUser $row(user)

		if {[info exists row(feeder_id)]} {
			logger "my feeder ID is $row(feeder_id)"
			set ::feederID $row(feeder_id)
			write_feeder_id $row(feeder_id)
		} else {
			unset -nocomplain ::feederID
		}

		if {[info exists row(site_url)]} {
			logger "site statistics URL: $row(site_url)"
			set ::siteURL $row(site_url)
		} else {
			unset -nocomplain ::siteURL
		}
	} else {
		# NB do more here, like UI stuff
		log_locally "*******************************************"
		log_locally "LOGIN FAILED: status '$row(status)': reason '$row(reason)'"
		log_locally "please correct this, possibly using piaware-config"
		log_locally "to set valid Flightaware user name and password."
		log_locally "piaware will now exit."
		log_locally "You can start it up again using 'sudo service piaware start'"
		exit 4
	}
}

proc read_feeder_id {} {
	if {[piawareConfig exists feeder-id]} {
		return [list "config" [piawareConfig get feeder-id]]
	}

	if {$::params(cachedir) eq ""} {
		return [list "none" ""]
	}

	set path "$::params(cachedir)/feeder_id"
	set id ""
	catch {
		set f [open $path "r"]
		try {
		    gets $f id
		} finally {
		    close $f
		}
	}

	# only return this as "cache" if we can actually update it
	if {![create_cache_dir] || ![file writable $::params(cachedir)] || ([file exists $path] && ![file writable $path])} {
		return [list "cache_ro" $id]
	} else {
		return [list "cache" $id]
	}
}

proc write_feeder_id {id} {
	if {$::params(cachedir) eq ""} {
		return
	}

	set path "$::params(cachedir)/feeder_id"
	if {[catch {
		create_cache_dir
		set f [open "$path.new" "w"]
		try {
			puts $f $id
		} finally {
			close $f
		}

		file rename -force -- "$path.new" $path
	} result]} {
		logger "Failed to update feeder ID file at $path: $result"
	}
}
