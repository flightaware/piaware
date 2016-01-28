#
# makefile for piaware doc files
#

PREFIX=/usr

MANPAGES=faup1090.1 piaware.1 piaware-config.1 piaware-status.1

all:
	@echo "'make install' to install docs"

install:
	install -d $(DESTDIR)$(PREFIX)/share/man/man1
	install $(MANPAGES) $(DESTDIR)$(PREFIX)/share/man/man1
