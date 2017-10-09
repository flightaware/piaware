set ::childPipes [list]   ;# List of child process pipes being supplied with data

# start listening on $::params(port)
proc start_listening {} {
	set ::listenSocket [socket -server accept_connection $::params(port)]
	logger "Listening for firehose connections on port $::params(port)"
}

# stop any existing listener
proc stop_listening {} {
	if {[info exists ::listenSocket]} {
		catch {close $::listenSocket}
		unset -nocomplain ::listenSocket
	}
}

# callback when a new client connection is accepted
proc accept_connection {sock clientAddr clientPort} {
	lassign [chan pipe] pipeRead pipeWrite

	flush stdout
	flush stderr
	try {
		set childpid [fork]
	} on error {result} {
		logger "failed to fork: $result"
		catch {close $pipeRead}
		catch {close $pipeWrite}
		catch {close $sock}
		return
	}

	if {$childpid == 0} {
		# I am the child

		try {
			set ::logPrefix "pirehose $clientAddr:$clientPort"

			foreach pipe $::childPipes {
				catch {close $pipe}
			}

			stop_reaping
			stop_listening
			stop_reading_stdin
			dup $pipeRead stdin
			close $pipeRead
			close $pipeWrite
			handle_client_connection $sock
			vwait forever  ;# nested, but that's fine
		} on error {result} {
			logger "Caught '$result' from forked_child_handler: $::errorInfo"
		} finally {
			exit 99
		}
	}

	# I am the parent
	logger "Spawned child $childpid for client connection from $clientAddr:$clientPort"
	catch {close $sock}
	catch {close $pipeRead}

	chan configure $pipeWrite -blocking 0 -buffering full -encoding ascii -translation lf
	lappend ::childPipes $pipeWrite
}

# start reading and forwarding TSV lines from stdin
proc start_reading_stdin {} {
	chan configure stdin -buffering line -blocking 0 -encoding ascii -translation lf
	chan event stdin readable [list forward_data_to_children stdin]
}

# stop reading TSV lines from stdin
proc stop_reading_stdin {} {
	chan event stdin readable ""
}

# callback when TSV data is ready for forwarding
proc forward_data_to_children {f} {
	set lines [list]

	# read a batch of lines
	try {
		while {1} {
			set count [gets $f line]
			if {$count < 0} {
				if {[eof $f]} {
					# Server EOF
					logger "Parent saw EOF, exiting"
					catch {close $f}
					set ::die 1
					return
				}

				# no more data
				break
			}
			lappend lines $line
		}
	} on error {result} {
		logger "error reading data: $result"
		catch {close $f}
		set ::die 1
		return
	}

	if {$lines eq ""} {
		# no complete line ready yet
		return
	}

	# forward the whole batch to each child in turn
	foreach pipe $::childPipes {
		try {
			foreach line $lines {
				puts $pipe $line
			}
			flush $pipe
		} on error {result} {
			# clean up on dead child
			catch {close $pipe}
			set i [lsearch -exact $::childPipes $pipe]
			set ::childPipes [lreplace $::childPipes $i $i]
		}
	}
}
