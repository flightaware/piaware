#
# fa_piaware_config - unified config reader/writer
# for the various config sources that piaware and the
# piaware sdcard image can use.
#
# Copyright (C) 2016-2018 FlightAware LLC, All Rights Reserved
#
#

package require Itcl
package require tryfinallyshim
package require fa_sudo
package require Tclx

namespace eval ::fa_piaware_config {
	# a note on empty values vs. defaults
	#
	# empty values are equivalent to missing values
	# if a value is empty or missing and there is a default, the default is applied
	# you can't override a default with an empty value
	#  (setting an empty value returns that key to its default)
	# explitly empty values will "white out" any non-empty value in a lower-priority file

	set helperPath [file join [file dirname [info script]] "helpers" "update-piaware-config"]

	proc new {klass name args} {
		# blergh. itcl makes this difficult
		# acts like running $klass $name $args directly,
		# but returns the fully-qualified command name so
		# it can be used from other namespaces
		set cmd [uplevel 1 [list $klass] [list $name] $args]
		return [uplevel 1 namespace which -command $cmd]
	}

	proc valid_mac {mac} {
		return [regexp -nocase {^[a-z0-9]{2}:[a-z0-9]{2}:[a-z0-9]{2}:[a-z0-9]{2}:[a-z0-9]{2}:[a-z0-9]{2}$} $mac]
	}

	proc valid_uuid {uuid} {
		return [regexp -nocase {^[a-z0-9]{8}-[a-z0-9]{4}-[a-z0-9]{4}-[a-z0-9]{4}-[a-z0-9]{12}$} $uuid]
	}

	proc valid_country_code {code} {

		# Find better way to do this?
		set supportedCountryCodes {
			AD AE AF AG AI AL AM AO AQ AR AS AT AU AW AX AZ BA BB BD BE BF BG BH BI BJ BL
			BM BN BO BQ BR BS BT BV BW BY BZ CA CC CD CF CG CH CI CK CL CM CN CO CR CU CV
			CW CX CY CZ DE DJ DK DM DO DZ EC EE EG EH ER ES ET FI FJ FK FM FO FR GA GB GD
			GE GF GG GH GI GL GM GN GP GQ GR GS GT GU GW GY HK HM HN HT HU ID IE IL IM IN
			IO IQ IR IS IT JE JM JO JP KE KG KH KI KM KN KP KR KW KY KZ LA LB LC LI LK LR
			LS LT LU LV LY MA MC MD ME MF MG MH MK ML MM MN MO MP MQ MR MS MT MU MV MW MX
			MY MZ NA NC NE NF NG NI NL NO NP NR NU NZ OM PA PE PF PG PH PK PL PM PN PR PS
			PT PW PY QA RE RO RS RU RW SA SB SC SD SE SG SH SI SJ SK SL SM SN SO SR SS ST
			SV SX SY SZ TC TD TF TG TH TJ TK TL TM TN TO TR TT TV TW TZ UA UG UM US UY UZ
			VA VC VE VG VI VN VU WF WS YE YT ZA ZM ZW 00
		}

		if {$code ni $supportedCountryCodes} {
			return 0
		}

		return 1
	}

	proc valid_gain {value} {
		return [expr {[string is double -strict $value] || $value eq "max"}]
	}

	proc valid_receiver_type {value} {
		set supportedReceiverTypes {rtlsdr sdr bladerf beast relay radarcape radarcape-local other none}

		if {$value ni $supportedReceiverTypes } {
			return 0
		}

		return 1
	}
	# check a value of the given type, return 1 if it looks OK
	proc validate_typed_value {type value} {
		switch $type {
			"string" {
				return 1
			}

			"boolean" {
				return [string is boolean -strict $value]
			}

			"integer" {
				return [string is integer -strict $value]
			}

			"double" {
				return [string is double -strict $value]
			}

			"mac" {
				return [valid_mac [string trim $value]]
			}

			"uuid" {
				return [valid_uuid [string trim $value]]
			}

			"country" {
				return [valid_country_code [string toupper [string trim $value]]]
			}

			"gain" {
				return [valid_gain [string tolower [string trim $value]]]
			}

			"receiver" {
				return [valid_receiver_type [string tolower [string trim $value]]]
			}

			default {
				error "unrecognized type: $type"
			}
		}
	}

