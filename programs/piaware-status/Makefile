#
# makefile for tcllauncher app for piaware-status - interactive program to
#  get the status of the piaware toolchain
#

PREFIX=/usr
TCLLAUNCHER := $(shell which tcllauncher)

all:
	@echo "'make install' to install piaware-status"

install:
	install -d $(DESTDIR)$(PREFIX)/bin $(DESTDIR)$(PREFIX)/lib/piaware-status
	install -m 0755 $(TCLLAUNCHER) $(DESTDIR)$(PREFIX)/bin/piaware-status
	install *.tcl $(DESTDIR)$(PREFIX)/lib/piaware-status
