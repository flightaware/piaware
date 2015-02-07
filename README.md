PiAware
===

The basic aim of the piaware package is to forward data read from an ADS-B receiver to FlightAware.

It does this using a program, piaware, aided by some support programs.

* piaware - establishes an encrypted session to FlightAware and forwards data
* faup1090 - run by piaware to connect to dump1090 or some other program producing beast-style ADS-B data and translate between its format and FlightAware's
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

Piaware uses several techniques to keep the connection established and disconnect and reconnect if something goes wrong.

piaware-config program
---

piaware-config provides a way for you to set the FlightAware username and password that piaware will use to log into FlightAware and do some other stuff.  (One account can be used for many piaware ADS-B receiver sites.)

The main use will be

    piaware-config -user username -password

This will set the user to "username" and prompt for the password.  These are then saved in a config file that piaware finds when it starts.

Note that as of PiAware 1.13 it is no longer necessary to set a username and password, although if you do it will still work.  If PiAware is not pre-configured then the server will generally be able to associate the PiAware host with your FlightAware account automatically by looking at your FlightAware web session and the IP address your pi is coming from.  If it can't then there's a process for claiming a PiAware receiver as belonging to you.  For more information please check out [PiAware build instructions](https://flightaware.com/adsb/piaware/build) at FlightAware.

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

Building and installing Piaware from source
---

Before installing piaware you need to install the RTL-SDR libraries and dump1090and stuff.  We've created some [instructions](https://github.com/flightaware/piaware/wiki/Building-and-installing-PiAware-from-source) for that in the piaware wiki at github.

Notes from a recent install on Debian
* install Debian without desktop or whatever, pretty much everything else
* use ISO image if from Parallels
* in Parallels I let it take all of the disk

At first sudo isn't even there, so I did a su to become superuser (could have logged in as root instead) and did

```
apt-get update
apt-get install sudo
```

While su'ed add myself to group sudo in /etc/group and edited the line in /etc/sudoers for group sudo to be

```
%sudo	ALL=(ALL) NOPASSWD: ALL
```

...which allowed me to run sudo without entering my password.

This seems to be the default configuration on Raspbian.

Next install various packages.  If they are already installed, as on Raspbian
many are, that's fine.

```
sudo apt-get install tcl8.5-dev tclx8.4-dev itcl3-dev tcl-tls tcllib automake cmake tcl-tclreadline telnet git gcc make
```

If you want to develop, you might want to add some manual pages and whatnot...

```
sudo apt-get install tcl8.5-doc tclx8.4-doc itcl3-doc
```

Clone the tcllauncher git repo from the [tcllauncher git repo](https://github.com/flightaware/tcllauncher) and build...

```
git clone https://github.com/flightaware/tcllauncher.git
cd tcllauncher
autoconf
./configure --with-tcl=/usr/lib/tcl8.5
make
sudo make install
```

### Build and install dump1090

Build the RTL-SDR support libraries and build and install dump1090.

If you want to build the FlightAware variant, please follow our build
instructions in the [dump1090_mr repository](https://github.com/flightaware/dump1090_mr#building) at github.

### Build PiAware

Clone and install the piaware git repo from [FlightAware's piaware repository](https://github.com/flightaware/piaware):

```
git clone https://github.com/flightaware/piaware.git
cd piaware
sudo make install
```

Make piaware start and stop when the system boots and shuts down:

```
sudo update-rc.d piaware defaults
```

Stop piaware from stopping and starting when the system boots and shuts down:

```
  sudo update-rc.d piaware remove
```

Start piaware manually

```
/etc/init.d/piaware start
```

Please see the section on [/etc/init.d/piaware](https://github.com/flightaware/piaware#etcinitdpiaware) earlier in this document for details.

Overview of PiAware pieces
---
FlightAware's dump1090 is exactly the same as Malcolm Robb’s except for the code added to provide messages as filtered key-value pairs on port 10001.  All the command-line switches and capabilities should be there with only the addition of the —net-fatsv-port and the —no-rtlsdr-ok switches we created. 

faup1090 is a version of dump1090 that only has the ability to connect to the binary beast output port of dump1090 or another program capable of putting out that format such as modesmixer, and provides the filtered key-value pairs on port 10001.

In summary, FlightAware's dump1090 is standard dump1090 with the added port 10001 stuff and running FlightAware's dump1090 is slightly more efficient than running standard dump1090 and piaware running faup1090 to translate.
