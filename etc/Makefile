ETCDIR=/etc
INSTALL_SUDOERS=0

all:
	@echo "'make install' to install misc config"

install:
# conditionally install sudoers (only if explicitly requested)
ifeq ($(INSTALL_SUDOERS),1)
	install -d $(DESTDIR)$(ETCDIR)/sudoers.d
	install piaware.sudoers $(DESTDIR)$(ETCDIR)/sudoers.d/piaware
else
	@echo "Not installing sudoers file (set INSTALL_SUDOERS=1 to enable)"
endif
