#
# makefile for tcllauncher app for piaware-status - interactive program to
#  get the status of the piaware toolchain
#

PREFIX=/usr
TCLLAUNCHER := $(shell which tcllauncher)
TCLSH=$(shell which tclsh || which tclsh8.6)

all:
	@echo "'make install' to install piaware-status"

test:
	$(TCLSH) ./gps_status.test

install:
	install -d $(DESTDIR)$(PREFIX)/bin $(DESTDIR)$(PREFIX)/lib/piaware-status
	install -m 0755 $(TCLLAUNCHER) $(DESTDIR)$(PREFIX)/bin/piaware-status
	install *.tcl $(DESTDIR)$(PREFIX)/lib/piaware-status
