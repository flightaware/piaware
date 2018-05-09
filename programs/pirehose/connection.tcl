proc handle_client_connection {sock} {
	setproctitle "TLS handshake"

	# give TLS 60 seconds to complete or we trap with an alarm clock
	alarm 60

	try {
		fcntl $sock KEEPALIVE 1
		chan configure $sock -blocking 1 -translation binary

		set cipherlist "ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-AES256-GCM-SHA384:DHE-RSA-AES128-GCM-SHA256:DHE-DSS-AES128-GCM-SHA256:kEDH+AESGCM:ECDHE-RSA-AES128-SHA256:ECDHE-ECDSA-AES128-SHA256:ECDHE-RSA-AES128-SHA:ECDHE-ECDSA-AES128-SHA:ECDHE-RSA-AES256-SHA384:ECDHE-ECDSA-AES256-SHA384:ECDHE-RSA-AES256-SHA:ECDHE-ECDSA-AES256-SHA:DHE-RSA-AES128-SHA256:DHE-RSA-AES128-SHA:DHE-DSS-AES128-SHA256:DHE-RSA-AES256-SHA256:DHE-DSS-AES256-SHA:DHE-RSA-AES256-SHA:AES128-GCM-SHA256:AES256-GCM-SHA384:AES128-SHA256:AES256-SHA256:AES128-SHA:AES256-SHA:AES:CAMELLIA:DES-CBC3-SHA:!aNULL:!eNULL:!EXPORT:!DES:!RC4:!MD5:!PSK:!aECDH:!EDH-DSS-DES-CBC3-SHA:!EDH-RSA-DES-CBC3-SHA:!KRB5-DES-CBC3-SHA:!EDH"
		::tls::import $sock \
			-cipher $cipherlist \
			-ssl2 0 \
			-ssl3 0 \
			-tls1 1 \
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
# ignore the content, just watch for EOF or errors
#
proc read_client_discard {sock} {
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

	if {$line eq ""} {
		# nothing this time
		return
	}

	# silently swallow it
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
