#
# config for piaware
#
# Copyright (C) 2014 FlightAware LLC, All Rights Reserved
#

# server name is defined and can be overridden in the Itcl class library
# that handles connections

set serverRetryIntervalSeconds 60

set piawareVersion 1.15

set noMessageActionIntervalSeconds 3600

# perform ADS-B traffic check and report every this-many-seconds
set adsbTrafficCheckIntervalSeconds 300

# send health information every this many seconds
set sendHealthInformationIntervalSeconds 300

set faup1090Port 10001

# vim: set ts=4 sw=4 sts=4 noet :