	# given a user-provided value of a given type, return the normalized form
	proc normalize_typed_value {type value} {
		switch $type {
			"string" {
				return $value
			}

			"integer" - "double" {
				return [expr {$value}]
			}

			"boolean" {
				return [string is true -strict $value]
			}

			"mac" - "uuid" - "receiver" {
				return [string tolower [string trim $value]]
			}

			"country" {
				return [string toupper [string trim $value]]
			}

			"gain" {
				set t [string tolower [string trim $value]]
				if {$t eq "max" || $t == -10} {
					return "max"
				} else {
					return [expr {$value}]
				}
			}

			default {
				error "unrecognized type: $type"
			}
		}
	}

	# given a normalized value of the given type, return a formatted version suitable for writing to a config file
	proc format_typed_value {type value} {
		switch $type {
			"string" {
				return $value
			}

			"boolean" {
				if {![string is boolean -strict $value]} {
					error "bad boolean value: $value"
				}

				return [expr {$value ? "yes" : "no"}]
			}

			"integer" {
				if {![string is integer -strict $value]} {
					error "bad integer value: $value"
				}

				return $value
			}

			"double" {
				if {![string is double -strict $value]} {
					error "bad double value: $value"
				}

				return $value
			}

			"mac" {
				if {![valid_mac $value]} {
					error "bad MAC: $value"
				}
				return [string tolower [string trim $value]]
			}

			"uuid" {
				if {![valid_uuid $value]} {
					error "bad UUID: $value"
				}
				return [string tolower [string trim $value]]
			}

			"country" {
				if {![valid_country_code $value]} {
					error "bad Country code: $value"
				}
				return [string toupper [string trim $value]]
			}

			"gain" {
				if {![valid_gain $value]} {
					error "bad gain: $value"
				}
				return [string tolower $value]
			}

			"receiver" {
				if {![valid_receiver_type $value]} {
					error "bad receiver type: $value"
				}
				return [string tolower $value]
			}

			default {
				error "unrecognized type: $type"
			}
		}
	}

	# ConfigMetadata manages a set of descriptors that describe allowable
	# config settings, their types, and default values
	::itcl::class ConfigMetadata {
		private variable descriptors

		constructor {settingslist} {
			foreach setting $settingslist {
				add_setting {*}$setting
			}
		}

		# add_setting setting-key ?-default value? ?-type type? ?-protect 0|1?
		method add_setting {args} {
			set fileKey [lindex $args 0]

			set i 1
			set configKey [string tolower $fileKey]
			set typeName "string"
			set protect 0
			while {$i < [llength $args]} {
				switch [lindex $args $i] {
					"-default" {
						incr i
						set defaultValue [lindex $args $i]
						incr i
					}

					"-type" {
						incr i
						set typeName [lindex $args $i]
						incr i
					}

					"-protect" {
						incr i
						set protect [lindex $args $i]
						incr i
					}

					default {
						break
					}
				}
			}
			if {$i < [llength $args]} {
				error "wrong args: should be \"add_setting key ?-type type? ?-default value? ?-protect 0|1?\""
			}

			if {$typeName ni {boolean string integer double mac uuid country gain receiver}} {
				error "wrong args: -type understands \"boolean\", \"string\", \"double\", \"integer\", \"mac\", \"uuid\", \"country\", \"gain\", \"receiver\""
			}

			if {[info exists defaultValue]} {
				if {![::fa_piaware_config::validate_typed_value $typeName $defaultValue]} {
					error "wrong args: -default value is not parseable as $typeName"
				}

				set defaultValue [::fa_piaware_config::normalize_typed_value $typeName $defaultValue]
			} else {
				set defaultValue ""
			}

			set descriptors($configKey) [list $typeName $defaultValue $protect]
		}

		# return the keys of all known config settings
		method all_settings {} {
			return [array names descriptors]
		}

		# return the normalized (lowercase) key for a given input key
		# if require is 1 (the default), then raises an error if the key is unknown
		method key {configKey {require 1}} {
			set k [string tolower $configKey]
			if {$require && ![info exists descriptors($k)]} {
				error "Unknown configuration key: $configKey"
			}
			return $k
		}

		# return 1 if the given key is a valid config key
		method exists {configKey} {
			return [info exists descriptors([key $configKey 0])]
		}

		# return the type of the given config key
		method type {configKey} {
			return [lindex $descriptors([key $configKey]) 0]
		}

		# return the default value of the given config key, or "" if no default is present
		method default {configKey} {
			return [lindex $descriptors([key $configKey]) 1]
		}

		# return the protection setting of the given config key
		# (protected settings contain sensitive settings like passwords)
		method protect {configKey} {
			return [lindex $descriptors([key $configKey]) 2]
		}

		# test if the given value is valid for a given config key, return 1 if OK
		method validate {configKey value} {
			return [::fa_piaware_config::validate_typed_value [type $configKey] $value]
		}

		# normalize a config value for the given config key
		method normalize {configKey value} {
			return [::fa_piaware_config::normalize_typed_value [type $configKey] $value]
		}

		# format a normalized value for the given config key
		method format {configKey value} {
			return [::fa_piaware_config::format_typed_value [type $configKey] $value]
		}
	}

