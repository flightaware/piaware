#
# handle data from the client after TLS handshake, while waiting for an initiation command
#
proc read_client_initiation {sock} {
	try {
		set count [gets $sock line]
	} on error {result} {
		logger "read error: $result"
		child_exit 1
	}

	if {$count < 0} {
		logger "EOF before initiation command"
		child_exit 1
	}

	if {$line eq ""} {
		# nothing this time
		return
	}

	# enable writing to the client now
	set ::clientSock $sock

	try {
		set cmd [lindex $line 0]
		switch -exact -- $cmd {
			"live" {
				set line [lrange $line 1 end]
				set minClock [clock seconds]
				set maxClock Inf
			}

			"pitr" {
				set line [lassign [lrange $line 1 end] epoch]
				if {![string is integer -strict $epoch]} {
					error "Argument to pitr is not an integer"
				}
				set minClock $epoch
				set maxClock Inf
			}

			"range" {
				set line [lassign [lrange $line 1 end] startEpoch endEpoch]
				if {![string is integer -strict $startEpoch] || ![string is integer -strict $endEpoch]} {
					error "Arguments to range are not integers"
				}
				set minClock $startEpoch
				set maxClock $endEpoch
			}

			default {
				error "Unrecognized or out-of-sequence command: $cmd"
			}
		}

		global filterAirline filterIdents filterLatLong keepaliveInterval secondsBetweenPositions filtersEnabled

		# defaults
		set version $::maxVersion
		set username ""
		set password ""
		set filterAirline ""
        set filterIdents ""
        set filterEvents ""
        set filterSource ""
        set filterLatLong ""
        set filterAirport ""
        set compressionMode ""
        set keepaliveInterval 0
        set strictUnblocking 0
        set secondsBetweenPositions 0
		set filtersEnabled 0

		foreach {cmd arg} $line {
			switch -exact -- $cmd {
				version {
					if {![string is double -strict $arg] || $arg < 1.0} {
						error "Invalid argument supplied to version command: $arg"
					}
					set version $arg
				}

				username {
					set username $arg
				}

				password {
					set password $arg
				}

				filter - airline_filter {
					foreach term $arg {
						if {![string is alnum -strict $term] || [string length $term] != 3} {
							error "Invalid term specified to filter command: $term"
						}
						set term [string toupper $term]
						lappend filterAirline $term
						set filtersEnabled 1
					}
				}

				idents {
					foreach term $arg {
						set term [string toupper $term]
						if {![regexp {^[A-Z0-9*]{3,}$} $term]} {
							error "Invalid term specified to idents command: $term"
						}
						lappend filterIdents $term
						set filtersEnabled 1
					}
				}

				events {
					set filterEvents $arg
				}

				latlon - latlong {
					if {[llength $arg] != 4} {
						error "Invalid argument supplied to latlong. Should be list of 4 values (lowLat lowLon hiLat hiLon): $arg"
					}
					foreach val $arg {
						if {![string is double -strict $val]} {
							error "Invalid argument supplied to latlong. Not a decimal: $val"
						}
					}

					lassign $arg lowLat lowLon hiLat hiLon

					if {$lowLat > $hiLat} {
						lassign [list $lowLat $hiLat] hiLat lowLat
					}
					if {$lowLon > $hiLon} {
						lassign [list $lowLon $hiLon] hiLon lowLon
					}

					lappend filterLatLong [list $lowLat $lowLon $hiLat $hiLon]
					set filtersEnabled 1
				}

				airport_filter {
					foreach term $arg {
						if {![regexp {^[A-Za-z0-9?]+$} $term]} {
							error "Invalid term specified to airport_filter command: $term"
						}
						set term [string toupper $term]
						lappend filterAirport $term
					}
					set filtersEnabled 1
				}

				compression {
					# apply data compression to all responses.
					switch -exact -- $arg {
						"gzip" - "compress" - "deflate" {
							set compressionMode $arg
						}
						default {
							error "Invalid argument supplied to compression: $arg"
						}
					}
				}

				keepalive {
					if {![string is integer -strict $arg] || $arg < 15} {
						error "Invalid argument supplied to keepalive: $arg"
					}
					set keepaliveInterval $arg
				}

				strict_unblocking {
					if {![string is integer -strict $arg] || ![string is boolean -strict $arg]} {
						error "Invalid argument supplied to strict_unblocking: $arg"
					}
					set strictUnblocking $arg
				}

				ratelimit_secs_between {
					if {![string is integer -strict $arg] || $arg < 0} {
						error "Invalid argument supplied to ratelimit_secs_between: $arg"
					}
					set secondsBetweenPositions $arg
				}

				default {
					error "Unrecognized or out-of-sequence command: $cmd"
				}
			}
		}

		if {$username == "" || $password == ""} {
			error "Login credentials missing"
        } elseif {$username ne $::params(username) || $password ne $::params(password)} {
			error "Login credentials denied: $username"
        }

		if {$filterEvents ne "" && "position" ni $filterEvents} {
			error "No supported event types requested (pirehose provides only 'position' type events)"
		}

		if {$strictUnblocking} {
			error "pirehose does not support strict_unblocking"
		}

		if {$filterAirport ne ""} {
			error "pirehose does not support filter_airport"
		}

		if {$version < $::minVersion || $version > $::maxVersion} {
			error "pirehose does not support version $version"
		}
	} on error {result} {
		logger "failed to process initiation command: $result"
		write_to_client "Error: $result"
		child_exit 2
	}

	# looks cool, clear the initiation timeout alarm, swallow client input looking for EOF
	# clear the alarm clock
	alarm 0
	logger "initiation OK, feeding data"
    setproctitle "waiting for data"
	chan event $::clientSock readable [list read_client_discard $sock]

	# enable compression if requested
	if {$compressionMode ne ""} {
		zlib push $compressionMode $sock
		periodically_syncflush_output
	}

	set ::lastActive [clock milliseconds]
	if {$keepaliveInterval > 0} {
		periodically_check_keepalive
	}
}
