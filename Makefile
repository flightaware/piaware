#
# piaware client-side top-level Makefile
#

# locate the config directory of the init system
SYSTEMD := $(shell ls -d /etc/systemd/system/ 2>/dev/null)
SYSVINIT := $(shell ls -d /etc/init.d/ 2>/dev/null)
TCLSH=$(shell which tclsh || which tclsh8.5 || which tclsh8.6)
USR_DIR := /usr

ifneq ($(DESTDIR),)
    DESTDIR := $(DESTDIR)/
endif

ifeq ($(PREFIX),)
    PREFIX_DIR := $(DESTDIR)$(USR_DIR)
else
    PREFIX_DIR := $(DESTDIR)$(PREFIX)/$(USR_DIR)
    $(warning Installing to $(DESTDIR)$(PREFIX))
endif

export TCLSH
export PREFIX_DIR

all:
	@echo "'make install' as root to install client package and program"

install:
	$(MAKE) -C package install
	$(MAKE) -C programs/piaware install
	$(MAKE) -C programs/piaware-config install
	$(MAKE) -C programs/piaware-status install
	$(MAKE) -C doc install

# conditionally install init services
ifdef SYSVINIT
	install -d $(DESTDIR)$(SYSVINIT)
	install scripts/piaware-rc-script $(DESTDIR)$(SYSVINIT)piaware
else
ifdef SYSTEMD
	install -d $(DESTDIR)/$(SYSTEMD)
	install scripts/piaware.service $(DESTDIR)$(PREFIX)/$(SYSTEMD)
else
	@echo "No init service found"
endif
endif

