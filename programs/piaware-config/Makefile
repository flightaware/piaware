#
# makefile for tcllauncher app for piaware-config - interactive program to
#  configure and do other stuff as a FlightAware adept client
#

PREFIX=/usr
TCLLAUNCHER := $(shell which tcllauncher)

all:
	@echo "'make install' to install piaware-config"

install:
	install -d $(DESTDIR)$(PREFIX)/bin $(DESTDIR)$(PREFIX)/lib/piaware-config
	install -m 0755 $(TCLLAUNCHER) $(DESTDIR)$(PREFIX)/bin/piaware-config
	install *.tcl $(DESTDIR)$(PREFIX)/lib/piaware-config
