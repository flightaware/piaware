# -*- mode: tcl; tab-width: 4; indent-tabs-mode: t -*-
#
# update.tcl - Piaware's processing of update commands
#
# Copyright (C) 2014-2016 FlightAware LLC, All Rights Reserved
#

package require fa_services
package require fa_sudo

set ::aptRunScript [file join [file dirname [info script]] "helpers" "run-apt-get"]

#
# handle_update_request - handle a message from the server requesting
#   that we update the software
#
#   you should be able to inspect this to assure yourself that if
#   there is no allow-auto-updates or allow-manual-updates in
#   the piaware config files, the update cannot occur.
#
proc handle_update_request {type _row} {
	upvar $_row row

	# make sure our copy of the config is up to date
	reread_piaware_config

	switch $type {
		"auto" {
			logger "auto update (flightaware-initiated) requested by adept server"
			set key "allow-auto-updates"
		}

		"manual" {
			logger "manual update (user-initiated via their flightaware control page) requested by adept server"
			set key "allow-manual-updates"
		}

		default {
			logger "update request type must be 'auto' or 'manual', ignored..."
			return
		}
	}

	# see if we are allowed to do this
	if {![piawareConfig get $key]} {
		# no
		logger "update denied by local configuration ([piaware origin $key])"
		return
	}

	if {![info exists row(action)]} {
		error "no action specified in update request"
	}

	logger "performing $type update, action: $row(action)"

	set restartPiaware 0
	set updatedPackageLists 0
	set ok 1
	foreach action [split $row(action) " "] {
		if {$action in {full packages piaware dump1090}} {
			# these actions require that the package lists
			# are up to date, but we don't want to do it
			# several times
			if {!$updatedPackageLists} {
				set ok [update_package_lists]
			}
		}

		if {!$ok} {
			logger "skipping action $action"
			continue
		}

		switch $action {
			"full" - "packages" {
				set ok [upgrade_all_packages]
			}

			"piaware" {
				# only restart piaware if upgrade_piaware said it upgraded
				# successfully
				set ok [upgrade_piaware]
				if {$ok} {
					set restartPiaware 1
				}
			}

			"restart_piaware" {
				set restartPiaware 1
				set ok 1
			}

			"dump1090" {
				# try to upgrade dump1090 and if successful, restart it
				set ok [upgrade_dump1090]
				if {$ok} {
					::fa_services::attempt_service_restart dump1090 restart
				}
			}

			"restart_dump1090" {
				::fa_services::attempt_service_restart dump1090 restart
				set ok 1
			}

			"restart_receiver" {
				::fa_services::attempt_service_restart $::adsbDataService restart
				set ok 1
			}

			"reboot" {
				reboot
				# don't run anything further
				set ok 0
			}

			"halt" {
				halt
				# don't run anything further
				set ok 0
			}

			default {
				logger "unrecognized update action '$action', ignoring..."
				set ok 0
			}
		}
	}

	logger "update request complete"

	if {$restartPiaware} {
		restart_piaware
	}
}

#
# reboot - reboot the machine
#
proc reboot {} {
    logger "rebooting..."
	::fa_sudo::exec_as -root -- /sbin/reboot &
}

#
# halt - halt the machine
#
proc halt {} {
	logger "halting..."
	::fa_sudo::exec_as -root -- /sbin/halt &
}

#
# run_apt_get - run the apt-get helper script as root
# and log all the output
#
proc run_apt_get {args} {
	run_command_as_root_log_output $::aptRunScript {*}$args
}

#
# update_package_lists
# runs apt-get update to update all package lists
# installs the FA repository config if it's not present
#
proc update_package_lists {} {
    return [run_apt_get update]
}

#
# update_operating_system_and_packages 
#
# * upgrade raspbian (retain local changes, upgrade unchanged config files)
#
# * reboot
#
proc upgrade_all_packages {} {
    logger "*** attempting to upgrade all packages to the latest"

    if {![run_apt_get upgrade-all]} {
		logger "aborting upgrade..."
		return 0
    }
    return 1
}

#
# upgrade_piaware - upgrade piaware via apt-get
#
proc upgrade_piaware {} {
	# If we have piaware-release installed, upgrade that
	# so the whole release is upgraded. Otherwise,
	# upgrade just piaware.

	set res [query_dpkg_names_and_versions "piaware-release"]
	if {$res ne ""} {
		return [single_package_upgrade "piaware-release"]
	} else  {
		return [single_package_upgrade "piaware"]
	}
}


#
# upgrade_dump1090 - upgrade dump1090-fa via apt-get
#
proc upgrade_dump1090 {} {
	return [single_package_upgrade "dump1090-fa"]
}

#
# single_package_upgrade: update a single FA package
#
proc single_package_upgrade {pkg} {
	# run the update/upgrade
    if {![run_apt_get upgrade-package $pkg]} {
		logger "aborting upgrade..."
		return 0
    }

	logger "upgrade of $pkg seemed to go OK"
	return 1
}

