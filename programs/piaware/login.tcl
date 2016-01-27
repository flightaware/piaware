# -*- mode: tcl; tab-width: 4; indent-tabs-mode: t -*-
#
# login.tcl - populates the adept login message with various bits of metadata
#
# Copyright (C) 2014-2016 FlightAware LLC, All Rights Reserved
#

# populates the initial login message
proc gather_login_info {_message} {
	upvar $_message message

	# message type, mac are already populated by the adept client

	# refresh everything so we're up to date
	reread_piaware_config
	inspect_sockets_with_netstat

	# construct some key-value pairs to be included.
	catch {set message(uname) [exec /bin/uname --all]}

	# from config.tcl
	set message(piaware_version) $::piawareVersion
	set message(piaware_version_full) $::piawareVersionFull

	set res [query_dpkg_names_and_versions "*piaware*"]
	if {[llength $res] == 2} {
		# only if it's unambiguous
		lassign $res packageName packageVersion
		set message(piaware_package_version) $packageVersion
		set message(image_type) "${packageName}_package"
	}

	set message(dump1090_packages) [query_dpkg_names_and_versions "*dump1090*"]

	if {[info exists ::netstatus(program_30005)]} {
		set message(adsbprogram) $::netstatus(program_30005)
	}

	set message(transprogram) "faup1090"

	catch {
		if {[get_default_gateway_interface_and_ip gateway iface ip]} {
			set message(local_ip) $ip
			set message(local_iface) $iface
		}
	}

	catch {
		get_os_release rel
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
	} {
		if {[piawareConfig exists $configKey]} {
			set message($msgVar) [piawareConfig get $configKey]
		}
	}
}
