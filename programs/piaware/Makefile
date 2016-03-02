#
# makefile for tcllauncher app for piaware - ADS-B uploader using
# FA's simple aviation data exchange protocol
#

PREFIX=/usr
LIB=$(PREFIX)/lib/piaware
TCLLAUNCHER := $(shell which tcllauncher)

all:
	@echo "'make install' to install piaware"

install:
	install -d $(DESTDIR)$(PREFIX)/bin $(DESTDIR)$(LIB)
	install -m 0755 $(TCLLAUNCHER) $(DESTDIR)$(PREFIX)/bin/piaware
	install *.tcl $(DESTDIR)$(LIB)
	$(MAKE) -C helpers install
