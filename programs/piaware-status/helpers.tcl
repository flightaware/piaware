#
# flightaware helper routines for piaware-status program
#
#

#
# report_status - report on what's running, inspect network connections and
#  report (if allowed), and then connect to ports and listen for data for
#  a while
#
proc report_status {} {
    report_on_whats_running

    netstat_report

    check_ports_for_data
}

#
# process_running_report -check to see if a process is running, say whether
#  it is or not, and store a 1/0 in the running array for that process
#
proc process_running_report {name} {
    if {[is_process_running $name]} {
	puts "$name is running."
	set ::running($name) 1
    } else {
	puts "$name is not running."
	set ::running($name) 0
    }
}

#
# report_on_whats_running - look at some programs that are interesting to
#  know about
#
proc report_on_whats_running {} {
    set programs [list dump1090 faup1090 piaware]

    # if they have an alt adsbprogram, use that
    if {[info exists ::adeptConfig(adsbprogram)]} {
	set prog $::adeptConfig(adsbprogram)
	if {$prog != "" && $prog != "dump1090"} {
	    lappend programs $prog
	    set ::adsbprog $prog
	}
    }

    foreach program $programs {
	process_running_report $program
    }
}

#
# whats_probably_30005 - say what we think is at the other end of port 30005
#
proc whats_probably_30005 {} {
    if {[info exists ::netstatus(program_30005)]} {
	return $::netstatus(program_30005)
    }

    if {[info exists ::adsbprog]} {
	if {$::running($::adsbprog)} {
	    return $::adsbprog
	} else {
	    return "dump1090 or $::adsbprog"
	}
    } else {
	if {$::running(dump1090)} {
	    return dump1090
	} else {
	    return "maybe dump1090"
	}
    }
    error "software failure"
}

#
# check_ports_for_data - check for data on beast and flightaware-style ports
#
proc check_ports_for_data {} {
    set ::nRunning 1
    test_port_for_traffic 30005 adsb_data_callback
}

#
# decr_nrunning - reducing the running count of things we're waiting for
#  and if it goes to zero, set the die global so the program will exit
#
proc decr_nrunning {} {
    incr ::nRunning -1
    if {$::nRunning <= 0} {
	set ::die 1
    }
}

#
# adsb_data_callback - callback when data is received on the beast 30005 port
#
proc adsb_data_callback {state} {
    set prog [whats_probably_30005]
    puts [subst_is_or_is_not "$prog %s producing data on port 30005." $state]
    decr_nrunning
}
