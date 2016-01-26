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

	# construct some key-value pairs to be included.
	foreach var "user password image_type piaware_version piaware_version_full piaware_package_version dump1090_packages" globalVar "::flightaware_user ::flightaware_password ::imageType ::piawareVersion ::piawareVersionFull ::piawarePackageVersion ::dump1090Packages" {
		if {[info exists $globalVar] && [set $globalVar] ne ""} {
			set message($var) [set $globalVar]
		}
	}

	catch {set message(uname) [exec /bin/uname --all]}

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

	set message(local_auto_update_enable) [update_check autoUpdate]
	set message(local_manual_update_enable) [update_check manualUpdate]
	set message(local_mlat_enable) [mlat_is_configured]
}
