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

piaware-config provides a way for you to configure piaware's settings to control authentication, updates, and
multilateration.

The configuration is read once when piaware starts. If you change piaware's configuration, you should then restart
piaware by:

```
$ sudo service piaware restart
```

Displaying the current configuration
---

Running piaware-config with no arguments will show the current configuration:

```
$ piaware-config
```

The "-showall" argument will show all settings, including those that are using the default values:

```
$ piaware-config -showall
```

Configuring updates
---

To configure whether piaware will accept requests for automatic (requested by FlightAware) or manual (requested
by you via the FlightAware website control panel) updates and restarts:

```
# disable auto updates:
$ sudo piaware-config allow-auto-updates no
# disable manual updates:
$ sudo piaware-config allow-manual-updates no
```

Updates default to enabled for Piaware sdcard images, and disabled for package installs.

Configuring multilateration support
---

Multilateration data is sent to FlightAware by default. To disable it:

```
# disable multilateration:
$ sudo piaware-config allow-mlat no
```

Configuring multilateration results
---

By default, multilateration positions resulting from the data that you feed to FlightAware
are returned to you by sending them to the local dump1090 process on port 30104; dump1090
will then include them on the web map it generates.

There are two controls for this. There is an overall enable/disable
control that can be used to entirely disable returning results if they are not needed:

```
$ sudo piaware-config mlat-results no
```

If you want to send the results elsewhere, you can modify where they are sent and the format used:

```
  # Connect to localhost:30104 and send multilateration results in Beast format.
  # Listen on port 310003 and provide multilateration results in Basestation format to anyone who connects

$ sudo piaware-config mlat-results-format "beast,connect,localhost:30104 basestation,listen,31003"
```

The default configuration now connects to port 30104, not 30004. The default FlightAware dump1090 configuration has
been updated to match this. This change is to avoid accidentally feeding mlat results to an older dump1090
that is not mlat-aware and might end up feeding the results to places you don't want to feed them to. If you really
do want to feed to port 30004, and you know that's not going to cause problems with mlat results going where they
shouldn't, you can return to the older behaviour by:

```
$ sudo piaware-config mlat-results-format "beast,connect,localhost:30004"
```

piaware-status program
---

piaware-status will examine your system and try to figure out what's going on.  It will report on whether dump1090, faup1090 and piaware are running or not and it will identify what program, if any, is producing data on port 30005 and whether or not piaware is connected to FlightAware.

log file
---

piaware logs to the file **/var/log/piaware.log**.  This is rotated weekly; older logs are at **/var/log/piaware.log.0**, **/var/log/piaware.log.1**, etc.

fa_adept_client package
---

The fa_adept_client package provides a class library for being a FlightAware aviation data exchange protocol (ADEPT) client.

fa_adept_config package
---

The fa_adept_config package provides functions for reading and writing the piaware config file.

piaware package
---

The piaware package provides functions used by various of the piaware programs.

systemd service file
---

piaware is started as a systemd service ("piaware.service"). It can be started and stopped with:

    sudo systemctl start piaware
    sudo systemctl stop piaware
    sudo systemctl restart piaware

The current state can be checked with:

    systemctl status piaware


FlightAware
---
FlightAware has released over a dozen applications  (under the free and liberal BSD license) into the open source community. FlightAware's repositories are available on GitHub for public use, discussion, bug reports, and contribution. Read more at https://flightaware.com/about/code/

