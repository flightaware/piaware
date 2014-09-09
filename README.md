Piaware
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

Piaware uses several techniques are used to keep the connection established and disconnect and reconnect if something goes wrong.

piaware-config program
---

piaware-config provides a way for you to set the FlightAware username and password that piaware will use to log into FlightAware and do some other stuff.  (One account can be used for many piaware ADS-B receiver sites.)

The main use will be

    piaware-config -user username -password

This will set the user to "username" and prompt for the password.  These are then saved in a config file that piaware finds when it starts.

piaware-status program
---

piaware-status will examine your system and try to figure out what's going on.  It will report on whether dump1090, faup1090 and piaware are running or not and it will identify what program, if any, is producing data on port 30005 and whether or not piaware is connected to FlightAware.

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

Building and installing Piaware from source
---
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

Clone the tcllauncher git repo from https://github.com/flightaware/tcllauncher
and build...

```
git clone https://github.com/flightaware/tcllauncher.git
cd tcllauncher
autoconf
./configure --with-tcl=/usr/lib/tcl8.5
make
sudo make install
```

http://sourceforge.net/projects/libusb/
./configure --prefix=/usr
make
sudo make install

sudo apt-get install pkg-config

git clone git://git.osmocom.org/rtl-sdr.git
cd rtl-sdr
mkdir build
cd build
cmake -DCMAKE_INSTALL_PREFIX:PATH=/usr .
make
sudo make install

clone dump1090_mr from github
git clone git@github.com:flightaware/dump1090_mr.git
cd dump1090_mr
make
sudo make install


Clone and install the piaware git repo from
https://github.com/flightaware/piaware

```
git clone https://github.com/flightaware/piaware.git
cd piaware
sudo make install
```

Make piaware start and stop when the system boots and shuts down

```
sudo update-rc.d piaware defaults
```

Stop piaware from stopping and starting when the system boots and shuts down

```
  sudo update-rc.d piaware remove
```

