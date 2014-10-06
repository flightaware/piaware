
LIB=/usr/lib/fa_adept_packages

TCLSH=tclsh

FILES=fa_adept_config.tcl fa_adept_client.tcl piaware.tcl ca/DigiCertCA.crt

all:	pkgIndex.tcl
	@echo '"make install" to install'

pkgIndex.tcl:	$(FILES)
	echo 'pkg_mkIndex .' | $(TCLSH)

install:    all
	mkdir -p $(LIB)
	cp $(FILES) pkgIndex.tcl $(LIB)
