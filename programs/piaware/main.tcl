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
package require tls

if {![info exists ::launchdir]} {
    set ::launchdir "."
}

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
        {v  "emit version information and exit"}
    }

    set usage ": $::argv0 ?-p pidfile? ?-v? ?-debug? ?-serverport <port>? "

    if {[catch {array set ::params [::cmdline::getoptions argv $options $usage]} catchResult] == 1} {
        puts stderr $catchResult
        exit 1
    }

    if {$argv != ""} {
        puts stderr [::cmdline::usage $options]
        exit 1
    }

	if {$::params(v)} {
		puts stdout "piaware version $::piawareVersion"
		exit 0
	}

	user_check

	load_piaware_config_and_stuff

	#::tcllauncher::daemonize
	# NB does not work due to thread/fork interaction, can be solved with
	# improvements in tcllauncher
	# we are instead launching from the /etc/init.d/ script
if 0 {
	set pid [fork]
	if {$pid != 0} {
		exit 0
	}
}

	# setup adept client early so logger command won't trace back
	# (this does not initiate a connection, it just creates the object)
    setup_adept_client

	# arrange for a clean shutdown in the event of certain common signals
	setup_signals

	# maintain a pidfile so we don't get multiple copies of ourself
	create_pidfile

	# set the number of messages received so far to 0
	set_prior_messages_received 0
 
	# start logging to a file unless configured for debug
	if {!$::params(debug)} {
		log_stdout_stderr_to_file
		schedule_logfile_switch
	}

	greetings

	# attempt to kill any extant copies of faup1090
	if {[is_process_running faup1090]} {
		system "killall faup1090"
		sleep 1
	}

	load_adept_config_and_setup
	#confirm_nonblank_user_and_password_or_die

	inspect_sockets_with_netstat

    setup_fa_style_adsb_client

	periodically_check_adsb_traffic

	after 30000 periodically_send_health_information

    catch {vwait die}

	cleanup_and_exit
}

if {!$tcl_interactive} {
    main $argv
}

# vim: set ts=4 sw=4 sts=4 noet :
