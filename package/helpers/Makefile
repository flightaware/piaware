PREFIX=/usr
LIB=$(PREFIX)/lib/piaware_packages

CFLAGS=-Wall -Werror -O

all: droproot
	@echo '"make install" to install'

droproot:
	$(CC) $(CXXFLAGS) $(CFLAGS) $(LDFLAGS) -o droproot droproot.c

clean:
	rm -f droproot

install: droproot
	install -d $(DESTDIR)$(LIB)/helpers
	install -m 0755 update-piaware-config droproot restart-receiver restart-network $(DESTDIR)$(LIB)/helpers
