#
# makefile for tcllauncher app for piaware-config - interactive program to
#  configure and do other stuff as a FlightAware adept client
#

LIB=$(PREFIX_DIR)/lib
BIN=$(PREFIX_DIR)/bin

CLIENT_INSTALLFILES= *.tcl

PROGNAME=piaware-config

all:
	@echo "'make install' to install $(PROGNAME)"

install-client:
	@echo ---- installing client
	-install $(BIN)/tcllauncher $(BIN)/$(PROGNAME)
	mkdir -p $(LIB)/$(PROGNAME)
	cp $(CLIENT_INSTALLFILES) $(LIB)/$(PROGNAME)

install: install-client
