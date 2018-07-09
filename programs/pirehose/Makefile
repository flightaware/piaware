#
# makefile for tcllauncher app for pirehose - a firehose implementation
# using data from a single PiAware receiver
#

PREFIX=/usr
LIB=$(PREFIX)/lib/pirehose
TCLLAUNCHER := $(shell which tcllauncher)

all:
	@echo "'make install' to install pirehose"

install:
	install -d $(DESTDIR)$(PREFIX)/bin $(DESTDIR)$(LIB)
	install -m 0755 $(TCLLAUNCHER) $(DESTDIR)$(PREFIX)/bin/pirehose
	install *.tcl $(DESTDIR)$(LIB)
	install -m 0755 *.sh $(DESTDIR)$(LIB)
