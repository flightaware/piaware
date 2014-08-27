#
# piaware client-side top-level Makefile
#

all:
	@echo "'make install' to install client package and program"

install:
	$(MAKE) -C package install
	$(MAKE) -C programs/piaware install
	$(MAKE) -C programs/piaware-config install
	$(MAKE) -C programs/piaware-status install
	install scripts/piaware-rc-script /etc/init.d/piaware

install-server:
	cd programs/fa_adept_server;make install

