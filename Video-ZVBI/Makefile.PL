#
# Copyright (C) 2006-2007 Tom Zoerner. All rights reserved.
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# For a copy of the GPL refer to <http://www.gnu.org/licenses/>
#
# $Id: Makefile.PL,v 1.2 2007/11/23 22:20:19 tom Exp tom $
#

use 5.7.1;  # note: keep in sync with ZVBI.pm and Meta.yml

use ExtUtils::MakeMaker;
use ExtUtils::Liblist;

#
# Since MakeMaker considers missing libraries "probably harmless"
# we perform a search for libzvbi beforehand and abort if it's missing.
#
my $libs = '-lzvbi';
my $inc = '';

if (($#ARGV >= 0) && ($ARGV[0] =~ /^LIBPATH=(.*)/)) {
        my $libpath = $1;
        shift @ARGV;
        $libs = "-L$libpath $libs";
        $libpath =~ m#^(/.*)/lib$# and $inc = "$1/include";
        die "Cannot access $libpath: $!\n" unless -d $libpath;
        print STDERR "Probing for prerequisite libzvbi in $libpath...\n";
} else {
        print STDERR "Probing for prerequisite libzvbi at standard paths...\n";
}
my $ll = ExtUtils::Liblist->ext($libs, 1, 1);  # verbose, return names
die "NA: libzvbi not found - specify 'LIBPATH=/...' on command line\n" unless $#$ll >= 0;

#
# Compile path and base name of the library (sans minor version) into the
# module for dynamic loading
#
my $lso = $ll->[0];
$lso =~ s#\.\d+\.0$##;
my $def = "-DLIBZVBI_PATH=\\\"$lso\\\"";

# load optional symbols danymically from shared library
$def .= " -DUSE_DL_SYM";

# use packaged header file instead of the one that may or may not be installed
$def .= " -DUSE_LIBZVBI_INT";

#
# Generate the Makefile
#
WriteMakefile(
        'NAME'          => 'Video::ZVBI',
        'VERSION_FROM'  => 'ZVBI.pm',
        'LIBS'          => [ $libs ],
        'DEFINE'        => $def,
        'INC'           => $inc,
);

