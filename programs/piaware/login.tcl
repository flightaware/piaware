# -*- mode: tcl; tab-width: 4; indent-tabs-mode: t -*-
#
# login.tcl - populates the adept login message with various bits of metadata
#
# Copyright (C) 2014-2016 FlightAware LLC, All Rights Reserved
#

package require fa_sudo

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
