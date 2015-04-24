#
# makefile for tcllauncher app for piaware - ADS-B uploader using
# FA's simple aviation data exchange protocol
#

LIB=$(PREFIX_DIR)/lib
BIN=$(PREFIX_DIR)/bin

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
