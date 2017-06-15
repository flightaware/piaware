package require Itcl

# A package to handle encoding/decoding of a more compact form of the TSV data
# emitted by faup1090. The compact form is what is sent over the network, and
# it is reexpanded on the server side.
#
# This package is shared between piaware and fa_adept_server - make sure to
# keep them in sync. If the schema needs to change, bump the version number so
# the server can continue to handle older clients correctly.

# NB: this code needs to stay tcl8.5-compatible for piaware on wheezy

namespace eval ::fa_adept_codec {
	# Identity codec that does nothing. Used for messages before the login
	# handshake indicates a version to use.
	::itcl::class IdentityCodec {
		constructor {args} {
			configure {*}$args
		}

		# return the compression_version for this codec
		public method version {} {
			return ""
		}

		public method encode_array {_row} {}
		public method decode_array {_row} {}
	}

	# Codec class for the newer encoding scheme.  The encoded form has
	# one bit per field packed into the start of the message to
	# indicate presence/absence of that field. Then all present fields
	# are encoded in order. The encoded data is put into a field with
	# key '!'
	::itcl::class Codec {
		public variable schema "" { recompile_schema }
		public variable version
		protected variable compiled_schema

		# required options:
		#  -schema   list-of-lists field schema
		#  -version  codec version
		constructor {args} {
			configure {*}$args
		}

		# return the compression_version for this codec
		public method version {} {
			return $version
		}

		# preprocess "schema" and produce "compiled_schema"
		private method recompile_schema {} {
			set s [list]

			foreach entry $schema {
				lassign $entry field encoding enc_args cleanup_type cleanup_args

				switch -exact -- $cleanup_type {
					"toupper" - "format" - "cleanstring" - "" {
						# OK
					}

					default {
						error "field $field has unrecognized cleanup type $cleanup_type"
					}
				}

				switch -exact -- $encoding {
					binary {
						lappend s [list $field $encoding $enc_args $cleanup_type $cleanup_args]
					}

					enum {
						if {[llength $enc_args] == 0} {
							error "field $field with encoding enum does not specify any enum values"
						}
						if {[llength $enc_args] > 255} {
							error "field $field with encoding enum specifies too many enum values ([llength $enc_args] > 255)"
						}
						# sort enum list
						lappend s [list $field $encoding [lsort $enc_args] $cleanup_type $cleanup_args]
					}

					flags {
						# sort flag list
						lappend s [list $field $encoding [lsort $enc_args] $cleanup_type $cleanup_args]
					}

					default {
						error "field $field has unhandled encoding $encoding"
					}
				}
			}

			set compiled_schema [lsort -index 0 $s]
		}

		# encode one field value using the given encoding
		# return the encoded value, or an empty string if it couldn't be
		# encoded
		private proc encode_field {value encoding enc_args} {
			switch -exact -- $encoding {
				binary {
					# enc_args is the "binary format" format string to use
					if {[catch {binary format $enc_args $value} result]} {
						return ""
					} else {
						return $result
					}
				}

				flags {
					# enc_args is a list of possible flags;
					# value is a list of set flags
					set bits [string repeat "0" [llength $enc_args]]
					foreach flag $value {
						set i [lsearch -exact -sorted $enc_args $flag]
						if {$i < 0} {
							# unencodeable flag value
							return ""
						}
						# inline K combinator here crashes 8.6.5, so do it the slow way
						# (this is probably https://core.tcl.tk/tcl/info/1af8de)
						set bits [string replace $bits $i $i "1"]
					}

					return [binary format "B*" $bits]
				}

				enum {
					# enc_args is a list of possible enum values;
					# value is an enum value
					set i [lsearch -exact -sorted $enc_args $value]
					if {$i < 0} {
						# unencodeable enum value
						return ""
					}
					return [binary format "cu" $i]
				}

				default {
					return ""
				}
			}
		}

		# modify an array in place, encoding and removing keys that can be
		# encoded
		public method encode_array {_row} {
			upvar $_row row

			# Process fields one at a time rather than constructing a big
			# "binary format" format string (like we do in decode_array).
			# The encode side is not so performance-critical compared to
			# the server side as individual piawares are not processing all
			# that much data, and processing fields individually lets us
			# handle unencodeable values gracefully

			set binData ""
			set flags ""
			foreach entry $compiled_schema {
				lassign $entry field encoding enc_args

				set flag "0"
				if {[info exists row($field)]} {
					set encoded [encode_field $row($field) $encoding $enc_args]
					if {$encoded ne ""} {
						set flag "1"
						append binData $encoded
						unset row($field)
					}
				}

				append flags $flag
			}

			if {$binData eq ""} {
				return
			}

			set flagFormat B[llength $compiled_schema]
			set row(!) [string map {\t \\t \\ \\\\ \n \\n} [binary format $flagFormat $flags]$binData]
		}

		# takes the output of "binary scan" for a string value and return a
		# cleaned-up value (trimmed, no unsafe characters)
		private proc clean_string {value} {
			return [string toupper [string map {\t {} \n {}} [string trim $value]]]
		}

		# given a list of possible flags and an encoded value, expand the value to a list of flags
		private proc decode_flags {flagslist value} {
			set results [list]
			for {set i [string first "1" $value]} {$i >= 0} {set i [string first "1" $value $i+1]} {
				lappend results [lindex $flagslist $i]
			}
			return $results
		}

		# modify an array in place, reversing the effects of encode_array
		public method decode_array {_row} {
			upvar $_row row
			if {![info exists row(!)]} {
				return
			}

			set binData [string map {\\t \t \\n \n \\\\ \\} $row(!)]
			set n [llength $compiled_schema]
			binary scan $binData "B$n" flags

			set flagbytes [expr {int(($n + 7) / 8)}]
			set scanFormat "x$flagbytes "            ;# "binary scan" format arg
			set scanVars [list]                      ;# variables to scan into
			set postscript [list]                    ;# list of stuff to do after the scan

			for {set i [string first "1" $flags]} {$i >= 0} {set i [string first "1" $flags $i+1]} {
				lassign [lindex $compiled_schema $i] field encoding enc_args cleanup_type cleanup_args
				switch -exact -- $encoding {
					binary {
						append scanFormat $enc_args
						lappend scanVars "row($field)"
					}

					enum {
						append scanFormat "cu"
						lappend scanVars "row($field)"
						lappend postscript $field enum $enc_args
					}

					flags {
						append scanFormat "B[llength $enc_args]"
						lappend scanVars "row($field)"
						lappend postscript $field flags $enc_args
					}
				}

				if {$cleanup_type ne ""} {
					lappend postscript $field $cleanup_type $cleanup_args
				}
			}

			# snarf all the data
			binary scan $binData $scanFormat {*}$scanVars

			# do any postprocessing required
			foreach {field action extra} $postscript {
				switch -exact -- $action {
					enum {
						set row($field) [lindex $extra $row($field)]
					}

					flags {
						set row($field) [decode_flags $extra $row($field)]
					}

					toupper {
						set row($field) [string toupper $row($field)]
					}

					format {
						set row($field) [format $extra $row($field)]
					}

					cleanstring {
						set row($field) [clean_string $row($field)]
					}
				}
			}

			unset row(!)
		}
	}  ;# ::itcl::class Codec

