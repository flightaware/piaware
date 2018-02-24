package require fa_adept_codec 2.1

namespace eval ::fa_adept_schema {
	namespace eval internals {
		variable debug 0

		proc hexify {s} {
			set out ""
			for {set i 0} {$i < [string length $s]} {incr i} {
				scan [string index $s $i] "%c" ascii
				append out [format "%02X" $ascii]
			}
			return $out
		}

		proc define_proc {name args body} {
			variable debug

			if {$debug} {
				puts stderr "proc $name {$args} {$body}"
				puts stderr ""
			}
			proc $name $args $body
		}

		proc enum_encode {enumValues v} {
			set i [lsearch -exact -sorted $enumValues $v]
			if {$i < 0} {
				error "unknown enum value: $v"
			}
			return $i
		}

		proc enum_decode {enumValues v} {
			if {$v < 0 || $v >= [llength $enumValues]} {
				error "encoded enum out of range: $v"
			}
			return [lindex $enumValues $v]
		}

		proc flags_encode {flagValues vList} {
			set bits [string repeat "0" [llength $flagValues]]
			foreach flag $vList {
				set i [lsearch -exact -sorted $flagValues $flag]
				if {$i < 0} {
					# unencodeable flag value
					error "unknown flag value: $flag"
				}
				# inline K combinator here crashes 8.6.5, so do it the slow way
				# (this is probably https://core.tcl.tk/tcl/info/1af8de)
				set bits [string replace $bits $i $i "1"]
			}

			return $bits
		}

		proc flags_decode {flagValues v} {
			set results [list]
			for {set i [string first "1" $v]} {$i >= 0} {set i [string first "1" $v $i+1]} {
				lappend results [lindex $flagValues $i]
			}
			return $results
		}

		proc position_encode {v} {
			if {![string is list $v]} {
				error "bad position list"
			}

			if {[llength $v] != 4} {
				error "bad position list"
			}

			lassign $v lat lon nic rc
			if {![string is double -strict $lat] || $lat < -90 || $lat > 90} {
				error "position latitude out of range"
			}
			if {![string is double -strict $lon] || $lon < -180 || $lon > 180} {
				error "position longitude out of range"
			}
			if {![string is integer -strict $nic] || $nic < 0 || $nic > 255} {
				error "position NIC out of range"
			}
			if {![string is integer -strict $rc] || $rc < 0 || $rc > 65535} {
				error "position Rc out of range"
			}
			return [binary format "I I cu Su" [expr {round($lat * 100000)}] [expr {round($lon * 100000)}] $nic $rc]
		}

		proc position_decode {v} {
			binary scan $v "I I cu Su" lat lon nic rc
			return [format "%.5f %.5f %u %u" [expr {$lat / 100000.0}] [expr {$lon / 100000.0}] $nic $rc]
		}

		proc ident_encode {v} {
			set clean [string trim $v]
			if {[string length $clean] > 8} {
				error "ident too long"
			}
			return $clean
		}

		proc ident_decode {v} {
			return [string toupper [string map {\t {} \n {}} [string trim $v]]]
		}

		proc armor {s} {
			return [string map {\\ \\\\ \t \\t \n \\n} $s]
		}

		proc unarmor {s} {
			return [string map {\\\\ \\ \\t \t \\n \n} $s]
		}

		proc gen_encode_one_field {namesp def} {
			variable ${namesp}::definition::_meta_source_enum

			lassign $def field hasMeta format encoder decoder rangecheck
			if {$encoder eq ""} {
				set encoder {$v}
			}

			if {$hasMeta} {
				set v "\$_value"
				set encodeExpr [subst -nocommands -nobackslashes $encoder]
				set rangecheckExpr [subst -nocommands -nobackslashes $rangecheck]
				set innerBody [subst -nocommands {
					lassign \$row($field) _value _age _source
					if {!($rangecheckExpr)} {
						error "value out of range"
					}
					set d [binary format {cu cu $format} \$_age [::fa_adept_schema::internals::enum_encode {$_meta_source_enum} \$_source] $encodeExpr]
					if {$::fa_adept_schema::internals::debug} {
						puts stderr "$field: encoded as [::fa_adept_schema::internals::hexify \$d] ([string length \$d] bytes)"
					}
					append encodedData \$d
				}]
			} else {
				set v "\$row($field)"
				set encodeExpr [subst -nocommands -nobackslashes $encoder]
				set rangecheckExpr [subst -nocommands -nobackslashes $rangecheck]
				set innerBody [subst -nocommands {
					if {!($rangecheckExpr)} {
						error "value out of range"
					}
					set d [binary format {$format} $encodeExpr]
					if {$::fa_adept_schema::internals::debug} {
						puts stderr "$field: encoded as [::fa_adept_schema::internals::hexify \$d] ([string length \$d] bytes)"
					}
					append encodedData \$d
				}]
			}

			return [subst -nocommands {
				if {![info exists row($field)]} {
					append header 0
				} elseif {[catch {$innerBody} result]} {
					if {$::fa_adept_schema::internals::debug} {
						puts stderr "Caught error encoding $field: \$result"
					}
					append header 0
				} else {
					unset row($field)
					append header 1
				}
			}]
		}

