


LIB=$(PREFIX_DIR)/lib/fa_adept_packages

FILES=fa_adept_config.tcl fa_adept_client.tcl piaware.tcl ca/DigiCertCA.crt

all:	pkgIndex.tcl
	@echo '"make install" to install'

pkgIndex.tcl:	$(FILES)
	echo 'pkg_mkIndex .' | $(TCLSH)

install:    all
	mkdir -p $(LIB)
	cp $(FILES) pkgIndex.tcl $(LIB)
