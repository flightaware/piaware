#
# fa_sudo - run commands as other users via sudo or fork/setuid/exec
#
# Copyright (C) 2016 FlightAware LLC, All Rights Reserved
#
#

package require Tclx

namespace eval ::fa_sudo {
	namespace export open_as exec_as popen_as can_sudo

	if {[catch {package require Tcl 8.6}]} {
		# use Tclx's pipe with CLOEXEC tweaks

		proc makepipe {} {
			pipe r w
			fcntl $r CLOEXEC 1
			fcntl $w CLOEXEC 1
			return [list $r $w]
		}
	} else {
		# use tcl8.6's 'chan pipe' directly
		proc makepipe {} {
			return [chan pipe]
		}
	}

	set dropRootHelper [file join [file dirname [info script]] "helpers" "droproot"]
	set audit 0

	proc _shellquote_arg {arg} {
		return [concat \" [string map {\\ {\\} ` {\`} \$ {\$} \" {\"}} $arg] \"]
	}

	proc _shellquote {args} {
		set l {}
		foreach arg $args {
			lappend l [_shellquote_arg $arg]
		}
		return [join $l " "]
	}

	proc _make_droproot_args {user argv0 args} {
		# try a few different things to drop root
		set path [auto_execok $::fa_sudo::dropRootHelper]
		if {$path ne ""} {
			return [list {*}$path $user $argv0 {*}$args]
		}

		set path [auto_execok "chpst"]
		if {$path ne ""} {
			return [list {*}$path -u $user -b $argv0 {*}$args]
		}

		set path [auto_execok "sudo"]
		if {$path ne ""} {
			# sudo doesn't have an option to set argv[0]
			return [list {*}$path -u $user {*}$args]
		}

		set path [auto_execok "su"]
		if {$path ne ""} {
			# su will pass the args to a shell, make sure it's suitably quoted
			return [list {*}path $user -- -c [_shellquote {*}$args]]
		}

		error "can't work out a way to drop root privileges (no droproot, chpst, or sudo found)"
	}

	proc _can_sudo {user args} {
		if {[catch {exec_as -returnall -ignorestderr -- {*}[auto_execok sudo] -n -u $user -l -- {*}$args </dev/null >/dev/null} result]} {
			# failed
			return 0
		}

		lassign $result deadpid status out err
		if {$status ne "0"} {
			# return code says it failed
			return 0
		}

		# seems OK
		return 1
	}

	proc can_sudo {user args} {
		if {[_is_user $user]} {
			# already the right user/group
			return 1
		}

		if {[auto_execok sudo] eq ""} {
			# no sudo installed
			return 0
		}

		if {[id userid] == 0} {
			# assume root can do everything
			return 1
		}

		# ask sudo if this is OK
		set key [list $user {*}$args]
		if {![info exists ::fa_sudo::cache($key)]} {
			set ::fa_sudo::cache($key) [_can_sudo $user {*}$args]
		}

		return $::fa_sudo::cache($key)
	}

	proc clear_sudo_cache {} {
		array unset ::fa_sudo::cache
	}

	proc _prepare_read_redirect {where _child _cleanup} {
		upvar 1 $_child child
		upvar 1 $_cleanup cleanup

		switch -glob $where {
			"@*" {
				set fileid [string range $where 1 end]
				catch {flush $fileid}
				set child $fileid
			}

			"<*" {
				set child [open [string range $where 1 end] "r"]
				lappend cleanup $child
			}

			"*" {
				upvar 2 $where parent
				lassign [makepipe] child parent
				lappend cleanup $child
			}

			default {
				error "don't understand a read redirection of $where"
			}
		}
	}

	proc _prepare_write_redirect {where _child _cleanup} {
		upvar 1 $_child child
		upvar 1 $_cleanup cleanup

		switch -glob $where {
			"@*" {
				set fileid [string range $where 1 end]
				catch {flush $fileid}
				set child $fileid
			}

			">>*" {
				set child [open [string range $where 2 end] "a"]
				lappend cleanup $child
			}

			">*" {
				set child [open [string range $where 1 end] "w"]
				lappend cleanup $child
			}

			"*" {
				upvar 2 $where parent
				lassign [makepipe] parent child
				lappend cleanup $child
			}

			default {
				error "don't understand a write redirection of $where"
			}
		}
	}

	variable unprivilegedUser "nobody"

	proc _parse_popen_options {_options args} {
		upvar $_options options

		# options
		set arglist {}
		for {set i 0} {$i < [llength $args]} {incr i} {
			set arg [lindex $args $i]

			switch -glob $arg {
				-options {
					incr i
					array set options [lindex $args $i]
				}

				-stdout - -stderr - -stdin - -argv0 - -user {
					incr i
					set options($arg) [lindex $args $i]
				}

				-root - -noroot {
					set options($arg) 1
				}

				-- {
					incr i
					break
				}

				-* {
					error "don't recognize option $arg"
				}

				default {
					break
				}
			}
		}

		lappend arglist {*}[lrange $args $i end]

		# final tweaks
		if {[info exists options(-root)]} {
			set options(-user) "root"
		}

		if {[info exists options(-noroot)]} {
			if {![info exists options(-user)]} {
				set options(-user) $::fa_sudo::unprivilegedUser
			}
		}

		return $arglist
	}

	# return 1 if current process credentials match the given user
	proc _is_user {user} {
		if {[catch {id convert user $user} uid]} {
			# user doesn't exist?
			return 0
		}

		if {[id userid] != $uid} {
			return 0
		}

		return 1
	}

	# Start a single subprocess with redirections and possibly changing UID/GID.
	#
	# popen_as
	#   ?-root?                                           # try to run as root, using sudo if necessary
	#   ?-noroot?                                         # if we are root, switch to unprivilegedUser
	#   ?-user user?                                      # try to run as the given user, using sudo or dropping privileges as necessary
	#   ?-argv0 argv0?                                    # set argv[0] of process to exec
	#   ?-stdin where? ?-stdout where? ?-stderr where?    # redirect stdin/stdout/stderr in child
	#   ?--?                                              # end of options
	#   command ?arg? ?arg? ...                           # command to exec
	#
	# 'where' can be:
	#   >path or >>path or <path to open a file
	#   @fileid to use an existing tcl channel
	#   any other value names a variable in the caller to place a pipe channel in;
	#    the child FD is connected to the other end of the pipe
	#
	# Returns the child PID, or 0 if the command could not be started because we couldn't switch users
	#
	# If not redirected, stdin/stdout/stderr use parent stdin/stdout/stderr
	#
	proc popen_as {args} {
		set options(-stdin) "@stdin"
		set options(-stdout) "@stdout"
		set options(-stderr) "@stderr"
		set arglist [_parse_popen_options options {*}$args]

		if {[info exists options(-argv0)]} {
			set argv0 $options(-argv0)
		} else {
			set argv0 [lindex $arglist 0]
		}

		if {[info exists options(-user)] && ![_is_user $options(-user)]} {
			# we want to change user

			if {[id userid] == 0} {
				# we are root, run something that switches to the right user then runs the target
				# (we can't do this directly due to tclx limitations - it has no interface for
				# setgroups or initgroups, so we cannot drop/add subsidiary groups, which is a
				# security hole)
				set arglist [_make_droproot_args $options(-user) $argv0 {*}$arglist]
				set argv0 [lindex $arglist 0]
			} else {
				# we are not root, try to use sudo to change user
				# (except if -noroot was given, in which case all we care about
				# is that we're not root, so don't use sudo)
				if {![info exists options(-noroot)]} {
					if {![can_sudo $options(-user) {*}$arglist]} {
						return 0
					}

					set arglist [list {*}[auto_execok sudo] -n -u $options(-user) -- {*}$arglist]
					# we can't pass argv0 through sudo, and if we set argv0 then sudo itself will
					# use that when reporting errors which is really confusing, so reset it to
					# just "sudo"
					set argv0 "sudo"
				}
			}
		}

		# parse the redirects, open any files we need to, create pipes
		# we do this in the parent so the parent can see errors easily
		_prepare_read_redirect $options(-stdin) stdinChild cleanupList
		_prepare_write_redirect $options(-stdout) stdoutChild cleanupList
		_prepare_write_redirect $options(-stderr) stderrChild cleanupList

		if {$::fa_sudo::audit} {
			puts stderr "AUDIT: Going to run $arglist with stdin:$options(-stdin) stdout:$options(-stdout) stderr:$options(-stderr)"
		}

		# spawn things
		set childpid [fork]
		if {$childpid != 0} {
			# we are the parent, close anything we opened
			foreach fd $cleanupList {
				catch {close $fd}
			}

			return $childpid
		}

		# we are the child
		catch {
			# put the fds in the right places
			if {$stdinChild ne "stdin"} {
				dup $stdinChild stdin
			}

			if {$stdoutChild ne "stdout"} {
				dup $stdoutChild stdout
			}

			if {$stderrChild ne "stderr"} {
				dup $stderrChild stderr
			}

			foreach fd $cleanupList {
				catch {close $fd}
			}

			# do the exec
			# and hope that CLOEXEC is set on everything that matters
			execl -argv0 $argv0 [lindex $arglist 0] [lrange $arglist 1 end]
		}

		# if we got here, we are the child but we failed to exec, so
		# bail out.
		catch {puts stderr "$::errorInfo"}
		exit 42
	}

	proc _parse_exec_pipeline {_options args} {
		upvar $_options options

		set arglist {}
		for {set i 0} {$i < [llength $args]} {incr i} {
			set arg [lindex $args $i]

			switch -glob $arg {
				"|" | "|&" {
					error "Multi-stage pipelines are not supported"
				}

				"<@"   { incr i ; set options(-stdin) "@[lindex $args $i]" }
				"<"    { incr i ; set options(-stdin) "<[lindex $args $i]" }
				"<<*"  { error "here-documents are not supported" }
				"<@*"  { set options(-stdin) [string range $arg 1 end] }
				"<*"   { set options(-stdin) $arg }

				">>"   { incr i ; set options(-stdout) ">>[lindex $args $i]" }
				">@"   { incr i ; set options(-stdout) "@[lindex $args $i]" }
				">"    { incr i ; set options(-stdout) ">[lindex $args $i]" }
				">>*"  { set options(-stdout) $arg }
				">@*"  { set options(-stdout) [string range $arg 1 end] }
				">*"   { set options(-stdout) $arg }

				"2>>"  { incr i ; set options(-stderr) ">>[lindex $args $i]" }
				"2>@"  { incr i ; set options(-stderr) "@[lindex $args $i]" }
				"2>"   { incr i ; set options(-stderr) ">[lindex $args $i]" }
				"2>>*" { set options(-stderr) [string range $arg 1 end] }
				"2>@*" { set options(-stderr) [string range $arg 2 end] }
				"2>*"  { set options(-stderr) [string range $arg 1 end] }

				">>&"  { incr i ; set options(-stdout) ">>[lindex $args $i]" ; set options(-stderr) "@stdout" }
				">&@"  { incr i ; set options(-stdout) "@[lindex $args $i]" ; set options(-stderr) "@stdout" }
				">&"   { incr i ; set options(-stdout) ">[lindex $args $i]" ; set options(-stderr) "@stdout" }
				">>&*" { set options(-stdout) ">>[string range $arg 3 end]" ; set options(-stderr) "@stdout" }
				">&@*" { set options(-stdout) [string range $arg 2 end] ; set options(-stderr) "@stdout" }
				">&*"  { set options(-stdout) ">[string range $arg 2 end]" ; set options(-stderr) "@stdout" }

				default {
					lappend arglist $arg
				}
			}
		}

		return $arglist
	}

	# Like regular exec, but allows changing user/group (and doesn't gobble child status for other processes)
	#
	# exec_as
	#  ?-user user? ?-root? ?-nonroot?          # as for popen_as
	#  ?-returnall?                             # return a 4-tuple: pid, exit status, stdout, stderr.
	#                                           # For backgrounded pipelines on successful background start the "exit status" is 0 and stdout/stderr are empty.
	#  ?-ignorestderr? ?-keepnewline? ?--?      # as for exec
	#  program ?arg? ?arg?                      # as for exec
	#
	# limitations:
	#   << redirection not supported
	#   executing more than one command in a pipeline not supported
	proc exec_as {args} {
		# options
		set sudo 0
		set ignorestderr 0
		set keepnewline 0
		set returnall 0

		for {set i 0} {$i < [llength $args]} {incr i} {
			set arg [lindex $args $i]
			switch -glob $arg {
				-user {
					incr i
					set popts($arg) [lindex $args $i]
				}

				-root - -noroot {
					set popts($arg) 1
				}

				-ignorestderr {
					set ignorestderr 1
				}

				-keepnewline {
					set keepnewline 1
				}

				-returnall {
					set returnall 1
				}

				-- {
					incr i
					break
				}

				-* {
					error "unrecognized option: $arg"
				}

				default {
					break
				}
			}
		}

		set arglist [_parse_exec_pipeline popts {*}[lrange $args $i end]]
		if {[lindex $arglist end] eq "&"} {
			set background 1
			set arglist [lrange $arglist 0 end-1]
		} else {
			set background 0
		}

		# apply defaults if stdin/out/err weren't otherwise redirected

		if {![info exists popts(-stdin)]} {
			set popts(-stdin) "@stdin"
		}

		if {![info exists popts(-stdout)]} {
			if {$background} {
				set popts(-stdout) "@stdout"
			} else {
				set popts(-stdout) stdoutPipe
			}
		}

		if {![info exists popts(-stderr)]} {
			if {$background || $ignorestderr} {
				set popts(-stderr) "@stderr"
			} else {
				set popts(-stderr) stderrPipe
			}
		}

		# fire it up
		set childpid [popen_as -options [array get popts] -- {*}$arglist]

		set stdoutResult {}
		if {[info exists stdoutPipe]} {
			fconfigure $stdoutPipe -translation binary
			if {$keepnewline} {
				set stdoutResult [read $stdoutPipe]
			} else {
				set stdoutResult [read -nonewline $stdoutPipe]
			}
			close $stdoutPipe
		}

		set stderrResult {}
		if {[info exists stderrPipe]} {
			fconfigure $stderrPipe -translation binary
			if {$keepnewline} {
				set stderrResult [read $stderrPipe]
			} else {
				set stderrResult [read -nonewline $stderrPipe]
			}
			close $stderrPipe
		}

		if {$childpid == 0} {
			# failed to start because sudo refused to run it for us
			set result [list 0 SUDOFAILED SUDOFAILED]
		} elseif {$background} {
			set result [list 0 0 0]
		} else {
			set result [wait $childpid]
		}

		lassign $result deadpid status code

		if {$returnall} {
			return [list $deadpid $code $stdoutResult $stderrResult]
		} else {
			set errcode NONE
			set errmsg $stderrResult

			set exitmsg ""
			switch -glob $status:$code {
				EXIT:* {
					if {$code != 0} {
						set exitmsg "child process $childpid exited with status $code"
						set errcode [list CHILDSTATUS $childpid $code "exited with status $code"]
					}
				}

				SIG:* {
					set exitmsg "$stderrResult\nchild process $childpid killed by uncaught signal $code"
					set errcode [list CHILDKILLED $childpid $code "uncaught signal $code"]
				}

				SUDOFAILED:* {
					set exitmsg "$stderrResult\nsudo refused to start the command"
					set errcode [list SUDOFAILED $childpid 0 "sudo refused to start the command"]
				}

				default {
					set exitmsg "exited with unexpected status $status $code"
				}
			}

			if {$exitmsg ne ""} {
				if {$errmsg ne ""} {
					append errmsg "\n"
				}
				append errmsg $exitmsg
				if {$keepnewline} {
					append errmsg "\n"
				}
			}

			if {$errmsg ne ""} {
				return -code error -errorcode $errcode $errmsg
			} else {
				return $stdoutResult
			}
		}
	}

	# Like regular open-with-a-pipeline, but allows changing user/group (and doesn't
	# gobble child status for other processes)
	#
	# open_as
	#  ?-user user? ?-root? ?-nonroot?                             # as for popen_as
	#  ?-ignorestderr?                                             # as for exec
	#  ?--?                                                        # end of options
	#  file ?mode?                                                 # as for open
	#
	# limitations:
	#   << redirection not supported
	#   executing more than one command in a pipeline not supported
	#   file must be either a simple filename with mode = "r",
	#     or a pipeline starting with '|'
	#   [pid $f] will not work on the return value; use [::fa_sudo::pipeline pid $f]
	#
	proc open_as {args} {
		# options
		set sudo 0
		set ignorestderr 0

		for {set i 0} {$i < [llength $args]} {incr i} {
			set arg [lindex $args $i]
			switch -glob $arg {
				-user {
					incr i
					set popts($arg) [lindex $arg $i]
				}

				-root - -droproot {
					set popts($arg) 1
				}

				-ignorestderr {
					set ignorestderr 1
				}

				-- {
					incr i
					break
				}

				-* {
					error "unrecognized option: $arg"
				}

				default {
					break
				}
			}
		}

		lassign [lrange $args $i end] pipeline mode perms

		set chanmode {}
		if {$mode in {{} r r+ w+ a+}} {
			lappend chanmode "read"
		}
		if {$mode in {r+ w w+ w+ a a+}} {
			if {[info exists popts(-stdin)]} {
				error "access mode $mode requires write access to the pipeline, but stdin was redirected"
			}
			lappend chanmode "write"
		}

		if {$chanmode eq ""} {
			error "unrecognized access mode $mode"
		}

		if {[string index $pipeline 0] ne "|"} {
			if {"write" in $chanmode} {
				error "open_as can only open files readonly"
			}

			set pipeline [list cat $pipeline]
		} else {
			set pipeline [string range $pipeline 1 end]
		}

		set arglist [_parse_exec_pipeline popts {*}$pipeline]

		if {[lindex $arglist end] eq "&"} {
			error "can't background a sudo_open pipeline"
		}

		# apply defaults if stdin/out/err weren't otherwise redirected

		if {![info exists popts(-stdin)]} {
			if {"write" in $chanmode} {
				set popts(-stdin) stdinPipe
			} else {
				set popts(-stdin) "@stdin"
			}
		}

		if {![info exists popts(-stdout)]} {
			if {"read" in $chanmode} {
				set popts(-stdout) stdoutPipe
			} else {
				set popts(-stdout) "@stdout"
			}
		}

		if {![info exists popts(-stderr)]} {
			if {$ignorestderr} {
				set popts(-stderr) "@stderr"
			} else {
				set popts(-stderr) stderrPipe
			}
		}

		# fire it up
		set childpid [popen_as -options [array get popts] -- {*}$arglist]
		if {$childpid == 0} {
			error "failed to open pipeline: sudo refused to run the command"
		}

		# wrap the results in a channel
		set f [chan create $chanmode ::fa_sudo::pipeline]
		set ::fa_sudo::pipeline::childPid($f) $childpid
		if {[info exists stdinPipe]} {
			set ::fa_sudo::pipeline::childStdin($f) $stdinPipe
		}
		if {[info exists stdoutPipe]} {
			set ::fa_sudo::pipeline::childStdout($f) $stdoutPipe
		}
		if {[info exists stderrPipe]} {
			set ::fa_sudo::pipeline::childStderr($f) $stderrPipe
		}
		return $f
	}

	namespace eval pipeline {
		# Provides a channel handler interface to pipelines created via sudo_open
		# (see chan create)

		namespace export initialize finalize watch configure cget cgetall blocking read write pid

		proc initialize {channelId mode} {
			set supported {initialize finalize watch configure cget cgetall blocking}
			if {"read" in $mode} {
				lappend supported "read"
			}

			if {"write" in $mode} {
				lappend supported "write"
			}

			return $supported
		}

		proc finalize {channelId} {
			variable childStdin
			variable childStdout
			variable childStderr
			variable childPid

			set blocking 1
			if {[info exists childStdin($channelId)]} {
				if {![fconfigure $childStdin($channelId) -blocking]} {
					set blocking 0
				}
				close $childStdin($channelId)
				unset childStdin($channelId)
			}

			if {[info exists childStdout($channelId)]} {
				if {![fconfigure $childStdout($channelId) -blocking]} {
					set blocking 0
				}
				close $childStdout($channelId)
				unset childStdout($channelId)
			}

			set errcode "NONE"
			set errmsg {}
			if {[info exists childStderr($channelId)]} {
				set errmsg [::read $childStderr($channelId)]
				close $childStderr($channelId)
				unset childStderr($channelId)
			}

			if {[info exists childPid($channelId)]} {
				set cpid $childPid($channelId)
				if {$blocking} {
					lassign [wait $cpid] deadpid status code

					switch $status {
						EXIT {
							if {$code != 0} {
								if {[string index $errmsg end] ne "\n"} {
									append errmsg "\n"
								}
								append errmsg "child process $deadpid exited with status $code"
								set errcode [list CHILDSTATUS $deadpid $code]
							}
						}

						SIG {
							if {[string index $errmsg end] ne "\n"} {
								append errmsg "\n"
							}
							append errmsg "child process $deadpid killed by uncaught signal $code"
							set errcode [list CHILDKILLED $deadpid $code "uncaught signal $code"]
						}

						default {
							if {[string index $errmsg end] ne "\n"} {
								append errmsg "\n"
							}
							append errmsg "\n" "exited with unexpected status $status $code"
						}
					}
				}

				unset childPid($channelId)
			}

			if {$errmsg ne ""} {
				return -code error -errorcode $errcode $errmsg
			}
		}

		proc watch {channelId eventspec} {
			variable childStdin
			variable childStdout

			if {[info exists childStdout($channelId)]} {
				if {"read" in $eventspec} {
					fileevent $childStdout($channelId) readable [list chan postevent $channelId read]
				} else {
					fileevent $childStdout($channelId) readable ""
				}
			}

			if {[info exists childStdin($channelId)]} {
				if {"write" in $eventspec} {
					fileevent $childStdin($channelId) writable [list chan postevent $channelId write]
				} else {
					fileevent $childStdin($channelId) writable ""
				}
			}
		}

		proc read {channelId count} {
			variable childStdout

			if {[info exists childStdout($channelId)]} {
				return [::read $childStdout($channelId) $count]
			} else {
				return ""
			}
		}

		proc write {channelId data} {
			variable childStdin

			if {[info exists childStdin($channelId)]} {
				puts -nonewline $childStdin($channelId) $data
				return [string length $data]
			} else {
				error "pipeline is not writable"
			}
		}

		proc configure {channelId option value} {
			variable childStdin
			variable childStdout

			if {[info exists childStdout($channelId)]} {
				fconfigure $childStdout($channelId) $option $value
			}

			if {[info exists childStdin($channelId)]} {
				fconfigure $childStdin($channelId) $option $value
			}
		}

		proc cget {channelId option} {
			variable childStdin
			variable childStdout

			if {[info exists childStdin($channelId)]} {
				return [fconfigure $childStdin($channelId) $option]
			} elseif {[info exists childStdout($channelId)]} {
				return [fconfigure $childStdout($channelId) $option]
			} else {
				return ""
			}
		}

		proc cgetall {channelId} {
			variable childStdin
			variable childStdout

			if {[info exists childStdin($channelId)]} {
				array set opts [fconfigure $childStdin($channelId)]
			}

			if {[info exists childStdout($channelId)]} {
				array set opts [fconfigure $childStdout($channelId)]
			}

			return [array get opts]
		}

		proc blocking {channelId mode} {
			variable childStdin
			variable childStdout

			if {[info exists childStdin($channelId)]} {
				fconfigure $childStdin($channelId) -blocking $mode
			}

			if {[info exists childStdout($channelId)]} {
				fconfigure $childStdout($channelId) -blocking $mode
			}
		}

		proc pid {channelId} {
			variable childPid

			if {[info exists childPid($channelId)]} {
				return $childPid($channelId)
			} else {
				return ""
			}
		}

		namespace ensemble create
	}

} ;# namespace eval ::fa_sudo

package provide fa_sudo 0.1

