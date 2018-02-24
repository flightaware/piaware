PREFIX=/usr
LIB=$(PREFIX)/lib/fa_adept_codec
TCLSH=$(shell which tclsh || which tclsh8.6 || which tclsh8.5)

FILES=fa_adept_codec.tcl fa_adept_schema.tcl none.codec adept_1.x.codec adept_2.1.codec

all:
	@echo '"make install" to install'

pkgIndex.tcl: $(FILES)
	echo 'pkg_mkIndex . $(FILES)' | $(TCLSH)

install: pkgIndex.tcl
	install -d $(DESTDIR)$(LIB)
	install $(FILES) pkgIndex.tcl $(DESTDIR)$(LIB)

test:
	$(TCLSH) ./fa_adept_codec.test
