#  Copyright (C) 2002 Regents of the University of Michigan,
#  portions used with permission 
#  For more information, see http://csem.engin.umich.edu/tools/swmf

SHELL =/bin/sh

default: SPECTRUM

include ../Makefile.def
include ../Makefile.conf
-include Makefile.RULES

# Other required libraries
LIBSHARE  = ${LIBDIR}/libSHARE.a
LIBBATSRUS = ../src/libBATSRUS.a
LIBTIMING = ${LIBDIR}/libTIMING.a

SEARCH_EXTRA = -I${LIBRARYDIR} -I${COUPLERDIR}
#
# Post processing executables
#

# ------------------------------- SPECTRUM -----------------
${BINDIR}/SPECTRUM.exe: ${LIBDIR}/libSHARE.a spectrum.o
	${LINK.f90} -o ${BINDIR}/SPECTRUM.exe spectrum.o \
		-L${LIBDIR} -lSHARE ${LflagMpi}

SPECTRUM:
	make ${BINDIR}/SPECTRUM.exe
	rm -f ./SPECTRUM.exe
	ln -s ${BINDIR}/SPECTRUM.exe .

# ------------------------------- SPECTRUM2 ---------------
OBJECTS = ModSpectrumLos.o ModSpectrum.o 

${OBJECTS} : ${LIBSHARE} ${LIBTIMING} ${LIBBATSRUS}

OBJECTS_EXE = Spectrum2.o 

${OBJECTS_EXE}: ${LIBSHARE} ${LIBTIMING} ${LIBBATSRUS} ${OBJECTS}

SPECTRUM2: ${OBJECTS_EXE} 
	${LINK.f90} -o SPECTRUM2.exe ${OBJECTS_EXE} ${OBJECTS} \
		-L../src -lBATSRUS \
		-L${LIBDIR} -lMAGNETOGRAM -lDEMT -lEMPIRICALEE \
		-lTIMING -lSHARE ${LflagMpi}

# ------------------------------- SNAPSHOT ----------------

${BINDIR}/SNAPSHOT.exe: ${LIBSHARE} select_snapshot.o
	${LINK.f90} -o ${BINDIR}/SNAPSHOT.exe select_snapshot.o \
		-L${LIBDIR} -lSHARE ${Lflag}

SNAPSHOT:
	make ${BINDIR}/SNAPSHOT.exe

${BINDIR}/ConvertRestart.exe:	ConvertRestart.o
	${LINK.f90} -o ${BINDIR}/ConvertRestart.exe ConvertRestart.o ${Lflag}

# ------------------------------- INTERPOLATE--------------

${BINDIR}/INTERPOLATE.exe: ${LIBSHARE} interpolate_output.o
	${LINK.f90} -o ${BINDIR}/INTERPOLATE.exe interpolate_output.o \
		-L${LIBDIR} -lSHARE ${LflagMpi}

INTERPOLATE:
	make ${BINDIR}/INTERPOLATE.exe

# ------------------------------- CRST --------------------

CRST:
	make ${BINDIR}/ConvertRestart.exe

# ------------------------------- EARTH_TRAJ --------------

OBJECTS1 = CON_geopack_internal.o ModUT.o

earth_traj.o:  ${LIBSHARE} ${OBJECTS1}

EARTH_TRAJ: earth_traj.o
	${LINK.f90} ${SEARCH} -o ${BINDIR}/EARTH_TRAJ.exe earth_traj.o \
		${OBJECTS1} -L${LIBDIR} -lSHARE ${Lflag}

TIME_CONV:  ${OBJECTS1} time_convert.o
	${LINK.f90} ${SEARCH} -o ${BINDIR}/TIME_CONV.exe time_convert.o \
		${OBJECTS1} -L${LIBDIR} -lSHARE ${Lflag}

TIME_TOCRNO:  ${OBJECTS1} time_to_cr_no.o
	${LINK.f90} ${SEARCH} -o ${BINDIR}/TIME_TOCRNO.exe time_to_cr_no.o \
		${OBJECTS1} -L${LIBDIR} -lSHARE ${Lflag}

#
# test for SPECTRUM
#
test_spectrum:
	@echo "test_spectrum_compile..." > ../test_spectrum.diff
	$(MAKE) test_spectrum_compile
	@echo "test_spectrum_run..." >> ../test_spectrum.diff
	$(MAKE) test_spectrum_run
	@echo "test_spectrum_check..." >> ../test_spectrum.diff
	$(MAKE) test_spectrum_check

SPECTRUM_chianti_tbl.dat: ../data/SPECTRUM/SPECTRUM_chianti_tbl.dat.gz
	gunzip -c ../data/SPECTRUM/SPECTRUM_chianti_tbl.dat.gz \
	> SPECTRUM_chianti_tbl.dat

test_spectrum_compile: SPECTRUM_chianti_tbl.dat
	make SPECTRUM

test_spectrum_run:
	rm -f test-spectrum.out test-spectrum.eps
	cp -f test-SPECTRUM.in SPECTRUM.in
	${MPIRUN} ./SPECTRUM.exe > test-spectrum.log

test_spectrum_check:
	${SCRIPTDIR}/DiffNum.pl -t -r=1e-5 -a=1e-12 \
		test-spectrum.out \
		test-spectrum.ref.gz > ../test_spectrum.diff
	@ls -l ../test_spectrum.diff

#
# test for SPECTRUM2
#
test_spectrum2:
	@echo "test_spectrum2 started"
	@echo "test_spectrum2_compile..." > ../test_spectrum2.diff
	$(MAKE) test_spectrum2_compile
	@echo "test_spectrum2_run..." >> ../test_spectrum2.diff
	$(MAKE) test_spectrum2_run
	@echo "test_spectrum2_check..." >> ../test_spectrum2.diff
	$(MAKE) test_spectrum2_check

test_spectrum2_compile: SPECTRUM_chianti_tbl.dat
	make SPECTRUM2

test_spectrum2_run:
	rm -f test-spectrum.out test-spectrum.eps
	cp -f test-SPECTRUM2.in SPECTRUM.in
	${MPIRUN} ./SPECTRUM2.exe > test-spectrum2.log

test_spectrum2_check:
	${SCRIPTDIR}/DiffNum.pl -t -r=1e-5 -a=1e-12 \
		test-spectrum2.out \
		test-spectrum.ref.gz > ../test_spectrum2.diff
	@ls -l ../test_spectrum2.diff

#
#	cleaning
#
clean: cleanfiles

distclean: clean
	rm -f SPECTRUM*.exe SPECTRUM.in test-spectrum*.log \
		test-spectrum.out test-label.out SPECTRUM_chianti_tbl.dat