	# ConfigFile handles a single config file on disk.
	# This superclass handles the standard format; subclasses
	# implement other formats
	::itcl::class ConfigFile {
		private common reCommentLine {^\s*#.*}
		private common reOptionLine {^\s*([a-zA-Z0-9_-]+)\s+(.+)$}
		private common reEmptyOptionLine {^\s*([a-zA-Z0-9_-]+)\s*(?:#.*)?$}

		public variable filename
		public variable metadata
		public variable readonly 0
		public variable priority 0
		public variable writeHelper
		public variable eol "lf"

		private variable lines
		private variable values
		private variable valueSourceLine

		private variable mappings
		private variable revMappings

		# caller should supply at least -filename and -metadata, and optionally
		# -readonly / -priority
		constructor {args} {
			configure {*}$args
		}

		# add an alias to this file: settings with a key
		# of "from" in the file will be treated as if
		# they are "to" when reading the file, and
		# settings with a key of "to" will be written
		# to the file with a key of "from"
		method alias {from to} {
			set mappings($from) [string tolower $to]
			set revMappings($to) [string tolower $from]
		}

		# clear existing values and try to (re)read the config file.
		# returns a list of problems encountered, one problem per entry
		# if the file is missing, this is a no-op
		method read_config {} {
			set lines {}
			array unset values
			array unset valueSourceLine

			if {![file exists $filename]} {
				return {}
			}

			set problems {}
			if {[catch {
				set f [open $filename "r"]
				fconfigure $f -encoding ascii -translation auto
				while {[gets $f line] >= 0} {
					lassign [parse_line $line] fileKey value
					lappend lines $line

					if {$fileKey ne ""} {
						if {[info exists mappings($fileKey)]} {
							set configKey [$metadata key $mappings($fileKey)]
						} else {
							set configKey [$metadata key $fileKey 0]
							if {![$metadata exists $configKey]} {
								lappend problems "$filename:[llength $lines]: unrecognized option $fileKey"
								continue
							}
						}

						# Empty values have a special meaning: they are a whiteout marker
						# Don't process them further.
						if {$value ne ""} {
							if {![$metadata validate $configKey $value]} {
								lappend problems "$filename:[llength $lines]: invalid value for option $fileKey: $value"
								continue
							}

							set value [$metadata normalize $configKey $value]
						}

						if {[info exists values($configKey)]} {
							lappend problems "$filename:[llength $lines]: $fileKey overrides a value previously set on line $valueSourceLine($configKey)"
							# but accept it anyway
						}

						set values($configKey) $value
						set valueSourceLine($configKey) [llength $lines]
					}
				}
			} result] == 1} {
				lappend problems "$filename: failed to read config file: $result"
			}

			if {[info exists f]} {
				catch {close $f}
			}

			return $problems
		}

		# return 1 if this config file is readonly
		# (either configured as readonly, or target file is not writable)
		method readonly {} {
			if {$readonly} {
				return 1
			}

			if {![file exists $filename]} {
				return 1
			}

			if {[id userid] != 0 && [info exists writeHelper] && [::fa_sudo::can_sudo root $writeHelper $filename]} {
				return 0
			}

			if {![file writable $filename] || ![file writable [file dirname $filename]]} {
				return 1
			}

			return 0
		}

		# returns the priority of this file, either that explicitly set
		# by a "priority" entry, or whatever was set in the ctor.
		method priority {} {
			if {[$metadata exists priority] && [get priority] ne ""} {
				return [get priority]
			} else {
				return $priority
			}
		}

		# try to write the config file out, raise an error if something
		# goes wrong.
		# writing an empty config file is a no-op
		method write_config {} {
			if {[llength $lines] == 0} {
				return
			}

			if {[readonly]} {
				error "config file $filename is readonly"
			}

			if {![file exists $filename]} {
				error "config file $filename does not exist, cannot update it"
			}


			# get current ownership/permissions
			set fp [open $filename "r"]
			fstat $fp stat fpstat
			close $fp

			if {[id userid] == 0} {
				# we are root, just check for readonly dir
				if {![file writable [file dirname $filename]]} {
					error "can't write config file $filename, containing directory is readonly"
				}
				set useHelper 0
			} else {
				# check that we can set the same ownership
				if {![file writable [file dirname $filename]] ||
					$fpstat(uid) != [id userid] ||
					($fpstat(gid) != [id groupid] && $fpstat(gid) ni [id groupids])} {
					# we cannot write the file directly
					if {[info exists writeHelper] && [::fa_sudo::can_sudo root $writeHelper $filename]} {
						set useHelper 1
					} else {
						error "can't directly write config file $filename, and no helper is available"
					}
				} else {
					set useHelper 0
				}
			}

			if {$useHelper} {
				# send the new file via a pipe to the helper
				# which will do the actual work
				set f [::fa_sudo::open_as -root "|$writeHelper $filename" "w"]
			} else {
				# write the file directly ourselves
				set temppath "${filename}.new"
				set f [open $temppath "w" [expr {$fpstat(mode) & 0777}]]

				# fix the ownership to match the old file
				chown -fileid [list $fpstat(uid) $fpstat(gid)] $f
			}

			# write the new data
			try {
				fconfigure $f -encoding ascii -translation $eol
				foreach line $lines {
					puts $f $line
				}

				if {!$useHelper} {
					flush $f
					sync $f
				}

				close $f
				unset f

				if {!$useHelper} {
					catch {exec sync}
					file rename -force -- $temppath $filename
					unset temppath
					catch {exec sync}
				}
			} finally {
				if {[info exists f]} {
					catch {close $f}
				}

				if {[info exists temppath]} {
					catch {file delete -- $temppath}
				}
			}

		}

		proc unquote_value {text} {
			set text [string trimleft $text]
			if {[string length $text] == 0} {
				# empty string
				return ""
			}

			set quote [string index $text 0]
			if {$quote ne "\"" && $quote ne "'"} {
				# simple case, unquoted value
				# take everything up to an (optional) comment char
				# trim whitespace
				set commentChar [string first "#" $text]
				if {$commentChar >= 0} {
					set text [string range $text 0 $commentChar-1]
				}

				return [string trimright $text]
			}

			# complex case, quoted value with backslash-escapes
			# this is very relaxed: we just entirely ignore everything (comments etc) after the close-quote
			# and we also don't care if the value doesn't have a close-quote

			set out ""
			set escape 0
			for {set i 1} {$i < [string length $text]} {incr i} {
				set ch [string index $text $i]
				if {$escape} {
					append out $ch
					set escape 0
					continue
				}

				if {$ch eq $quote} {
					break
				}

				if {$ch eq "\\"} {
					set escape 1
					continue
				}

				append out $ch
			}

			return $out
		}

		protected method parse_line {line} {
			if {[regexp $reCommentLine $line]} {
				return {}
			}

			if {[regexp $reEmptyOptionLine $line -> key]} {
				return [list $key ""]
			}

			if {[regexp $reOptionLine $line -> key value]} {
				return [list $key [unquote_value $value]]
			}

			return {}
		}

		proc quote_value {text} {
			if {[string trim $text] eq $text && [string index $text 0] ne "\"" && [string index $text 0] ne "'" && [string first "#" $text] < 0 && [string first " " $text] < 0} {
				# safe to just dump it in directly:
				# no leading/trailing whitespace, doesn't start with a quote, doesn't contain a comment character
				# we also quote values with embedded whitespace for clarity, though it's not necessary when parsing
				return $text
			}

			# needs quoting.
			return "\"[string map [list "\"" "\\\"" "\\" "\\\\"] $text]\""
		}

		protected method generate_line {key value} {
			if {$value eq ""} {
				return "$key  # whiteout entry, updated by fa_piaware_config"
			} else {
				return "$key [quote_value $value]   # updated by fa_piaware_config"
			}
		}

		# get the value for a given config key
		#
		# raises an error if the key is unknown
		# otherwise, returns the key value ("" for a whiteout or missing value)
		# defaults are _not_ applied
		method get {configKey} {
			set configKey [string tolower $configKey]

			if {![$metadata exists $configKey]} {
				error "unknown config key: $configKey"
			}

			if {[info exists values($configKey)]} {
				return $values($configKey)
			} else {
				return ""
			}
		}

		# set the value for a config key
		#
		# this is not named the more obvious "set" because that way
		# lies a twisty little maze of ::set commands
		#
		# returns 1 if the value actually changed
		method set_option {configKey value} {
			set configKey [string tolower $configKey]

			if {![$metadata exists $configKey]} {
				error "unknown config key: $configKey"
			}

			if {[info exists revMappings($configKey)]} {
				set fileKey $revMappings($configKey)
			} else {
				set fileKey $configKey
			}

			if {$value ne ""} {
				if {![$metadata validate $configKey $value]} {
					error "not a valid value for this key"
				}

				set value [$metadata normalize $configKey $value]
				set formatted [$metadata format $configKey $value]
			} else {
				# whiteout
				set formatted ""
			}

			if {[info exists values($configKey)] && $values($configKey) eq $value} {
				# unchanged
				return 0
			}

			set newLine [generate_line $fileKey $formatted]

			if {[info exists valueSourceLine($configKey)]} {
				lset lines [expr {$valueSourceLine($configKey)-1}] $newLine
			} else {
				lappend lines $newLine
				set valueSourceLine($configKey) [llength $lines]
			}

			set values($configKey) $value
			return 1
		}

		# return 1 if the given key has a value set in this file;
		# ignores any defaults; returns 1 for whiteouts, too.
		method exists {configKey} {
			set configKey [string tolower $configKey]
			if {![$metadata exists $configKey]} {
				error "unknown config key: $configKey"
			}

			return [info exists values($configKey)]
		}

		# return the origin of a given key: either
		#   filename:line if the key is present in this file, or
		#   "" if the key is not present
		method origin {configKey} {
			set configKey [string tolower $configKey]
			if {[info exists valueSourceLine($configKey)]} {
				return "$filename:$valueSourceLine($configKey)"
			} else {
				return ""
			}
		}

		# return the filename for this config file
		method filename {} {
			return $filename
		}
	}

	# a subclass of ConfigFile that understands the tcl-list-format
	# files used for /root/.piaware in the past
	::itcl::class LegacyListConfigFile {
		inherit ConfigFile

		constructor {args} {
			ConfigFile::constructor {*}$args
		}

		protected method parse_line {line} {
			if {![string is list -strict $line]} {
				return {}
			}

			if {[llength $line] != 2} {
				return {}
			}

			return $line
		}

		protected method generate_line {key value} {
			return [list $key $value]
		}
	}

	# a subclass of ConfigFile that understands the list-of-tcl-sets
	# format used for /etc/piaware in the past
	::itcl::class LegacySetConfigFile {
		inherit ConfigFile

		constructor {args} {
			ConfigFile::constructor {*}$args
		}

		protected method parse_line {line} {
			lassign $line setword varname value
			if {$setword ne "set"} {
				return {}
			}

			return [list $varname $value]
		}

		protected method generate_line {key value} {
			return [list "set" $key $value]
		}
	}

	# ConfigGroup handles reading and writing a group of ConfigFile
	# instances that can have different priorities and formats.
	# They should, however, have the same metadata.
	::itcl::class ConfigGroup {
		public variable configFiles {}
		public variable metadata

		private variable orderedFiles {}
		private variable dirty

		# caller should provide at least metadata
		# and can provide an initial list of configFiles
		# nb: the files are not read until read_config is called
		constructor {args} {
			configure {*}$args
			sort_config_files
		}

		# add a new ConfigFile instance to this group
		method add {cf} {
			lappend configFiles $cf
			sort_config_files
		}

		# sort known files by priority
		private method sort_config_files {} {
			set prios {}
			foreach f $configFiles {
				lappend prios [list [$f priority] $f]
			}

			set orderedFiles {}
			foreach pair [lsort -integer -decreasing -index 0 $prios] {
				lappend orderedFiles [lindex $pair 1]
			}
		}

		# read all config files. Returns a list of problems.
		# Missing files are not considered a problem.
		method read_config {} {
			set warnings {}
			set prios {}
			array unset dirty
			foreach f $configFiles {
				lappend warnings {*}[$f read_config]
				unset -nocomplain dirty($f)
			}

			# might have read some priority settings, resort
			sort_config_files
			return $warnings
		}

		# delegate to the metadata associated with this group:
		#   $group metadata exists foo-key
		#   $group metadata type foo-key
		# etc
		method metadata {args} {
			return [$metadata {*}$args]
		}

		# return the file for this key
		# return "" if no file has it
		method file_for_key {configKey} {
			foreach f $orderedFiles {
				if {[$f exists $configKey]} {
					return $f
				}
			}
		}

		# get a given config key from the highest priority
		# file in this group. If no file has this key set,
		# returns the default value if there is one, otherwise
		# returns an empty string.
		method get {configKey} {
			if {![$metadata exists $configKey]} {
				error "unknown config key: $configKey"
			}

			set f [file_for_key $configKey]
			if {$f ne ""} {
				# it's set somewhere (possibly a whiteout)
				set value [$f get $configKey]
			} else {
				set value ""
			}

			if {$value eq ""} {
				# not set, use default
				set value [$metadata default $configKey]
			}

			return $value
		}

		# return 1 if the given key is set in one of the config files
		# or has a default value
		method exists {configKey} {
			return [expr {[get $configKey] ne ""}]
		}

		# try to set an option, return the file we set it in
		# (file will not have been updated on disk, call write_config to write it out)
		method set_option {configKey value} {
			if {$configKey eq "priority"} {
				error "can't set priority of a group; set it on the particular file directly"
			}

			# find the config file we want to change, see if it would work
			# generally we want to update the config file with the lowest
			# priority that we can.

			set target ""
			foreach f $orderedFiles {
				if {$target eq "" && ![$f readonly]} {
					# this is the highest priority writable config file
					# we could put a new value in; remember it but keep
					# looking for an existing lower-priority value we
					# could amend in place.
					set target $f
				}

				if {[$f exists $configKey]} {
					# we must change the setting in this file;
					# setting it anywhere later would just get overridden
					# by the existing setting in this file.

					if {![$f readonly]} {
						# prefer to update an existing setting rather than
						# creating an override in a higher-priority file
						set target $f
						break
					}

					if {$target ne ""} {
						# change it in whatever higher-priority writable file we found
						break
					}

					# this setting would override whatever we do on lower
					# priority files, and we can't change it, give up
					error "cannot update option $configKey in readonly file [$f filename]"
				}
			}

			if {$target eq ""} {
				error "cannot update option $configKey as all config files are read-only"
			}

			if {[$target set_option $configKey $value]} {
				set dirty($target) 1
				return $target
			} else {
				return ""
			}
		}

		# return the origin of a config key (where it was set from)
		# this will return one of:
		#   filename:linenumber if it was explicitly set somewhere
		#   "defaults" if it was not explictly set and has a default value
		#   "" if it was not explictly set and has no default value
		method origin {configKey} {
			set f [file_for_key $configKey]
			if {$f ne ""} {
				return [$f origin $configKey]
			}

			if {[$metadata default $configKey] ne ""} {
				return "defaults"
			}

			return ""
		}

		# write out any changed config files;
		# raises an error if something goes wrong
		method write_config {} {
			foreach f $configFiles {
				if {[info exists dirty($f)]} {
					$f write_config
					unset dirty($f)
				}
			}
		}
	}

	# Build a metadata instance for the standard Piaware config settings
	proc piaware_standard_settings {name} {
		set settings {
			{"priority"              -type integer}
			{"image-type"            -type string}
			{"manage-config"         -type boolean -default no}
			{"feeder-id"             -type uuid}
			{"flightaware-user"      -protect 1}
			{"flightaware-password"  -protect 1}
			{"force-macaddress"      -type mac}
			{"allow-auto-updates"    -type boolean -default no}
			{"allow-manual-updates"  -type boolean -default no}

			{"wired-network"         -type boolean -default yes}
			{"wired-type"            -default "dhcp"}
			"wired-address"
			"wired-netmask"
			"wired-broadcast"
			"wired-gateway"
			{"wired-nameservers"     -default {8.8.8.8 8.8.4.4}}

			{"wireless-network"      -type boolean -default no}
			"wireless-ssid"
			{"wireless-password"     -protect 1}
			{"wireless-type"         -default "dhcp"}
			"wireless-address"
			"wireless-netmask"
			"wireless-broadcast"
			"wireless-gateway"
			{"wireless-nameservers"  -default {8.8.8.8 8.8.4.4}}
			{"wireless-country"      -type country -default "00"}

			{"allow-dhcp-duid"       -type boolean -default yes}

			"http-proxy-host"
			"http-proxy-port"
			"http-proxy-user"
			{"http-proxy-password"   -protect 1}

			{"adept-serverhosts"     -default {piaware.flightaware.com piaware.flightaware.com {70.42.6.197 70.42.6.198 70.42.6.191 70.42.6.225 70.42.6.224 70.42.6.156}}}
			{"adept-serverport"      -type integer -default 1200}

			{"rfkill"                -type boolean -default no}
			{"receiver-type"         -type receiver -default rtlsdr}
			{"rtlsdr-device-index"   -default 0}
			{"rtlsdr-ppm"            -type integer -default 0}
			{"rtlsdr-gain"           -type gain -default max}
			{"beast-baudrate"        -type integer}
			"radarcape-host"
			"receiver-host"
			{"receiver-port"         -type integer -default 30005}
			{"allow-modeac"          -type boolean -default yes}
			{"allow-mlat"            -type boolean -default yes}
			{"mlat-results"          -type boolean -default yes}
			{"mlat-results-anon"     -type boolean -default yes}
			{"mlat-results-format"   -default "beast,connect,localhost:30104 beast,listen,30105 ext_basestation,listen,30106"}

			{"enable-firehose"       -type boolean -default no}

			{"uat-receiver-type"	 -type receiver -default none}
			{"uat-receiver-host"}
			{"uat-receiver-port"	 -type integer -default 30978}
			{"uat-sdr-gain"	         -type gain -default max}
			{"uat-sdr-ppm"	         -type double -default 0}
			{"uat-sdr-device"        -default "driver=rtlsdr"}

			{"use-gpsd"              -type boolean -default yes}
		}

		return [uplevel 1 ::fa_piaware_config::new ::fa_piaware_config::ConfigMetadata [list $name] [list $settings]]
	}

	# Return a new ConfigGroup that handles the standard piaware config location, which are
	# (starting from the highest priority):
	#
	#  priority 100+:     any extra config file given as an argument (readonly)
	#  priority 100+:     any config files found in /media/usb/*/piaware-config.txt, ordered arbitrarily (readonly)
	#  priority 50:       /boot/piaware-config.txt (readwrite)
	#  priority 40:       /etc/piaware.conf (readwrite)
	#  priority 30:       /usr/share/piaware-support/piaware-image-config.txt (readonly) (provides additional defaults on PiAware sdcard images)
	#
	# which means that in general changes will be written to /etc/piaware.conf where possible, or
	# /boot/piaware-config.txt if the setting was set there.
	#
	# Provide a itcl name pattern (e.g. #auto) as "name"
	proc piaware_combined_config {name {extraConfigFile ""}} {
		set metadata [piaware_standard_settings #auto]
		set combined [uplevel 1 ::fa_piaware_config::new ::fa_piaware_config::ConfigGroup $name -metadata $metadata]

		$combined add [new ConfigFile #auto -filename "/usr/share/piaware-support/piaware-image-config.txt" -metadata $metadata -priority 30 -readonly 1]
		$combined add [new ConfigFile #auto -filename "/etc/piaware.conf" -metadata $metadata -priority 40 -writeHelper $::fa_piaware_config::helperPath]

		$combined add [new ConfigFile #auto -filename "/boot/piaware-config.txt" -metadata $metadata -priority 50 -writeHelper $::fa_piaware_config::helperPath -eol crlf]

		set prio 100
		foreach f [lsort [glob -nocomplain -types f "/media/usb/*/piaware-config.txt"]] {
			$combined add [new ConfigFile #auto -filename $f -metadata $metadata -priority $prio -readonly 1]
			incr prio
		}

		if {$extraConfigFile ne ""} {
			$combined add [new ConfigFile #auto -filename $extraConfigFile -metadata $metadata -priority $prio -readonly 1]
		}

		return $combined
	}

	# point standard config at piaware
	interp alias {} ::fa_piaware_config::new_combined_config {} ::fa_piaware_config::piaware_combined_config

	# Return a new ConfigGroup that gives readonly access to the legacy config files
	# in /root/.piaware and /etc/piaware
	proc new_legacy_config {name} {
		set metadata [piaware_standard_settings #auto]
		set combined [uplevel 1 ::fa_piaware_config::new ::fa_piaware_config::ConfigGroup $name -metadata $metadata]

		set c [new LegacySetConfigFile #auto -filename "/etc/piaware" -metadata $metadata -priority -100 -readonly 1]
		$c alias "imageType" "image-type"
		$c alias "autoUpdate" "allow-auto-updates"
		$c alias "manualUpdate" "allow-manual-updates"
		$combined add $c

		set c [new LegacyListConfigFile #auto -filename "/root/.piaware" -metadata $metadata -priority -50 -readonly 1]
		$c alias "autoUpdate" "allow-auto-updates"
		$c alias "manualUpdate" "allow-manual-updates"
		$c alias "mlat" "allow-mlat"
		$c alias "mlatResults" "mlat-results"
		$c alias "mlatResultsFormat" "mlat-results-format"
		$c alias "user" "flightaware-user"
		$c alias "password" "flightaware-password"
		$combined add $c

		return $combined
	}
}

package provide fa_piaware_config 0.1
