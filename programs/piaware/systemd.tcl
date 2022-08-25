# basic systemd watchdog support
#
# For now, this is very simple - reset the watchdog from the tcl event loop;
# this is intended mostly to catch tcl-tls hanging in a way that freezes
# the whole event loop.

proc systemd_start_watchdog {} {
	set ::systemd_notify [auto_execok systemd-notify]
	if {$::systemd_notify eq ""} {
		# no systemd-notify in path, probably not a systemd system at all
		return
	}

	if {![info exists ::env(WATCHDOG_USEC)]} {
		# no watchdog requested
		return
	}

	if {[info exists ::env(WATCHDOG_PID)] && $::env(WATCHDOG_PID) != [pid]} {
		# watchdog PID exists but is not our PID
		return
	}

	set ::systemd_watchdog_interval_ms [expr {round($::env(WATCHDOG_USEC) * 0.8 / 1000.0)}]
	unset ::env(WATCHDOG_USEC)	 ;# ensure that child processes don't think they need to do a watchdog

	systemd_periodically_reset_watchdog
}

proc systemd_periodically_reset_watchdog {} {
	after $::systemd_watchdog_interval_ms systemd_periodically_reset_watchdog
	catch {exec -- {*}$::systemd_notify --pid=[pid] WATCHDOG=1}
}
