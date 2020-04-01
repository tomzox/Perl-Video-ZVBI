#!/bin/bash
#
# Script for automatically generating Debian binary package
#
# $Id: create_deb.sh,v 1.4 2020/04/01 07:19:28 tom Exp tom $
#
set -e

version="1.0.0"
name="libzvbi-perl"
arch="amd64"

BASEDIR=deb/${name}_${version}_${arch}

echo "...creating directories"
mkdir -p $BASEDIR/DEBIAN
mkdir -p $BASEDIR/usr/share/perl5/Video
mkdir -p $BASEDIR/usr/lib/perl5/auto/Video/ZVBI
mkdir -p $BASEDIR/usr/share/doc/$name
mkdir -p $BASEDIR/usr/share/man/man3

echo "...creating control and copyright files"
cat >$BASEDIR/DEBIAN/control <<EoF
Package: $name
Priority: optional
Section: perl
Maintainer: T. Zoerner <tomzo@users.sourceforge.net>
Architecture: $arch
Version: $version
Depends: perl (>= 5.7), libzvbi0 (>= 0.2.16)
Recommends: zvbi
Description: Perl interface to the "ZVBI" VBI device capture library
 Using the ZVBI library, this Perl module provides object-oriented
 interfaces for (from lowest to highest level of abstraction) accessing
 raw VBI sampling devices (currently the Linux V4L & V4L2 API and the
 FreeBSD, OpenBSD, NetBSD and BSDi bktr driver API are supported),
 a versatile raw VBI bit slicer, decoders for various data services
 and basic search, and render and export functions for teletext pages.
Homepage: https://github.com/tomzox/Perl-Video-ZVBI
EoF

cat >$BASEDIR/usr/share/doc/$name/copyright <<EoF
Copyright (C) 2006-2020 T. Zoerner. All rights reserved.

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 2 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

For a copy of the GNU General Public License see:
/usr/share/common-licenses/GPL-2

Alternatively, see <http://www.gnu.org/licenses/>.
EoF

# copy doc files
echo "...copying doc files"
cp -fp Video-ZVBI/README $BASEDIR/usr/share/doc/$name/README
cp -fp Video-ZVBI/META.yml $BASEDIR/usr/share/doc/$name/META.yml
gzip -n -9 -c Video-ZVBI/Changelog > $BASEDIR/usr/share/doc/$name/changelog.gz

# copy generated files to perl module dir
# NOTE pre-requisite: cd Video-ZVBI && perl Makefile.PL && make
echo "...copying generated files from blib tree"
cp -fp Video-ZVBI/blib/lib/Video/ZVBI.pm $BASEDIR/usr/share/perl5/Video/ZVBI.pm
chmod 0644 $BASEDIR/usr/share/perl5/Video/ZVBI.pm
strip -o $BASEDIR/usr/lib/perl5/auto/Video/ZVBI/ZVBI.so Video-ZVBI/blib/arch/auto/Video/ZVBI/ZVBI.so

# copy and compress manual page
echo "...copying manual page"
gzip -n -9 -c Video-ZVBI/blib/man3/Video::ZVBI.3pm > $BASEDIR/usr/share/man/man3/Video::ZVBI.3pm.gz

# generating hash sums
echo "...generating MD5"
cd $BASEDIR
find usr -type f | xargs md5sum > DEBIAN/md5sums
cd .. # leaves us in deb/ sub-dir

# build package
# - FIXME switch to using "debuild" to resolve perlapi and shlib dependencies
# note "fakeroot" is used to have files owned by user "root"
# - this is optional for local packages; can be removed if you don't have this script
echo "...building package"
fakeroot dpkg-deb --build ${name}_${version}_${arch} ${name}_${version}_${arch}.deb

echo "...checking package with lintian"
lintian ${name}_${version}_${arch}.deb
