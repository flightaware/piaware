#
# fa_sudo - an interface to sudo with some caching.
#
# Copyright (C) 2016 FlightAware LLC, All Rights Reserved
#
#

package require Tclx

namespace eval ::fa_sudo {
	proc _can_sudo {args} {
		set command [lindex $args 0]
		if {[auto_execok $command] eq ""} {
			return 0
		}

		if {[auto_execok sudo] eq ""} {
			return 0
		}

		if {[catch {exec sudo -n -l {*}$args < /dev/null} result]} {
			# failed
			return 0
		}

		# seems OK
		return 1
	}

	proc can_sudo {args} {
		if {[id userid] == 0} {
			# already root
			return 1
		}

		if {![info exists ::fa_sudo::cache($args)]} {
			set ::fa_sudo::cache($args) [_can_sudo {*}$args]
		}

		return $::fa_sudo::cache($args)
	}

	proc sudo_exec {args} {
		if {[id userid] == 0} {
			# already root
			return [exec {*}$args]
		}

		if {![can_sudo {*}$args]} {
			error "not root and sudo not possible for $args"
		}

		return [exec sudo -n $command {*}$args]
	}

	proc sudo_open {pipecommand {access "r"}} {
		if {[string index $pipecommand 0] ne "|"} {
			error "pipecommand must start with |"
		}

		# validate args, extract first command in the pipeline without redirections for sudo check
		set arglist [string range $pipecommand 1 end]
		set checkargs {}
		for {set i 0} {$i < [llength $arglist]} {incr i} {
			set arg [lindex $arglist $i]

			switch -glob $arg {
				"|" - "|&" {
					# stop here
					break
				}

				"<" - "<@" - "<<" - ">" - "2>" - ">&" -
				">>" - "2>>" - ">>&" - ">@" - "2>@" -
				">&@" {
					# file redirection with a following arg, skip them both
					incr i
				}

				"<*" - "<@*" - "<<*" - ">*" - "2>*" -
				">&*" - ">>*" - "2>>*" - ">>&*" -
				">@*" - "2>@*" - "2>@1" - ">&@*" - "&" {
					# single arg, or file redirection with the fileid embedded, skip it
				}

				* {
					lappend checkargs $arg
				}
			}

		}

		# ok, command looks sensible

		if {[id userid] == 0} {
			# already root
			return [open $pipecommand $access]
		}

		if {![can_sudo {*}$checkargs]} {
			error "not root and sudo not possible for $command"
		}

		return [open "|sudo -n $arglist" $access]
	}
} ;# namespace eval ::fa_sudo

package provide fa_sudo 0.1
