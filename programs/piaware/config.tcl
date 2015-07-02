#
# config for piaware
#
# Copyright (C) 2014 FlightAware LLC, All Rights Reserved
#

# server name is defined and can be overridden in the Itcl class library
# that handles connections

set serverRetryIntervalSeconds 60

set piawareVersion 2.1
set piawareVersionFull 2.1-1

# how many seconds with no messages received from the ADS-B receiver before
# we will attempt to restart dump1090
set noMessageActionIntervalSeconds 3600

# perform ADS-B traffic check and report every this-many-seconds
set adsbTrafficCheckIntervalSeconds 300

# send health information every this many seconds
set sendHealthInformationIntervalSeconds 300

# number of seconds that no ADS-B producer program (usually) is found running
# for before we will attempt to start it
set adsbNoProducerStartDelaySeconds 360

# where we store our location info
set locationFile "/var/lib/dump1090/latlon"

# vim: set ts=4 sw=4 sts=4 noet :
