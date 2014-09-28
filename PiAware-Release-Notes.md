piaware 1.13-1
---

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