	# Codec class for the legacy encoding scheme.
	#
	# This has a field with key '!' followed by a series of letters indicating which
	# fields are packed (in that order) into the value. For simplicity this codec
	# decodes only.
	::itcl::class OldCodec {
		public variable version
		protected variable lastDecompressClock 0
		protected common decompressVar
		protected common decompressFormat

		foreach "var keyChar format" "clock c I sent_at C I hexid h H6 ident i A8 alt a I lat l R lon m R speed s S squawk q H4 heading H S" {
			set decompressVar($keyChar) $var
			set decompressFormat($keyChar) $format
		}

		constructor {args} {
			configure {*}$args
		}

		public method version {} {
			return $version
		}

		public method encode_array {_row} {
			error "not implemented"
		}

		public method decode_array {_row} {
			upvar $_row row

			foreach var [array names row] {
				if {[string index $var 0] != "!"} {
					continue
				}

				decompress_kv_to_array row $var $row($var)
				unset row($var)
			}
		}

		private method decompress_kv_to_array {_row key value} {
			upvar $_row row

			set scanString ""
			set varList [list]
			foreach char [split [string range $key 1 end] ""] {
				if {$char == "g"} {
					set row(airGround) "G"
					continue
				}

				if {![info exists decompressVar($char)]} {
					error "unrecognized compression char '$char'"
				}

				append scanString $decompressFormat($char)
				foreach oneVar $decompressVar($char) {
					lappend varList row($oneVar)
				}
			}

			# remap backslashes, tabs and neslines to their real deal
			set value [string map {\\t \t \\\\ \\ \\n \n} $value]

			# binary scan out all the values
			binary scan $value $scanString {*}$varList

			# substitute back in the clock if it was taken out
			if {[info exists row(clock)]} {
				set lastDecompressClock $row(clock)
			} else {
				set row(clock) $lastDecompressClock
			}

			# trim any spaces off the ends of the ident
			if {[info exists row(ident)]} {
				set row(ident) [string toupper [string map {\t {} \n {}} [string trim $row(ident)]]]
			}

			# map hexid back to uppercase for consistency
			if {[info exists row(hexid)]} {
				set row(hexid) [string toupper $row(hexid)]
			}

			# appropriate round lat and lon back off
			if {[info exists row(lat)]} {
				set row(lat) [format "%.5f" $row(lat)]
			}

			if {[info exists row(lon)]} {
				set row(lon) [format "%.5f" $row(lon)]
			}
		}
	}  ;# ::itcl::class OldCodec

