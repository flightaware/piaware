PiAware
===

The basic aim of the piaware package is to forward data read from an ADS-B receiver to FlightAware.

It does this using a program, piaware, aided by some support programs.

* piaware - establishes an encrypted session to FlightAware and forwards data
* piaware-config - used to configure piaware like with a FlightAware username and password
* piaware-status - used to check the status of piaware
* faup1090 - run by piaware to connect to dump1090 or some other program producing beast-style ADS-B data and translate between its format and FlightAware's
* fa-mlat-client - run by piaware to gather data for multilateration

This repo is the basis of the piaware Debian install package available
from https://flightaware.com/adsb/piaware/

Building from source
---

This repository provides only part of the overall piaware package.
You must also build fa-mlat-client and faup1090 and put them in the right places.

Please use [piaware_builder](https://github.com/flightaware/piaware_builder) to build the
piaware package; this is a mostly automated build that knows how to assemble and build
the different parts of the piaware pacakge. It is used to build the Raspbian piaware
release packages that FlightAware provides. It should also work on other Debian-based systems.

piaware program
---

The piaware program establishes a compressed, encrypted TLS connection to FlightAware and authenticates
either by MAC address, or by a registered FlightAware username (or email address) and password.

It then starts faup1090 to translate ADS-B data from a raw Beast-format feed on port 30005 to a filtered
ADS-B format. The filtered data is uploaded to FlightAware over the previously established TLS
connection.

Every five minutes piaware also sends a message containing basic health information about the local machine
such as system clock, CPU temperature, CPU load, basic filesystem capacity and system uptime.

Piaware will start the multilateration client fa-mlat-adept on request. fa-mlat-client extracts raw messages
from port 30005 and selectively forwards them by UDP to the FlightAware servers. UDP is used as this
message forwarding is time-sensitive, but it's not too important if some messages get dropped. Multilateration
control messages are sent over the main piaware TCP connection.

Piaware uses several techniques to keep the connection established and disconnect and reconnect if something goes wrong.


piaware-config program
---

piaware-config provides a way for you to set the FlightAware username and password that piaware will use to log
into FlightAware and do some other stuff.  (One account can be used for many piaware ADS-B receiver sites.)

The main use will be

```
$ sudo piaware-config -user username -password
```

This will set the user to "username" and prompt for the password.  These are then saved in a config file that piaware finds when it starts.

Note that as of PiAware 1.13 it is no longer necessary to set a username and password, although if you do it will still work.
If PiAware is not pre-configured then the server will generally be able to associate the PiAware host with your FlightAware
account automatically by looking at your FlightAware web session and the IP address your pi is coming from.  If it can't then
there's a process for claiming a PiAware receiver as belonging to you.  For more information please check out
[PiAware build instructions](https://flightaware.com/adsb/piaware/build) at FlightAware.

piaware-config may also be used to configure where multilateration results are forwarded. By default, results will be
made available on port 31003 in Basestation format.  This is different to the previous default of automatically looping back to the local dump1090 process on port 30004.  This is to avoid causing issues for clients feeding other sites and clients which do not expect or are unable to distinguish non-aircraft derived messages and interpret FlightAware MLAT calulated positions as true ADS-B data.

If the previous behaviour is required, it must be explicitly enabled.  However, before doing so, you must ensure that any other clients using the local dump1090 can handle and are happy to accept MLAT data:

```
  # Connect to localhost:30004 and send multilateration results in Beast format.
  # Listen on port 310003 and provide multilateration results in Basestation format to anyone who connects

$ sudo piaware-config -mlatResultsFormat "beast,connect,localhost:30004 basestation,listen,31003"
```

Feedback of MLAT results can be disabled entirely if needed:

```
$ sudo piaware-config -mlatResults 0
```

piaware-status program
---

piaware-status will examine your system and try to figure out what's going on.  It will report on whether dump1090, faup1090 and piaware are running or not and it will identify what program, if any, is producing data on port 30005 and whether or not piaware is connected to FlightAware.

log file
---

piaware logs to the file **/tmp/piaware.out**.  At the end of each GMT day that file is renamed to **/tmp/piaware.out.yesterday** and a new piaware.out is started.

fa_adept_client package
---

The fa_adept_client package provides a class library for being a FlightAware aviation data exchange protocol (ADEPT) client.

fa_adept_config package
---

The fa_adept_config package provides functions for reading and writing the piaware config file.

piaware package
---

The piaware package provides functions used by various of the piaware programs.

/etc/init.d/piaware
---

The piaware control script gets installed into /etc/init.d and piaware
can be started and stopped with

    /etc/init.d/piaware start

    /etc/init.d/piaware stop

    /etc/init.d/piaware restart


The piaware install package does the needful to make piaware stop and start automatically as Linux goes to and from multiuser operation.

This can probably be done for people installing piaware from this repo by doing a

    update-rc.d piaware defaults

and removed by doing a

    update-rc.d piaware remove
