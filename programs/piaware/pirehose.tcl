# -*- mode: tcl; tab-width: 4; indent-tabs-mode: t -*-

# piaware - pirehose
# This handles the pirehose subprocess and feeds messages
# from faup1090 / mlat to it.

package require fa_sudo

set ::pirehosePath [auto_execok "pirehose"]

proc start_pirehose {} {
	if {![piawareConfig get enable-firehose]} {
		return
	}

	if {$::pirehosePath eq ""} {
		logger "firehose support disabled (no pirehose found)"
		return
	}

	set command [list $::pirehosePath]
	logger "Starting pirehose listener: $command"

	if {[catch {::fa_sudo::popen_as -noroot -stdin pirehoseStdin -stdout pirehoseStdout -stderr pirehoseStderr {*}$command} result]} {
		logger "got '$result' starting pirehose"
		return
	}

	if {$result == 0} {
		logger "could not start pirehose: sudo refused to start the command"
		return
	}

	fconfigure $pirehoseStdin -buffering line -blocking 0 -translation lf

	log_subprocess_output "pirehose($result)" $pirehoseStdout
	log_subprocess_output "pirehose($result)" $pirehoseStderr

	set ::pirehosePipe $pirehoseStdin
	set ::pirehosePid $result
}

proc stop_pirehose {} {
	if {![info exists ::pirehosePipe]} {
		return
	}

	catch {close $::pirehosePipe}
	unset ::pirehosePipe
	catch {
		lassign [timed_waitpid 15000 $::pirehosePid] deadpid why code
		if {$code ne "0"} {
			logger "pirehose exited with $why $code"
		} else {
			logger "pirehose exited normally"
		}
	}
}

proc forward_to_pirehose {line} {
	if {![info exists ::pirehosePipe]} {
		return
	}

	if {[catch {puts $::pirehosePipe $line} catchResult] == 1} {
		logger "got '$catchResult' writing to pirehose"
		stop_pirehose
		return
	}
}

# vim: set ts=4 sw=4 sts=4 noet :
