#
# fa_adept_config - key-value pair config file reader/writer
#
# Copyright (C) 2014 FlightAware LLC, All Rights Reserved
#
#

set adeptConfigFile "/root/.piaware"

#
# load_adept_config - open and read in the adept config file.
#  if the file doesn't exist, that's ok.
#
#  use set_adept_config to set all the variables and their values that are
#  found.
#
proc load_adept_config {} {
	if {[catch {set fp [open $::adeptConfigFile]} catchResult] == 1} {
		if {[lindex $::errorCode 0] == "POSIX" && [lindex $::errorCode 1] == "ENOENT"} {
			return 0
		}
		puts stderr "got $catchResult trying to open '$::adeptConfigFile'"
		exit 2
	}
	while {[gets $fp line] >= 0} {
		if {[catch {llength $line} catchResult] == 1} {
			# line does not have list format
			puts stderr "config file line '$line' does not have list format"
		} elseif {$catchResult != 2} {
			# line does not contain two elements
			puts stderr "config file line '$line' does not contain two elements"
		} else {
			lassign $line var value
			set_adept_config $var $value
			#puts stderr "load element $var to value '$value'"
		}
	}

	close $fp
	return 1
}

#
# set_adept_config - store an adept config variable and value in the
#  adeptConfig global array.
#
proc set_adept_config {var value} {
	set ::adeptConfig($var) $value
	#puts "set adept config var $var to value '$value'"
}

#
# save_adept_config - write out all the variables found in the adept config
#  global array to the adept config file.
#
proc save_adept_config {} {
	set fp [open $::adeptConfigFile w 0600]
	foreach var [lsort [array names ::adeptConfig]] {
		puts $fp [list $var $::adeptConfig($var)]
	}
	close $fp
}

package provide fa_adept_config 1.0

# vim: set ts=4 sw=4 sts=4 noet :
