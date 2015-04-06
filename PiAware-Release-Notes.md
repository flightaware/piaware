piaware 1.20-1
--
* Greatly improved range and message rate by configuring dump1090 to use auto-gain rather than max gain (--gain -10 added to dump1090 arguments). Sites allowing remote upgrade will be upgraded automatically. People running their own copies of dump1090 are advised to add --gain -10 to their dump1090 command line arugments to obtain these same improvements.

* Allow piaware to upgrade a package (piaware or dump1090) even if the current version can't be determined, like when it isn't installed. Since previous versions of the piaware bootable image shipped with dump1090 but dump1090 wasn't installed as a dpkg, piaware versions prior to 1.20 can't upgrade dump1090 through the manual (user-triggered) or automatic (flightaware-triggered) upgrade process.

* Make piaware exit if it asks for a restart of itself but didn't die. In some cases upgrading could leave two copies of piaware running at the same time.

* piaware's process ID number is now logged in piaware shutdown messages so the log isn't confusing if the old version is still exiting while the new one is already running. (People upgrading from 1.19-3 will still see the potentially confusing messages; future upgrades from 1.20-1 will have clearer log messages.)

* When piaware is looking for a dump1090 control script in /etc/init.d, make sure it prefers like fadump1090.sh to fadump1090.sh.dpkg-old.

* Bug fix to make renaming /tmp/piaware.out to /tmp/piaware.out.yesterday to be more likely to occur on the UTC day boundary.

* "pi" user's password on SD card image has been changed from the default raspberry to flightaware to help thwart possible automated attacks against Raspberry Pi devices running Raspbian with the default account and password.

piaware 1.19-3
---
* The 1.19-2 package was corrupted. We always bump the version for every change due to CDN caching and whatnot.


piaware 1.19-2
---
* Compress the ADS-B messages, not just the non-ADS-B messages.

piaware 1.19-1
---
* New compression techniques reduce upstream bandwidth by 2/3rds without filtering any additional messages.

* Disconnect from the server after many unrecognized server messages.

* Report full version when running piaware -v to get version number.

* Remove raspi-copies-and-fills from dependencies. This makes the piaware Debian package compatible with more systems not based on Raspberry Pi.

piaware 1.18-2
---
* Principally this release is to bump the version number because the 1.18-1 SD card image zip file was corrupt.

* Reload adept config on update request in case piaware-config has been run and used to change something since piaware last started.

piaware 1.18-1
---
* Fix "too many nested evaluations" error on systems without an eth0 device.

* Include full piaware version (like 1.18-1 vs just 1.18) in login message.

* Cache the mac address once it is known, for performance.

piaware 1.17-2
--
* Fix bug in reconnecting after receiving an unrecognized message from the server.

* Get a mac address from alternate source like wlan0 if no eth0 is present

* Don't invoke rpi-update as part of a full update.

piaware 1.17-1
--
* Disconnect/reconnect after detecting an error in a server message. Although we don't believe the runaway logging is caused by a server message, whatever the cause this should interrupt the runaway.

* After disconnecting from the server wait 60 seconds before reconnecting. Again the goal here mainly is to slow things down.

* Don't continue through the server message handler if we get an error reading from the server socket.

* Don't try to log errors about messages theoretically received from the server, back to the server.

* Add a -showtraffic option to piaware to aid debugging.


piaware 1.17
---
* Improved connection / re-connection handling and stability (important update)

* Do not consider issuer of SSL certificate, in light of potential changes during SSL cert renewal.

piaware 1.16
---
* Reworked problem detection and restart logic: Piaware will now reliably attempt to restart dump1090 if no messages are received in an hour and piaware can find a startup script for dump1090 in /etc/init.d to restart it with.

* Piaware will now attempt to start dump1090 if no ADS-B producer program is seen listening for connections on port 30005 (the "Beast" binary data port) for more than six minutes.

* Most piaware messages logged locally are now also forwarded to FlightAware. This will greatly help with debugging and users will soon be able to retrieve the last few hours of log messages via the FlightAware website.