	# Given a compression_version, create a codec for it.
	# If the version is omitted the latest codec is returned.
	proc new_codec {{version 2.0}} {
		switch -glob -- $version {
			"" - none {
				return [uplevel 1 [list ::fa_adept_codec::IdentityCodec #auto]]
			}

			1.* {
				return [uplevel 1 [list ::fa_adept_codec::OldCodec #auto -version $version]]
			}

			2.0 {
				return [uplevel 1 [list ::fa_adept_codec::Codec #auto -version $version -schema {
					{clock          binary Iu}
					{sent_at        binary Iu}
					{hexid          binary H6 toupper}
					{otherid        binary H6 toupper}
					{addrtype       enum   {adsb_icao adsb_icao_nt adsr_icao tisb_icao adsb_other adsr_other tisb_other tisb_trackfile}}
					{ident          binary A8 cleanstring}
					{iSource        enum   {modes adsb tisb}}
					{squawk         binary H4}
					{alt            binary I}
					{alt_geom       binary I}
					{baro_rate      binary S}
					{geom_rate      binary S}
					{gs             binary Su}
					{ias            binary Su}
					{tas            binary Su}
					{mach           binary R format %.3f}
					{lat            binary R format %.5f}
					{lon            binary R format %.5f}
					{track          binary Su}
					{track_rate     binary R format %.2f}
					{roll           binary R format %.1f}
					{mag_heading    binary Su}
					{airGround      enum   {A+ G+}}
					{category       binary H2 toupper}
					{intent_alt     binary I}
					{intent_heading binary Su}
					{alt_setting    binary R format %.1f}
					{datalink_caps  binary H14 toupper}
					{es_op_status   binary H14 toupper}
					{tisb           flags  {ident squawk alt alt_geom gs ias tas lat lon track mag_heading airGround category intent_alt intent_heading alt_setting}}
				}]]
			}

			default {
				error "unsupported codec version $version"
			}
		}
	}

} ;# namespace eval  ::fa_adept_codec

package provide fa_adept_codec 2.0