		proc gen_encode {namesp fields} {
			# build the body
			set encodeFormat "B[llength $fields] a*"

			set encodeBody ""
			for {set fieldIndex 0} {$fieldIndex < [llength $fields]} {incr fieldIndex} {
				set def [lindex $fields $fieldIndex]
				append encodeBody [gen_encode_one_field $namesp $def]
			}

			set procBody [subst -nocommands {
				upvar \$_row row
				set encodedData ""
				$encodeBody
				if {[string length \$encodedData] > 0} {
					set row(!) [::fa_adept_schema::internals::armor [binary format {$encodeFormat} \$header \$encodedData]]
				}
			}]

			# define it
			define_proc ${namesp}::encode {_row} $procBody
		}

		proc gen_decode_setup_loop {namesp fields} {
			for {set fieldIndex 0} {$fieldIndex < [llength $fields]} {incr fieldIndex} {
				lassign [lindex $fields $fieldIndex] field hasMeta format encoder decoder rangecheck

				if {$hasMeta} {
					lappend formatStrList [list cu cu $format]
					lappend formatVarsList [list ${field}_age ${field}_source ${field}_value]
				} elseif {$decoder ne ""} {
					lappend formatStrList [list $format]
					lappend formatVarsList ${field}_value
				} else {
					lappend formatStrList [list $format]
					lappend formatVarsList row(${field})
				}
			}

			return [subst -nocommands {
				set formatStrList {$formatStrList}
				set formatVarsList {$formatVarsList}
				set formatStr ""
				set formatVars [list]
				set presentFields [list]
				for {set i [string first 1 \$header]} {\$i >= 0} {set i [string first 1 \$header \$i+1]} {
					lappend present \$i
					append formatStr [lindex \$formatStrList \$i]
					lappend formatVars {*}[lindex \$formatVarsList \$i]
				}
			}]
		}

		proc gen_decode_cleanup_loop {namesp fields} {
			variable ${namesp}::definition::_meta_source_enum

			for {set fieldIndex 0} {$fieldIndex < [llength $fields]} {incr fieldIndex} {
				lassign [lindex $fields $fieldIndex] field hasMeta format encoder decoder rangecheck
				if {$decoder eq "" && !$hasMeta} {
					continue
				}

				if {$decoder ne ""} {
					set v "\$${field}_value"
					set decodedValue [subst -nocommands -nobackslashes $decoder]
				} else {
					set decodedValue "\$${field}_value"
				}

				if {$hasMeta} {
					append switchBody [subst -nocommands {
						$fieldIndex {
							set row($field) [list $decodedValue \$${field}_age [::fa_adept_schema::internals::enum_decode {$_meta_source_enum} \$${field}_source]]
						}
					}]
				} {
					append switchBody [subst -nocommands {
						$fieldIndex {
							set row($field) $decodedValue
						}
					}]
				}
			}

			return [subst -nocommands {
				foreach i \$present {
					switch \$i {
						$switchBody
					}
				}
			}]
		}

		proc gen_decode {namesp fields} {
			# build the body
			set nFields [llength $fields]
			set headerFormat "B$nFields"
			set setupLoop [gen_decode_setup_loop $namesp $fields]
			set cleanupLoop [gen_decode_cleanup_loop $namesp $fields]

			set procBody [subst -nocommands {
				upvar \$_row row
				if {![info exists row(!)]} {
					return
				}

				# read the header to see what is present
				if {[binary scan [::fa_adept_schema::internals::unarmor \$row(!)] "$headerFormat a*" header input] < 1} {
					error "truncated message"
				}

				# prepare formatStr and formatVars to read all fields that are present
				$setupLoop

				# bulk read all the fields
				if {[binary scan \$input \$formatStr {*}\$formatVars] != [llength \$formatVars]} {
					error "truncated message"
				}

				# do final cleanup on fields that we read
				$cleanupLoop
				unset row(!)
			}]

			# define it
			define_proc ${namesp}::decode {_row} $procBody
		}

		proc gen_version {namesp version} {
			define_proc ${namesp}::version {} [list return $version]
		}
	}