* New remote update capability for updating Raspbian and piaware. Automatic and manual updates are supported. Both can be enabled or disabled on the device using piaware-config and auto updates can be disabled by the user through the FlightAware website. If enabled the user will be able to issue manual updates through the FlightAware website, updating PiAware, other Debian packages, and the operating system and boot firmware as well as rebooting and restarting piaware and dump1090.

* If the connection is lost with the FlightAware server then the reconnect interval is randomized between 60 and 120 seconds rather than hard-set at 60 seconds to ease the server load when the adept server is restarted and a thousand plus piaware hosts all reconnect at the same time

piaware 1.15
---
* Piaware will now attempt to restart dump1090 if no messages are received in an hour.

* Multiple adept servers are now tried, round-robin. The IP of the FlightAware server is now listed as well as the hostname. (This allows connection in some cases where there are DNS problems on the local host.)

* Some addition versions of Linux are now supported. (thanks to github user brookst (Tim Brooks) for this)

piaware 1.14
---
Mon, 06 Oct 2014 16:50:47 +0000

* faup1090 now exits if it loses its connection.
Before this if dump1090 restarted for some reason then faup1090 would sit there idefinitely and passing no data to piaware, even after dump1090 came back. Hat tip to Oliver Jowett (github user "mutability") for the fix.

* faup1090 services table bug fix
A mistake in how the services table was defined in faup1090 caused faup1090 to go past the end of the table when initializing and manipulating the TCP listening port. It's a wonder it didn't cause a coredump. Hat tip again to Oliver Jowett for pointing out the bug...

* Certificate validation failures on some other Linux systems' version of OpenSSL have been fixed. Hat tip to John Carroll (FA user johncarroll944) for the fix.

* Picked up numerous upstream dump1090 improvements and bug fixes, mostly by Oliver Jowett, through Malcolm Robb's dump1090 on github:

 * Improved client EOF handling.

 * Check if bit correction happened before bailing out due to a bad CRC.

 * Prefer to use global CPR decoding where possible.

 * Add --stats-every option, add sample block counters

 * Better error reporting if dump1090 is unable to bind a listening port.


piaware 1.13-1
---
Mon, 30 Sep 2014 12:49:09 +0000


* piaware can now login without a FlightAware user's username and password having been pre-configured on the Raspberry Pi.

* Stop shipping librtlsdr as faup1090 doesn't need it.

* Properly install non-executable files without executable bit set.

* piaware package is now digitally signed with a FlightAware developers key.

* Almost all Debian package "lintian" complaints have been fixed.

* Fix typo in faup1090 lost-connection message (thanks to github user saiarcot895).

* All programs installed by piaware (piaware, piaware-config, piaware-status and faup1090) now have manual pages.

piaware 1.12
---
Fri, 19 Sep 2014 15:17:09 +0000

* Piaware 1.12 will correctly report version 1.12.  1.11 reported 1.10
and caused a fair bit of confusion.  Sorry.

* When piaware is up and successfully receiving and forwarding messages it
should now log only the every-five-minutes traffic summary.

* Any failure to determine the local IP address should no longer cause problems.

* A few log messages shortened by having them not identify the function that
issued them.

* The net-tools package is now a prerequisite for PiAware.  This comes
installed by default on Raspberry Pi / Raspbian but may help people trying
to get PiAware working on other versions of Linux.

* If piaware can't determine the local machine's MAC address then it aborts
at startup.  This should only be relevant to people running PiAware on something
other than Raspberry Pi / Raspbian as other versions of Linux may
not provide the expected method piaware uses to figure that out.

piaware 1.11
---
Sat,  6 Sep 2014 17:13:29 +0000

* Piaware now provides (hopefully) much more understandable log messages.
For instance, while the prior message might have been
    reaped child 18593 SIG SIGHUP
The new message is
    the system confirmed that process $pid exited after receiving a hangup signal

