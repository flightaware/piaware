proc handle_client_connection {sock} {
	setproctitle "TLS handshake"

	# give TLS 60 seconds to complete or we trap with an alarm clock
	alarm 60

	try {
		fcntl $sock KEEPALIVE 1
		chan configure $sock -blocking 1 -translation binary

		::tls::import $sock \
			-ssl2 0 \
			-ssl3 0 \
			-tls1 0 \
			-tls1.1 0 \
			-tls1.2 0 \
			-tls1.3 1 \
			-server 1 \
			-certfile $::params(certfile) \
			-keyfile $::params(keyfile)

		::tls::handshake $sock
	} on error {result} {
		logger "TLS handshake failed: $result"
		child_exit 1
	}

	logger "TLS handshake complete: [::tls::status $sock]"
	setproctitle "waiting for initiation command"

	chan configure $sock -blocking 0 -buffering line -encoding ascii -translation {auto lf}
	chan configure stdin -blocking 0 -buffering line -encoding ascii -translation lf

	chan event $sock readable [list read_client_initiation $sock]
	chan event stdin readable [list read_parent]

	periodically_cleanup_aircraft
}

#
# handle data from the client after initiation command
# watch for EOF or errors
# reject additional input
#
proc read_client_post_init {sock} {
	try {
		set count [gets $sock line]
	} on error {result} {
		logger "client read error: $result"
		child_exit 1
	}

	if {$count < 0} {
		logger "client EOF"
		child_exit 0
	}

	if {$count > 0} {
		logger "client sent extra data after initiation"
		write_to_client "Error: already specified connection mode line"
		child_exit 2
	}
}

proc write_to_client {line} {
	if {![info exists ::clientSock]} {
		return
	}

	try {
		puts $::clientSock $line
		set ::lastActive [clock milliseconds]
		if {![info exists ::needsFlush]} {
			set ::needsFlush $::lastActive
		}
	} on error {result} {
		logger "error writing to client: $result"
		child_exit 1
	}
}

proc child_exit {{rv 0}} {
	logger "child exiting with status $rv"
	if {[info exists ::clientSock]} {
		catch {close $::clientSock}
	}
	exit $rv
}

proc periodically_check_keepalive {} {
	set expiry [expr {$::lastActive + $::keepaliveInterval * 1000 - [clock milliseconds]}]
	if {$expiry <= 0} {
		set keepalive(type) "keepalive"
		set keepalive(pitr) [clock seconds]
		set keepalive(serverTime) [clock seconds]
		write_to_client [::json::write object {*}[array get keepalive]]
		set expiry [expr {$::keepaliveInterval * 1000}]
	}

	after [expr {$expiry + 5}] periodically_check_keepalive
}

proc periodically_syncflush_output {} {
	if {[info exists ::needsFlush]} {
		set expiry [expr {$::needsFlush + $::syncflushInterval - [clock milliseconds]}]
		if {$expiry <= 0} {
			try {
				flush $::clientSock
				chan configure $::clientSock -flush sync
				flush $::clientSock
			} on error {result} {
				logger "failed to flush data to client: $result"
				client_exit 1
			}
			unset ::needsFlush
			set expiry $::syncflushInterval
		}
	} else {
		set expiry $::syncflushInterval
	}

	after [expr {$expiry + 5}] periodically_syncflush_output
}
