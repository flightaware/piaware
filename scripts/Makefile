PREFIX=/usr
ETCDIR=/etc

# locate the config directory of the init system
SYSTEMD := $(shell ls -d $(DESTDIR)$(ETCDIR)/systemd/system 2>/dev/null | sed "s@^$(DESTDIR)@@g")
SYSVINIT := $(shell ls -d $(DESTDIR)$(ETCDIR)/init.d 2>/dev/null | sed "s@^$(DESTDIR)@@g")

all:
	@echo "'make install' to install scripts"

install:
	install -d $(DESTDIR)$(PREFIX)/lib/piaware/helpers
	install -m 0755 update-piaware-config $(DESTDIR)$(PREFIX)/lib/piaware/helpers

# conditionally install init services
ifdef SYSVINIT
	install -d $(DESTDIR)$(SYSVINIT)
	install -m 0755 piaware-rc-script $(DESTDIR)$(SYSVINIT)/piaware
endif
ifdef SYSTEMD
	install -d $(DESTDIR)$(SYSTEMD)
	install scripts/piaware.service $(DESTDIR)$(SYSTEMD)/piaware.service
endif
