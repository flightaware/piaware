PREFIX=/usr
LIB=$(PREFIX)/lib/fa_adept_packages

CFLAGS=-Wall -Werror -O

all:
	@echo '"make install" to install'

droproot:
	$(CC) $(CXXFLAGS) $(CFLAGS) $(LDFLAGS) -o droproot droproot.c

install: droproot
	install -d $(DESTDIR)$(LIB)/helpers
	install -m 0755 update-piaware-config droproot $(DESTDIR)$(LIB)/helpers
