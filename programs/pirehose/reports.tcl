# we need the json output to be all on one line
::json::write indented 0
::json::write aligned 0

set ::nextFlightID 0   ;# sequence number used in flight_id
set ::newestClock 0    ;# highes 'clock' value seen so far

# callback when TSV data forwarded by the listener to our pipe is available
proc read_parent {} {
	while {1} {
		try {
			set count [gets stdin line]
		} on error {result} {
			logger "parent read error: $result"
			child_exit 1
		}

		if {$count < 0} {
			if {[eof stdin]} {
				logger "parent EOF"
				child_exit 0
			}

			# no more data
			break
		}

		try {
			handle_report $line
		} on error {result} {
			logger "failed to process line: $line"
			logger "$::errorInfo"
		}
	}
}

# handle one TSV line
proc handle_report {line} {
    array set tsv [split $line "\t"]
	if {![info exists tsv(hexid)] || ![info exists tsv(clock)] || ([info exists tsv(anon)] && $tsv(anon) != 0)} {
		return
	}

	set hexid $tsv(hexid)

	# match to existing aircraft or create a new one
	if {[info exist ::aircraftState($hexid)]} {
		set aircraft $::aircraftState($hexid)
	} else {
		set newID "$hexid-[clock seconds]-piaware-[incr ::nextFlightID]"
		set aircraft [AircraftState #auto -hexid $hexid -flightId $newID]
		set ::aircraftState($hexid) $aircraft
	}

	# update aircraft state
	$aircraft update_from_report tsv

	# check for range start / end
	set now [clock seconds]
	if {$now > $::maxClock} {
		# done.
		logger "End of range reached, exiting"
		child_exit 0
	}

	# if this was a position, build a firehose line and maybe send it
	if {$now >= $::minClock && [info exists tsv(lat)] && [info exists tsv(lon)]} {
		if {[$aircraft build_and_filter_report $now $tsv(clock) report]} {
			# stringify everything to match what firehose does
			foreach field [array names report] {
				set report($field) [::json::write string $report($field)]
			}

			write_to_client [::json::write object {*}[array get report]]
		}
	}

	set ::newestClock [expr {max($::newestClock,$tsv(clock))}]
	setproctitle "at $::newestClock"
}

# clean up aircraft state for aircraft that haven't been seen in a while
# if they reappear later, they'll get a new flight_id
proc periodically_cleanup_aircraft {} {
	set now [clock milliseconds]
	set oldest $now
	foreach {hexid aircraft} [array get ::aircraftState] {
		set lastReport [$aircraft cget -lastSeen]
		if {$lastReport + $::aircraftExpiry <= $now} {
			unset ::aircraftState($hexid)
			itcl::delete object $aircraft
		} else {
			set oldest [expr {min($lastReport,$oldest)}]
		}
	}

	# reschedule just after the next expiry
	after [expr {$oldest + $::aircraftExpiry - $now + 5}] periodically_cleanup_aircraft
}
