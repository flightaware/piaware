# -*- mode: tcl; tab-width: 4; indent-tabs-mode: t -*-
#
# tryfinallyshim - a partial implementation of try-finally (no "catch") for Tcl 8.5
#
# safe to require the package in Tcl 8.6 - it is a no-op if "try" already exists.
#
# Copyright (C) 2016 FlightAware LLC, All Rights Reserved
#
# open source in accordance with the Berkeley license
#

if {[info commands try] eq ""} {
	proc try {tryScript args} {
		if {[llength $args] == 0} {
			# trivial case, try { $tryScript }
			catch {uplevel 1 $tryScript} tryResult tryOptions
			return -options $tryOptions $tryResult
		}

		if {[llength $args] != 2 || [lindex $args 0] ne "finally"} {
			error "syntax: try {...} ?finally {...}?"
		}

		set finallyScript [lindex $args 1]

		# try { $tryScript } finally { $finallyScript }, always run both
		catch {uplevel 1 $tryScript} tryResult tryOptions
		set fCode [catch {uplevel 1 $finallyScript} finallyResult finallyOptions]

		switch $fCode {
			0 {
				return -options $tryOptions $tryResult
			}

			1 {
				# error in finally block overrides the inner block's result
				return -options $finallyOptions $finallyResult
			}

			default {
				# finally block shouldn't do this
				error "finally block returned break/continue/return"
			}
		}
	}
}

package provide tryfinallyshim 0.1
