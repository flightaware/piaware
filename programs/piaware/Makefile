#
# makefile for tcllauncher app for piaware - ADS-B uploader using
# FA's simple aviation data exchange protocol
#

LIB=/usr/lib
BIN=/usr/bin
TCLSH=tclsh8.5

CLIENT_INSTALLFILES= *.tcl

PROGNAME=piaware

all:
	@echo "'make install' to install $(PROGNAME)"

install-client:
	@echo ---- installing client
	-install $(BIN)/tcllauncher $(BIN)/$(PROGNAME)
	mkdir -p $(LIB)/$(PROGNAME)
	cp $(CLIENT_INSTALLFILES) $(LIB)/$(PROGNAME)

install: install-client
