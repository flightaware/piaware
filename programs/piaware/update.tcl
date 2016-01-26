# -*- mode: tcl; tab-width: 4; indent-tabs-mode: t -*-
#
# update.tcl - Piaware's processing of update commands
#
# Copyright (C) 2014-2016 FlightAware LLC, All Rights Reserved
#

#
# update_check - see if the requested update type (manualUpdate or
#   autoUpdate) is allowed.
#
#   you should be able to inspect this and handle_update_request
#   and how they're invoked to assure yourself that if there is
#   no autoUpdate or manualUpdate in /etc/piaware configured true
#   or by piaware-config configured true, the update cannot occur.
#
proc update_check {varName} {
	# if there is no matching update variable in the adept config or
	# a global variable set by /etc/piaware, bail
	if {![info exists ::adeptConfig($varName)] && ![info exists ::$varName]} {
		logger "$varName is not configured in /etc/piaware or by piaware-config"
		return 0
	}

	#
	# if there is a var in the adept config and it's not a boolean or
	# it's false, bail.
	#
	if {![info exists ::adeptConfig($varName)]} {
		logger "$varName is not set in adept config, looking further..."
	} else {
		if {![string is boolean $::adeptConfig($varName)]} {
			logger "$varName in adept config isn't a boolean, bailing on update request"
			return 0
		}

		if {!$::adeptConfig($varName)} {
			logger "$varName in adept config is disabled, disallowing update"
			return 0
		} else {
			# the var is there and set to true, we proceed with the update
			logger "$varName in adept config is enabled, allowing update"
			return 1
		}
	}

	if {[info exists ::$varName]} {
		set val [set ::$varName]
		if {![string is boolean $val]} {
			logger "$varName in /etc/piaware isn't a boolean, bailing on update request"
			return 0
		} else {
			if {$val} {
				# the var is there and true, proceed
				logger "$varName in /etc/piaware is enabled, allowing update"
				return 1
			} else {
				# the var is there and false, bail
				logger "$varName in /etc/piaware is disabled, disallowing update"
				return 0
			}
		}
	}

	# this shouldn't happen
	logger "software error detected in update_check, disallowing update"
	return 0
}

#
# handle_update_request - handle a message from the server requesting
#   that we update the software
#
proc handle_update_request {type _row} {
	upvar $_row row

	# force piaware config and adept config reload in case user changed
	# config since we last looked
	load_piaware_config
	load_adept_config

	switch $type {
		"auto" {
			logger "auto update (flightaware-initiated) requested by adept server"
		}

		"manual" {
			logger "manual update (user-initiated via their flightaware control page) requested by adept server"
		}

		default {
			logger "update request type must be 'auto' or 'manual', ignored..."
			return
		}
	}

	# see if we are allowed to do this
	if {![update_check ${type}Update]} {
		# no
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
					attempt_dump1090_restart
				}
			}

			"restart_dump1090" {
				attempt_dump1090_restart
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
