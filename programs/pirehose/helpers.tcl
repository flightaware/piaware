set ::logPrefix "pirehose"

#
# log something to stderr with the current prefix
#
proc logger {msg} {
	puts stderr "$::logPrefix: $msg"
}

#
# setproctitle: change the process title, applying the log prefix
#
proc setproctitle {msg} {
	# disabled for now
	#::bsd::setproctitle "$::logPrefix $msg"
}

#
# log_bgerror - log about background exceptions
#
proc log_bgerror {message _options} {
	array set options $_options
	logger "caught bgerror: $options(-errorinfo)"
}

proc periodically_reap_children {} {
	while {1} {
		try {
			lassign [wait -nohang] childpid why code
		} on error {result} {
			break
		}

		if {$childpid eq ""} {
			break
		}

		if {$why eq "EXIT" && $code == 0} {
			logger "Child $childpid exited normally"
		} else {
			logger "Child $childpid exited with status $why $code"
		}
	}

	set ::reapTimer [after 5000 periodically_reap_children]
}

proc stop_reaping {} {
	if {[info exists ::reapTimer]} {
		after cancel $::reapTimer
		unset ::reapTimer
	}
}
