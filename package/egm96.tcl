# EGM96 table-driven model

namespace eval ::egm96 {
	proc lookup {ilat ilon} {
		return [lindex $geoid::data [expr {$ilat * $geoid::bandsize + $ilon}]]
	}

	# returns the height of the EGM96 geoid above the WGS84 ellipsoid
	proc geoid_height {lat lon} {
		if {$lat < -90 || $lat > 90} {
			error "latitude out of range"
		}

		set tlat [expr {($lat + 90) / $geoid::scale}]
		set tlon [expr {fmod($lon + 180,360) / $geoid::scale}]

		set ilat0 [expr {int($tlat)}]
		set flat [expr {$tlat - $ilat0}]

		set ilon0 [expr {int($tlon)}]
		set flon [expr {$tlon - $ilon0}]

		set ilat1 [expr {$ilat0 + 1}]
		set ilon1 [expr {$ilon0 + 1}]

		if {$ilat1 == $geoid::bandcount} {
			# north pole
			set ilat1 $ilat0
		}

		# just bilinear interpolation, works well enough
		# for our purposes

		set g00 [lookup $ilat0 $ilon0]
		set g01 [lookup $ilat0 $ilon1]
		set g10 [lookup $ilat1 $ilon0]
		set g11 [lookup $ilat1 $ilon1]

		set g0x [expr {$g00 + ($g01 - $g00) * $flon}]
		set g1x [expr {$g10 + ($g11 - $g10) * $flon}]

		return [expr {$g0x + ($g1x - $g0x) * $flat}]
	}
}

package provide egm96 0.1