* Piaware Now logs the number of ADS-B messages received in the reporting 
  interval (5 minutes) as well as cumulative, which makes it easier to see 
  how many messages you are getting without having to do arithmetic in your 
  head.
    
* When piaware is asked by the system to shutdown, its log messages now says
that in a more clear way.
    
* cryptic "not-connected-yet" logged in some cases as a message source
replaced by the hopefully less cryptic
"(not currently connected to an adsb source)", which may be true when
we have been connected but are no longer.

* we now log when we send a hangup signal and what process we are sending it to
    
* Raise time limit before reconnecting for no msgs
    
    Previously after five minutes if it hadn't received any messages piaware
    would kill and restart faup1090 and reconnect to it in order to get it
    to reconnect to dump1090 or modesmixer or whatnot, just in case there
    was a problem with the connection.
    
    FlightAware user "fill" pointed out that in off hours it will be common for
    many receivers to not see any messages for more than five minutes.
    
    The timeout is raised to one hour and the log message now better explains
    what's going on:
    
    "no new messages received in $secondsSinceLast seconds, it might just be 
    that there haven't been any aircraft nearby but I'm going to possibly 
    restart faup1090 and definitely reconnect, just in case there's a problem 
    with the current connection..."


piaware 1.10
---
6 Sep 2014 05:27:58 +0000

* At midnight UTC, renames /tmp/piaware.out to /tmp/piaware.out.yesterday
and starts a new /tmp/piaware.out

* Local IP address is sent in login and health messages.  With server-side
software that has yet to be written it'll provide a way for people to 
figure out the local IP that their Pi is on.

* Bug fixed where it would log not-connected-yet when it was connected.

* The /etc/init.d/piaware script now references the full path to
start-stop-daemon and piaware-config, making PiAware work with
DarkBasic Minimal Rasbarian and being a better practice, anyway.
(Hat Tip to FlightAware user PeterHR for the report.)

* Periodic alive messages from the server are no longer logged after


piaware 1.9
---
Sat, 30 Aug 2014 14:15:54 +0000

* piaware now figures out whatever program is serving beast data on
port 30005 and is cool with it

* new piaware-status program to inspect and report on the running state 
of the piaware toolchain

* piaware will now disconnect and reconnect from the ADS-B source and 
restart faup1090 if messages aren't received for a while

* piaware now receives "alive" messages from the server (release 1.9 and
above) and will disconnect and reconnect after a timeout if one is not 
received

* piaware server now disconnects if it hasn't received anything from piaware 
for quite a while

* piaware server now tells piaware when it is going down before it 
intentionally disconnects

piaware 1.8
---
30 Aug 2014 18:38:07 +0000

* Fix traceback in piaware traffic report when no traffic has occurred.

* Fix traceback in connect retry code when piaware has trouble connecting
to FlightAware

piaware 1.7-1
---
Thu, 21 Aug 2014 05:49:14 +0000

* Remove the Tk toolkit as a dependency.

* Login failures are now successfully reported back to piaware and logged
in /tmp/piaware.out.

* Piaware will exit after a login failure as manual intervention to change
the user name and/or password is probably required.

* Piaware now starts receiving data sooner after startup, typically within
about ten seconds.

* Fix bug in keep_trying_to_connect that would cause it not to.

* When piaware is trying to reconnect to FlightAware after losing its server
conenction, its log messages are much more clear / descriptive.

* Failure of piaware to initially connect to FlightAware within ten seconds
resulted in piaware terminating.  Failure of piaware to reconnect
after losing a connection could result in a stuck piaware
that was running but wouldn't reconnect or forward messages.  
Piaware now retries connections after connection failures both at startup
and after it has successfully connected.

* Piaware now logs in one log message the number of messages received from
dump1090 and the number of messages sent to FlightAware, one minute after
startup and every five minutes thereafter.  Previously it logged for
each thousand messages received and thousand messages sent the frequency
of which could be highly variable based on location and time of day.

