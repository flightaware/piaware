namespace eval ::fa_adept_schema {
	namespace eval internals {
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

		proc armor {s} {
			return [string map {\\ \\\\ \t \\t \n \\n} $s]
		}

		proc unarmor {s} {
			return [string map {\\\\ \\ \\t \t \\n \n} $s]
		}
	
		proc gen_encode_one_field {namesp def} {
			variable ${namesp}::definition::_meta_source_enum
			
			lassign $def field hasMeta format encoder decoder
			if {$encoder eq ""} {
				set encoder {$v}
			}

			if {$hasMeta} {
				set v "\$_value"
				set encodeExpr [subst -nocommands -nobackslashes $encoder]
				set innerBody [subst -nocommands {
					lassign \$row($field) _value _age _source
					append encodedData [binary format {cu cu $format} \$_age [::fa_adept_schema::internals::enum_encode {$_meta_source_enum} \$_source] $encodeExpr]
				}]
			} else {
				set v "\$row($field)"
				set encodeExpr [subst -nocommands -nobackslashes $encoder]
				set innerBody [subst -nocommands {
					append encodedData [binary format {$format} $encodeExpr]
				}]
			}

			return [subst -nocommands {
				if {![info exists row($field)] || [catch {$innerBody}]} {
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
			proc ${namesp}::encode {_row} $procBody
		}

		proc gen_decode_setup_loop {namesp fields} {
			for {set fieldIndex 0} {$fieldIndex < [llength $fields]} {incr fieldIndex} {
				lassign [lindex $fields $fieldIndex] field hasMeta format encoder decoder

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
				lassign [lindex $fields $fieldIndex] field hasMeta format encoder decoder
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
			proc ${namesp}::decode {_row} $procBody
		}

		proc gen_version {namesp version} {
			proc ${namesp}::version {} [list return $version]
		}
	}

	proc define {name version code} {
		if {[exists $name $version]} {
			error "$name schema version $version already exists"
		}

		set namesp ::fa_adept_schema::${name}_${version}
		
		# build a "definition" namespace that defines the DSL commands		
		namespace eval ${namesp}::definition {
			variable _fieldExists
			array set _fieldExists {}
			variable _fields {}

			proc _direct_field {name format encoder decoder args} {
				variable _fields
				variable _fieldExists
				if {[info exists _fieldExists($name)]} {
					error "duplicated field: $name"
				}
				lappend _fields [list $name [expr {"-nometa" ni $args}] $format $encoder $decoder]
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
				_direct_field $name "cu" $encoder $decoder {*}$args
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
				_direct_field $name $format $encoder $decoder {*}$args
			}

			proc integer {range name args} {
				lassign $range low high
				if {$low eq "" || $high eq ""} {
					error "missing range bounds"
				}
				if {$high < $low} {
					error "bad integer bounds: $low,$high"
				}

				if {$low < 0} {
					# signed
					if {$low >= -128 && $high <= 127} {
						set format c
					} elseif {$low >= -32768 && $high <= 32767} {
						set format S
					} elseif {$low >= -2147483648 && $high <= 2147483647} {
						set format I
					} elseif {$low >= -9223372036854775808 && $high <= 9223372036854775807} {
						set format W
					} else {
						error "can't handle an integer with bounds $low,$high"
					}
				} else {
					# unsigned
					if {$high <= 255} {
						set format cu
					} elseif {$high <= 65535} {
						set format Su
					} elseif {$high <= 4294967295} {
						set format Iu
					} elseif {$high <= 18446744073709551615} {
						set format W
					} else {
						error "can't handle an integer with bounds $low,$high"
					}
				}

				_direct_field $name $format {} {} {*}$args
			}

			proc hexdigits {width name args} {
				if {$width <= 0} {
					error "field $name declared with bad width $width"
				}
				_direct_field $name H${width} {} {[string toupper $v]} {*}$args
			}

			proc identstring {width name args} {
				if {$width <= 0} {
					error "field $name declared with bad width $width"
				}

				set cleanup {[string toupper [string map {\t {} \n {}} [string trim $v]]]}
				_direct_field $name A${width} $cleanup $cleanup {*}$args
			}

			proc decimal {precision name args} {
				if {$precision <= 0} {
					error "field $name declared with bad precision $precision"
				}
				set decoder [subst -nocommands {[format %.${precision}f \$v]}]
				_direct_field $name R {} $decoder {*}$args
			}

			proc latlon {name args} {
				set decoder [subst -nocommands {[format "%.5f %.5f" {*}\$v]}]
				_direct_field $name R2 {} $decoder {*}$args
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
		register $name $version [list expr \{$namesp\} ]
		return $namesp
	}

	proc exists {name version} {
		return [expr {[info exists internals::registry($name-$version)]}]
	}
	
	proc register {name version command} {
		if {[exists $name $version] && [find $name $version] ne $command} {
			error "$name schema version $version is already registered to a different command"
		}

		set internals::registry($name-$version) $command
	}

	proc new_codec {name version} {
		if {[info exists internals::registry($name-$version)]} {
			return [uplevel 1 $internals::registry($name-$version)]
		} else {
			error "no $name schema registered with version $version"
		}
	}

	namespace export define register exists new_codec
}

package provide fa_adept_schema 1.0
