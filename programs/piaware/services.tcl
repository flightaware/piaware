# -*- mode: tcl; tab-width: 4; indent-tabs-mode: t -*-
#
# piaware - aviation data exchange protocol ADS-B client
#
# Copyright (C) 2016 FlightAware LLC, All Rights Reserved
#

# Utilities to invoke rc.d scripts or systemctl to start/restart system services
# todo: upstart?

# return 1 if we have invoke-rc.d
proc has_invoke_rcd {} {
	if {![info exists ::invoke_rcd_path]} {
		set ::invoke_rcd_path [auto_execok invoke-rc.d]
	}

	if {$::invoke_rcd_path ne ""} {
		return 1
	} else {
		return 0
	}
}

# return 0 if the policy layer denies the given service/action
# return 1 if the policy layer allows it, or if there's no policy layer
proc can_invoke_service_action {service action} {
	# try to decide if we should invoke the given service/action
	if {![has_invoke_rcd]} {
		# assume we can
		return 1
	}

	set status [system invoke-rc.d --query $service $action]
	switch $status {
		104 -
		105 -
		106 {
			return 1
		}

		default {
			return 0
		}
	}
}

# return 1 if it looks like we're using systemd
proc is_systemd {} {
	return [file isdirectory /run/systemd/system]
}

# return a list of systemd service unitfiles matching pattern
proc systemd_find_services {pattern} {
	if {[catch {
		split [exec systemctl list-unit-files --no-legend --no-pager --type=service $pattern] "\n"
	} result] == 1} {
		return ""
	}

	set services {}
	foreach line $result {
		set parts [split [string trim $line] " "]
		set unitfile [lindex $parts 0]
		set state [lindex $parts end]
		if {$state eq "enabled"} {
			lappend services [string map {.service {}} $unitfile]
		}
	}

	return $services
}

# return a list of sysvinit-style services matching pattern
proc sysvinit_find_services {pattern} {
	set services {}
	foreach script [glob -nocomplain -directory /etc/init.d -tails -types {f r x} $pattern] {
		switch -glob $script {
			*.dpkg*	-
			*.rpm* -
			*.ba* -
			*.old -
			*.org -
			*.orig -
			*.save -
			*.swp -
			*.core -
			*~ {
				# Skip this
			}

			default {
				lappend services $script
			}
		}
	}

	return $services
}

# invoke an action on a service, via either systemd or rc.d as appropriate
proc invoke_service_action {service action} {
	if {[is_systemd]} {
		# this looks confusing, but:
		#   "systemctl restart" restarts the unit, or starts it if not active
		#   "systemctl try-restart" restarts the unit only if it is already active
		# which is what we want for our "start" and "restart" actions respectively

		case $action {
			restart { set cmd "try-restart" }
			default { set cmd "restart" }
		}

		set command [list systemctl --no-block $cmd ${service}.service]
	} elseif {[has_invoke_rcd]} {
		# use invoke-rc.d
		set command [list invoke-rc.d $service $action]
	} else {
		# no invoke-rc.d, just run the script
		set command [list /etc/init.d/$service $action]
	}

	logger "attempting to $action $service using '$command'..."
	return [system $command]
}


# attempt_service_restart - try to (re)start a service based on the base service name
# return 1 if it all looked OK, 0 if it didn't work
proc attempt_service_restart {basename {action restart}} {
	logger "attempting to $action $basename.. "

	if {[is_systemd]} {
		set candidates [systemd_find_services ${basename}*]
	} else {
		set candidates [sysvinit_find_services ${basename}*]
	}

	set services {}
	foreach service $candidates {
		# check invoke-rc.d etc
		if {[can_invoke_service_action $service $action]} {
			lappend services $service
		}
	}

	if {[llength $services] == 0} {
		logger "can't $action $basename, no services that look like $basename found"
		return 0
	} else {
		set service [lindex $services 0]
		if {[llength $services] > 1} {
			logger "warning, more than one enabled $basename service found ($services), proceeding with '$service'..."
		}

		set exitStatus [invoke_service_action $service $action]

		if {$exitStatus == 0} {
			logger "$basename $action appears to have been successful"
			return 1
		} else {
			logger "got exit status $exitStatus while trying to $action $basename"
			return 0
		}
	}
}
