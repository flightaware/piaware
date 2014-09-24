#
# makefile for piaware doc files
#

DOCDIR=/usr/share/man/man1

MANPAGES= faup1090.1 piaware.1 piaware-config.1 piaware-status.1

all:
	@echo "'make install' to install docs"

install:
	@echo ---- installing docs
	cp $(MANPAGES) $(DOCDIR)
	@echo --- compressing docs
	cd $(DOCDIR); gzip -9 $(MANPAGES)

