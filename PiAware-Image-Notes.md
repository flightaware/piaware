The FlightAware PiAware system image is a copy of Raspbian with a few changes.

Here's a summary of the changes from the default version of Raspbian.

* apt-get update and upgrade and rpi-update were performed to update the base image to the latest.
* dump1090 and the RTL-SDR libraries are preinstalled.
* The PiAware package is preinstalled.
* dump1090 and piaware are configured to start automatically whenever the Raspberry Pi boots up.
* The default hostname has been changed from raspberrypi to piaware.
* The apt tool is pointed look by default to a Raspbian mirror at FlightAware (/etc/apt/sources.list)
* The wolfram-engine package is removed, freeing more than 400 MB of storage.
* A few handy packages have been installed using apt-get such as git, automake, cmake, screen, kermit, telnet and rsync.
* The /tmp filesystem is configured to run out of RAM to reduce I/O to the SD card.
* The filesystem check program is configured to try to fix any problems without asking the user to confirm.
* Higher USB current limit on Raspberry Pi Model B Plus is enabled.
* Swapping to the SD card is disabled.  Although this saves wear on the SD card, if the system runs out of memory it will crash.
* ssh host keys are deleted as the last step of creating the install image and the rc.local script has been extended to regenerate host keys if they are not present.  This causes each PiAware image to generate its own ssh host keys, improving security.
* The default password has been changed from raspberry to flightaware
 
