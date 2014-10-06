#
# makefile for tcllauncher app for piaware-status - interactive program to
#  get the status of the piaware toolchain
#

LIB=/usr/lib
BIN=/usr/bin
TCLSH=tclsh8.5

CLIENT_INSTALLFILES= *.tcl

PROGNAME=piaware-status

all:
	@echo "'make install' to install $(PROGNAME)"

install-client:
	@echo ---- installing client
	-install $(BIN)/tcllauncher $(BIN)/$(PROGNAME)
	mkdir -p $(LIB)/$(PROGNAME)
	cp $(CLIENT_INSTALLFILES) $(LIB)/$(PROGNAME)

install: install-client
