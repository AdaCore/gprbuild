#!/bin/sh
# bootstrap.sh - a simple bootstrap for building gprbuild with xmlada

progname=bootstrap

prefix=/usr/local
bindir=/bin
datarootdir=/share
libexecdir=/libexec

srcdir=$PWD
xmlada_src=../xmlada
kb_src=../gprconfig_kb

CC=${CC:-cc}
GNATMAKE=${GNATMAKE:-gnatmake}
CFLAGS=${CFLAGS:-$CFLAGS}
GNATMAKEFLAGS=${GNATMAKEFLAGS:--j0}

usage() {
    cat >&2 <<EOF
usage: $progname [options]

Options [defaults in brackets]:
  --prefix=DIR       installation prefix [$prefix]
  --bindir=DIR       user executables [PREFIX/bin]
  --libexecdir=DIR   program executables [PREFIX/libexec]
  --datarootdir=DIR  read-only arch.-independent data root [PREFIX/share]

  --srcdir=DIR       source code path [$PWD]

  --with-xmlada=DIR  xmlada source path [$xmlada_src]
  --with-kb=DIR      gprconfig knowledge base [$kb_src]

  --build            build only but do not install
  --install          install only, skip build steps

Environment variables:
  CC                 specify C compiler [$CC]
  CFLAGS             set C and Ada compilation flags [$CFLAGS]
  DESTDIR            optional for staged installs
  GNATMAKE           specify gnatmake Ada builder [$GNATMAKE]
  GNATMAKEFLAGS      additional Ada builder flags [$GNATMAKEFLAGS]
EOF
exit 0
}

error() {
    printf -- "%s: $1" "$progname" "$(echo "$@" | cut -c 3-)" >&2
    exit 1
}

while :; do
    case $1 in
        --prefix=?*)      prefix=${1#*=} ;;
        --bindir=?*)      bindir=${1#*=} ;;
        --libexecdir=?*)  libexecdir=${1#*=} ;;
        --datarootdir=?*) datarootdir=${1#*=} ;;

        --srcdir=?*)      srcdir=${1#*=} ;;
        --with-xmlada=?*) xmlada_src=${1#*=} ;;
        --with-kb=?*)     kb_src=${1#*=} ;;
	--build)          MODE="build";;
	--install)        MODE="install";;

        -h|-\?|--help)    usage ;;

        *=*)              error '%s: Requires a value, try --help\n' "$1" ;;
        -?*)              error '%s: Unknown option, try --help\n' "$1" ;;
        *)                break # End of arguments.
    esac
    shift
done

set -e

inc_flags="-I$srcdir/src -I$srcdir/gpr/src -I$xmlada_src/sax -I$xmlada_src/dom \
-I$xmlada_src/schema -I$xmlada_src/unicode -I$xmlada_src/input_sources"

# Programs to build and install
bin_progs="gprbuild gprconfig gprclean gprinstall gprname gprls"
lib_progs="gprlib gprbind"

# Windows and Unix differencies

UName=`uname | cut -b -5`
PutUsage=gpr/src/gpr-util-put_resource_usage

rm -f ${PutUsage}.adb

if [ "$UName" = "CYGWI" ] || [ "$UName" = "MINGW" ]
then
	cp ${PutUsage}__null.adb ${PutUsage}.adb
else
	ln -s $PWD/${PutUsage}__unix.adb ${PutUsage}.adb
fi

# Build

if [ "x"${MODE} = "x" ] || [ ${MODE} = "build" ];
then
	# Install the gprconfig knowledge base
	rm -rf "$srcdir"/share/gprconfig
	cp -r "$kb_src"/db "$srcdir"/share/gprconfig

	command $CC -c $CFLAGS "$srcdir"/gpr/src/gpr_imports.c

	for bin in $bin_progs; do
		command $GNATMAKE $inc_flags "$bin"-main -o "$bin" $CFLAGS $GNATMAKEFLAGS -largs gpr_imports.o
	done

	for lib in $lib_progs; do
		command $GNATMAKE $inc_flags "$lib" $CFLAGS $GNATMAKEFLAGS -largs gpr_imports.o
	done
fi;

# Install

if [ "x"${MODE} = "x" ]  || [ ${MODE} = "install" ];
then
	mkdir -p "$DESTDIR$prefix$bindir"
	mkdir -p "$DESTDIR$prefix$libexecdir"/gprbuild
	mkdir -p "$DESTDIR$prefix$datarootdir"/gprconfig
	mkdir -p "$DESTDIR$prefix$datarootdir"/gpr

	install -m0755 $bin_progs "$DESTDIR$prefix$bindir"
	install -m0755 $lib_progs "$DESTDIR$prefix$libexecdir"/gprbuild
	install -m0644 "$srcdir"/share/gprconfig/*.xml "$DESTDIR$prefix$datarootdir"/gprconfig
	install -m0644 "$srcdir"/share/gprconfig/*.ent "$DESTDIR$prefix$datarootdir"/gprconfig
	install -m0644 "$srcdir"/share/_default.gpr "$DESTDIR$prefix$datarootdir"/gpr/_default.gpr
fi
