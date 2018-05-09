namespace eval ::fa_adept_codec {
	namespace eval internals {
		variable registry
		array set registry {}

		variable latest
		array set latest {}
	}

	proc exists {name version} {
		return [expr {[info exists internals::registry($name-$version)]}]
	}

	proc register {name version command} {
		if {[exists $name $version] && [find $name $version] ne $command} {
			error "$name schema version $version is already registered to a different command"
		}

		if {![info exists internals::latest($name)] || $internals::latest($name) < $version} {
			set internals::latest($name) $version
		}

		set internals::registry($name-$version) $command
	}

	proc new_codec {name {version ""}} {
		if {$version eq ""} {
			if {[info exists internals::latest($name)]} {
				set version $internals::latest($name)
			} else {
				error "no $name schema registered"
			}
		}

		if {[info exists internals::registry($name-$version)]} {
			return [uplevel 1 $internals::registry($name-$version)]
		} else {
			error "no $name schema registered with version $version"
		}
	}

	namespace export register exists new_codec
}

package provide fa_adept_codec 2.1
