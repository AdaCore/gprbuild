all:
	gnatmake -Pgprconfig

clean_doc:
	@cd doc; ${RM} gprconfig.cp gprconfig.log gprconfig.ky gprconfig.toc
	@cd doc; ${RM} gprconfig.aux gprconfig.fn gprconfig.pg
	@cd doc; ${RM} gprconfig.tp gprconfig.cps gprconfig.vr

clean: clean_doc
	gnat clean -q -Pgprconfig
	@${RM} standard_foo.gpr doc/gprconfig.pdf

distclean: clean
	${RM} config.log config.status doc/sdefault.ads

doc: doc/gprconfig.pdf
doc/gprconfig.pdf: doc/gprconfig.texi
	cd doc; echo x | texi2dvi -p gprconfig.texi
	${MAKE} clean_doc

test: all force
	${RM} standard_foo.gpr
	./gprconfig -o standard_foo.gpr -config GNAT,/usr/local/gnat-5.05w/bin -batch
	@cat standard_foo.gpr

force:

