Piaware
===

The basic aim of the piaware package is to forward data read from an ADS-B receiver to FlightAware.

It does this using a program, piaware, aided by some support programs.

* piaware - establishes an encrypted session to FlightAware and forwards data
* faup1090 - run by piaware to connect to dump1090 and translate between its formats and FlightAware's
* piaware-config - used to configure piaware like with a FlightAware username and password
* piaware-status - used to check the status of piaware

This repo is the basis of the piaware Debian install package available
from https://flightaware.com/adsb/piaware/

piaware program
---

The piaware program establishes a compressed, encrypted TLS connection to FlightAware and logs in with a registered FlightAware username (or email address) and password.

It then looks to see if your system is running the FlightAware version of dump1090 (available from https://github.com/flightaware/dump1090_mr) and if not, it starts the translation program faup1090 (available from the same source).

After a successful login, piaware should forward filtered ADS-B traffic to FlightAware.  (The filtering is to reduce the amount of traffic.  We do a lot of stuff to minimize upstream bandwidth.)

Every five minutes piaware also sends a message containing basic health information about the local machine such as system clock, CPU temperature, basic filesystem capacity and system uptime.

Piaware uses several techniques are used to keep the connection established and disconnect and reconnect if something goes wrong.

piaware-config program
---

piaware-config provides a way for you to set the FlightAware username and password that piaware will use to log into FlightAware and do some other stuff.  (One account can be used for many piaware ADS-B receiver sites.)

The main use will be

    piaware-config -user username -password

This will set the user to "username" and prompt for the password.  These are then saved in a config file that piaware finds when it starts.

piaware-status program
---

piaware-status will examine your system and try to figure out what's going on.  It will report on whether dump1090, faup1090 and piaware are running or not and it will see if dump1090 is producing data and whether or not piaware is connected to FlightAware.

log file
---

piaware logs to the file /tmp/piaware.out

fa_adept_client package
---

The fa_adept_client package provieds a class library for being an aviation
data exchange protocol (ADEPT) client.

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


