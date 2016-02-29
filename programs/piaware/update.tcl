# -*- mode: tcl; tab-width: 4; indent-tabs-mode: t -*-
#
# update.tcl - Piaware's processing of update commands
#
# Copyright (C) 2014-2016 FlightAware LLC, All Rights Reserved
#

package require fa_services

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
