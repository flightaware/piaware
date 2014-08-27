#
# piaware - ADS-B data upload to FlightAware
#
# Copyright (C) 2014 FlightAware LLC, All Rights Reserved
#

lappend auto_path /usr/local/lib

package require piaware
package require fa_adept_client
package require fa_adept_config
#package require BSD
package require Tclx
package require cmdline

if {![info exists ::launchdir]} {
    set ::launchdir "."
}

package require tls
package require Tclx
package require fa_adept_config

source $::launchdir/config.tcl
source $::launchdir/helpers.tcl
source $::launchdir/faup1090.tcl
source $::launchdir/health.tcl

#
# main - the main program
#
proc main {{argv ""}} {
    set options {
        {p.arg "" "specify the name of a file to write our pid in"}
        {serverport.arg "1200" "specify alternate server port (for FA testing)"}
        {debug  "log to stdout rather than the log file"}
    }

    set usage ": $::argv0 ?-p?"

    if {[catch {array set ::params [::cmdline::getoptions argv $options $usage]} catchResult] == 1} {
        puts stderr $catchResult
        exit 1
    }

    if {$argv != ""} {
        puts stderr [::cmdline::usage $options]
        exit 1
    }

	user_check

	#::tcllauncher::daemonize
if 0 {
	set pid [fork]
	if {$pid != 0} {
		exit 0
	}
}

	# attempt to kill any extant copies of faup1090
	system "killall faup1090"
	sleep 1

	setup_signals

	create_pidfile 
  
	# log to a file unless configured for debug
	if {!$::params(debug)} {
		log_stdout_stderr_to_file
	}

	greetings

	user_check
	get_user_and_password
	confirm_nonblank_user_and_password_or_die

    setup_adept_client

    setup_faup1090_client

	faup1090_running_periodic_check

	periodically_send_health_information

	after 60000 periodically_issue_a_traffic_report

    catch {vwait die}

	cleanup_and_exit
}

if {!$tcl_interactive} {
    main $argv
}

# vim: set ts=4 sw=4 sts=4 noet :