	proc define {name version code} {
		set namesp ::fa_adept_codecs::${name}_${version}
		if {[namespace exists $namesp]} {
			namespace delete $namesp
		}

		# build a "definition" namespace that defines the DSL commands
		namespace eval ${namesp}::definition {
			variable _fieldExists
			array set _fieldExists {}
			variable _fields {}

			proc _direct_field {name format encoder decoder rangecheck args} {
				variable _fields
				variable _fieldExists
				if {[info exists _fieldExists($name)]} {
					error "duplicated field: $name"
				}
				lappend _fields [list $name [expr {"-nometa" ni $args}] $format $encoder $decoder $rangecheck]
				set _fieldExists($name) 1
			}

			proc meta_source_enum {values} {
				variable _meta_source_enum

				if {[info exists _meta_source_enum]} {
					error "meta_source_enum duplicated"
				}

				for {set i 0} {$i < [llength $values]-1} {incr i} {
					set vname [lindex $values $i]
					if {$vname in [lrange $values $i+1 end]} {
						error "Duplicated enum name: $vname"
					}
				}

				set _meta_source_enum [lsort $values]
			}

			proc enum {values name args} {
				for {set i 0} {$i < [llength $values]-1} {incr i} {
					set vname [lindex $values $i]
					if {$vname in [lrange $values $i+1 end]} {
						error "Duplicated enum name: $vname"
					}
				}

				set values [lsort $values]
				set encoder "\[::fa_adept_schema::internals::enum_encode [list $values] \$v\]"
				set decoder "\[::fa_adept_schema::internals::enum_decode [list $values] \$v\]"
				_direct_field $name "cu" $encoder $decoder "1" {*}$args
			}

			proc flags {values name args} {
				for {set i 0} {$i < [llength $values]-1} {incr i} {
					set vname [lindex $values $i]
					if {$vname in [lrange $values $i+1 end]} {
						error "Duplicated flag name: $vname"
					}
				}

				set values [lsort $values]
				set format "B[llength $values]"
				set encoder "\[::fa_adept_schema::internals::flags_encode [list $values] \$v\]"
				set decoder "\[::fa_adept_schema::internals::flags_decode [list $values] \$v\]"
				_direct_field $name $format $encoder $decoder "1" {*}$args
			}

			proc signed {precision args} {
				_integer "" $precision {*}$args
			}

			proc unsigned {precision args} {
				_integer "u" $precision {*}$args
			}

			proc _integer {extraFormat precision name args} {
				lassign [split $precision "/"] width dp
				if {$width eq "" || $dp eq ""} {
					error "missing precision"
				}

				set places [expr {$width + $dp}]
				if {$places <= 2} { # -99 .. 99 fits in 8 bits
					set format c
				} elseif {$places <= 4} { # -9,999 .. 9,999 fits in 16 bits
					set format S
				} elseif {$places <= 9} { # -999,999,999 .. 999,999,999 fits in 32 bits
					set format I
				} else {
					set format W
				}

				set high "[string repeat 9 $width].[string repeat 9 $dp]5"

				if {$extraFormat eq "u"} {
					set rangecheck [subst -nocommands {[string is double -strict \$v] && \$v >= 0 && \$v < $high}]
				} else {
					set rangecheck [subst -nocommands {[string is double -strict \$v] && \$v > -$high && \$v < $high}]
				}

				if {$dp > 0} {
					set shift [expr {10.0 ** $dp}]
					set encoder [subst -nocommands {[expr {round(\$v * $shift)}]}]
					set decoder [subst -nocommands {[format %.${dp}f [expr {\$v / $shift}]]}]
				} else {
					set encoder ""
					set decoder ""
				}

				_direct_field $name "${format}${extraFormat}" $encoder $decoder $rangecheck {*}$args
			}

			proc hexdigits {width name args} {
				if {$width <= 0} {
					error "field $name declared with bad width $width"
				}
				set rangecheck [subst -nocommands {[string is xdigit -strict \$v] && [string length \$v] <= $width}]
				_direct_field $name H${width} {} {[string toupper $v]} $rangecheck {*}$args
			}

			proc identstring {name args} {
				set encoder "\[::fa_adept_schema::internals::ident_encode \$v\]"
				set decoder "\[::fa_adept_schema::internals::ident_decode \$v\]"
				_direct_field $name A8 $encoder $decoder "1" {*}$args
			}

			proc position {name args} {
				set encoder "\[::fa_adept_schema::internals::position_encode \$v\]"
				set decoder "\[::fa_adept_schema::internals::position_decode \$v\]"
				_direct_field $name a11 $encoder $decoder "1" {*}$args
			}

			proc epoch {name args} {
				set rangecheck [subst -nocommands {[string is wideinteger -strict \$v] && \$v >= 0}]
				_direct_field $name Wu {} {} $rangecheck {*}$args
			}
		}

		# run the definition code we were given
		namespace eval ${namesp}::definition $code

		if {![info exists ${namesp}::definition::_meta_source_enum]} {
			error "no meta_source_enum defined"
		}

		if {[info exists internals::registry($version)]} {
			error "codec with version $version is already defined"
		}

		# sort fields by name
		set sorted [lsort -index 0 [set ${namesp}::definition::_fields]]

		# build the actual code
		internals::gen_version $namesp $version
		internals::gen_encode $namesp $sorted
		internals::gen_decode $namesp $sorted

		namespace eval $namesp {
			namespace export encode decode version
			namespace ensemble create
		}

		# no longer need the definition namespace, clean it up
		namespace delete ${namesp}::definition

		# these codecs are stateless, so just return the ensemble command
		::fa_adept_codec::register $name $version [list expr \{$namesp\} ]
		return $namesp
	}

	namespace export define
}

package provide fa_adept_schema 2.1
