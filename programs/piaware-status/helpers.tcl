#
#
#
#

proc report_status {} {
    report_on_whats_running

    netstat_report

    if {$::running(dump1090)} {
	check_dump1090_for_data
    }
}

proc process_running_report {name} {
    if {[is_process_running $name]} {
	puts "$name is running"
	set ::running($name) 1
    } else {
	puts "$name is not running"
	set ::running($name) 0
    }
}

proc report_on_whats_running {} {
    foreach program "dump1090 faup1090 piaware" {
	process_running_report $program
    }
}

proc check_dump1090_for_data {} {
    set ::nRunning 2
    test_port_for_traffic 30005 dump1090_data_callback
    test_port_for_traffic 10001 fa_style_data_callback
}

proc decr_nrunning {} {
    incr ::nRunning -1
    if {$::nRunning <= 0} {
	set ::die ""
    }
}

proc dump1090_data_callback {state} {
    puts [subst_is_or_is_not "dump1090 %s producing data on port 30005." $state]
    decr_nrunning

}

proc fa_style_data_callback {state} {
    puts [subst_is_or_is_not "dump1090 / faup1090 %s producing data on port 10001." $state]
    decr_nrunning

}
