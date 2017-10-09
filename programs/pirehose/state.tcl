# Object that tracks the state for one aircraft
::itcl::class AircraftState {
	public variable hexid      ;# aircraft address
	public variable flightId   ;# unique flight ID assigned by pirehose

	variable lat          ;# last latitude, decimal degrees
	variable lon          ;# last longitude, decimal degrees
	variable alt          ;# last barometric altitude, ft
	variable alt_gnss     ;# last GNSS altitude, ft
	variable speed        ;# last groundspeed, kts
	variable speed_tas    ;# last TAS, kts
	variable speed_ias    ;# last IAS, kts
	variable heading      ;# last true heading, degrees
	variable heading_mag  ;# last magnetic heading, degrees
	variable ident        ;# last callsign/ident
	variable airGround    ;# last air/ground status, 'A' or 'G'
	variable squawk       ;# last squawk, 4-digit octal
	variable updateType   ;# last position type, 'A' (ADS-B) or 'M' (MLAT)

	variable permaMatch 0 ;# 1 if this aircraft matched a non-bounding-box filter in the past

	public variable lastSeen 0       ;# time of last received message (epoch ms)
	variable lastEmitted 0           ;# time of last emitted report (epoch ms)
    variable lastUpdate
	array set lastUpdate {}          ;# time of last update to each data field, epoch seconds, using 'clock' values

	constructor {args} {
		configure {*}$args
	}

	# return the time ('clock' value) of the last update to a field, or 0 if no data is available
	method last_update {field} {
		if {![info exists lastUpdate($field)]} {
			return 0
		} else {
			return $lastUpdate($field)
		}
	}

	# return 1 if a given field has valid data (updated within the last $::maxDataAge seconds)
	method valid {field when} {
		return [expr {[info exists lastUpdate($field)] && $when - $lastUpdate($field) < $::maxDataAge}]
	}

	# update aircraft state from a TSV report contained in the caller's array variable named by $_tsv
	method update_from_report {_tsv} {
		upvar $_tsv tsv

		set when $tsv(clock)

		if {[info exists tsv(type)] && $tsv(type) eq "mlat_result"} {
			# mlat result

			set updateType "M"

			foreach {field} {lat lon alt} {
				if {[info exists tsv($field)] && [last_update $field] <= $when} {
					set $field $tsv($field)
					set lastUpdate($field) $when
				}
			}

			if {[info exists tsv(nsvel)] && [info exists tsv(ewvel)]} {
				# convert N/S + E/W groundspeed into groundspeed and heading
				if {[last_update heading] <= $when} {
					set heading [expr {round(atan2($tsv(nsvel),$tsv(ewvel)) * 180 / 3.141592 + 360) % 360}]
					set lastUpdate(heading) $when
				}
				if {[last_update speed] <= $when} {
					set speed [expr {round(sqrt($tsv(nsvel) ** 2 + $tsv(ewvel) ** 2))}]
					set lastUpdate(speed) $when
				}
			}
		} else {
			# ADS-B or Mode S result

			set updateType "A"

			foreach {field} {lat lon alt alt_gnss speed speed_tas speed_ias heading heading_mag ident airGround squawk} {
				if {[info exists tsv($field)] && [last_update $field] <= $when} {
					set $field $tsv($field)
					set lastUpdate($field) $when
				}
			}
		}

		if {[last_update all] <= $when} {
			set lastUpdate(all) $when
			set lastSeen [clock milliseconds]
		}
	}

	# populate caller's array named $_data with a report of the current aircraft state,
	# formatted as for firehose; return 1 if it was populated.
	method build_report {when _data} {
		if {![valid lat $when] || ![valid lon $when]} {
			return 0
		}

		upvar $_data data
		set data(type) "position"
		set data(updateType) $updateType
		set data(id) $flightId
		set data(clock) $lastUpdate(all)
		set data(pitr) [clock seconds]
		set data(hexid) $hexid
		set data(lat) $lat
		set data(lon) $lon

		switch -exact -- $updateType {
			"A" {
				set data(facility_hash) "01234567"
				set data(facility_name) "Local ADS-B"
			}

			"M" {
				set data(facility_hash) "76543210"
				set data(facility_name) "FlightAware MLAT"
			}

			default {
				error "bad updateType"
			}
		}

		# required field, assume airborne if not valid
		if {[valid airGround $when] && $airGround eq "G+"} {
			set data(air_ground) "G"
		} else {
			set data(air_ground) "A"
		}

		# map internal state to firehose naming
		# for heading, true heading overrides magnetic heading
		foreach {src dest} {
			ident ident
			alt_gnss gps_alt
			speed gs
			squawk squawk
			heading_mag heading
			heading heading
			alt baro_alt} {
			if {[valid $src $when]} {
				set data($dest) [string trim [set $src]]
			}
		}

		if {![info exists data(ident)]} {
			# manufacture one as it is a required field
			set data(ident) "#$hexid"
		}

		return 1
	}

	# given a firehose-format report in caller's array $_data,
	# return 1 if it matches the current filters
	method matches_filters {_data} {
		upvar $_data data

		if {!$::filtersEnabled || $permaMatch} {
			# no filters or previous match, short-circuit it
			return 1
		}

		if {$::filterAirline != ""} {
			# this is necessarily very approximate
			foreach term $::filterAirline {
				if {[string match "${airline}*" $data(ident)]} {
					set permaMatch 1
					return 1
				}
			}
		}

		if {$::filterIdents ne ""} {
			foreach term $::filterIdents {
				if {[string match $term $data(ident)]} {
					set permaMatch 1
					return 1
				}
			}
		}

		if {$::filterLatLong ne ""} {
			foreach quad $::filterLatLong {
				lassign $quad lowLat lowLon hiLat hiLon
				if {$data(lat) >= $lowLat && $data(lat) <= $hiLat && $data(lon) >= $lowLon && $data(lon) <= $hiLon} {
					return 1   ;# not sticky!
				}
			}
		}

		# there were filters, but none matched
		return 0
	}

	# If the aircraft state passes the configured filters/interval, populate caller's
	# named $_data with a report of the current aircraft state and return 1
	method build_and_filter_report {when _data} {
		upvar $_data data

		if {([clock milliseconds] - $lastEmitted) < $::secondsBetweenPositions * 1000} {
			return 0
		}

		if {![build_report $when data]} {
			return 0
		}

		if {![matches_filters data]} {
			return 0
		}

		set lastEmitted [clock milliseconds]
		return 1
	}
}
