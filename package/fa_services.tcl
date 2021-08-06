# -*- mode: tcl; tab-width: 4; indent-tabs-mode: t -*-
#
# piaware - utilities to start/stop/check system services
# (sysvinit or systemd)
#
# Copyright (C) 2016 FlightAware LLC, All Rights Reserved
#

package require fa_sudo

namespace eval ::fa_services {
	set helperDir [file join [file dirname [info script]] "helpers"]

	proc restart_receiver {} {
		::fa_sudo::exec_as -root -- [file join $::fa_services::helperDir "restart-receiver"]
	}

	proc restart_network {} {
		::fa_sudo::exec_as -root -- [file join $::fa_services::helperDir "restart-network"]
	}

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

		lassign [::fa_sudo::exec_as -root -returnall -ignorestderr -- invoke-rc.d --query $service $action </dev/null] childpid status out err
		switch $status {
			SUDOFAILED -
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
			split [::fa_sudo::exec_as -- systemctl list-unit-files --no-legend --no-pager ${pattern}.service] "\n"
		} result] == 1} {
			return ""
		}

		set services {}
		foreach line $result {
			set parts [split [string trim $line] " "]
			set unitfile [lindex $parts 0]
			set state [lindex $parts end]
			if {$state eq "enabled" || $state eq "static"} {
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

	# check if a given service is running, via either systemd or rc.d as appropriate
	proc is_service_running {service} {
		if {[is_systemd]} {
			set command [list systemctl is-active ${service}.service < /dev/null]
		} elseif {[has_invoke_rcd]} {
			set command [list invoke-rc.d $service status < /dev/null]
		} else {
			set command [list /etc/init.d/$service status < /dev/null]
		}

		lassign [::fa_sudo::exec_as -root -returnall -- {*}$command] childpid status out err
		return [expr {$status == 0}]
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

			set command [list systemctl --no-block $cmd ${service}.service < /dev/null]
			set reap 0
		} elseif {[has_invoke_rcd]} {
			# use invoke-rc.d
			set command [list invoke-rc.d $service $action < /dev/null &]
			set reap 1
		} else {
			# no invoke-rc.d, just run the script
			set command [list /etc/init.d/$service $action < /dev/null &]
			set reap 1
		}

		logger "attempting to $action $service using '$command'..."
		lassign [::fa_sudo::exec_as -root -returnall -ignorestderr -- {*}$command] childpid status out err
		if {$reap && $childpid != 0} {
			reap_child_later $childpid
		}
		return $status
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

	# periodically try to reap a particular background process
	proc reap_child_later {childpid} {
		after 5000 [list ::fa_services::try_to_reap_child $childpid]
	}

	proc try_to_reap_child {childpid} {
		if {[catch {wait -nohang $childpid} result]} {
			# I guess we missed it.
			logger "child pid $childpid exited with unknown status"
			return
		}

		if {$result eq ""} {
			# I'm not dead!
			after 5000 [list try_to_reap_child $childpid]
			return
		}

		# died
		lassign $result deadpid status code
		switch $status {
			EXIT {
				if {$code != 0} {
					logger "child pid $deadpid exited with status $code"
				}
			}

			SIG {
				logger "child pid $deadpid killed by signal $code"
			}

			default {
				logger "child pid $deadpid exited with unexpected status $status $code"
			}
		}
	}
}

package provide fa_services 0.1
