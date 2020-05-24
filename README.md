# ZVBI library interface module for Perl

This repository contains the sources of the "Video::ZVBI" Perl module,
which has its official home at
[https://metacpan.org/pod/Video::ZVBI](https://metacpan.org/pod/Video::ZVBI).
Please use the ticket interfaces at CPAN for reporting issues.
This module is equivalent to the
[Zvbi module for Python](https://pypi.org/project/Zvbi/).

This Perl extension module provides an object-oriented interface to the
[ZVBI library](http://zapping.sourceforge.net/ZVBI/index.html).
The ZVBI library allows accessing television broadcast data services such
as teletext or closed captions via analog or DVB video capture devices.

Official ZVBI library description:

> The ZVBI library provides routines to access raw VBI sampling devices
> (currently the Linux DVB &amp; V4L2 APIs and the FreeBSD, OpenBSD,
> NetBSD and BSDi bktr driver API are supported), a versatile raw VBI
> bit slicer, decoders for various data services and basic search, render
> and export functions for text pages. The library was written for the
> Zapping TV viewer and Zapzilla Teletext browser.

The ZVBI module for Perl covers all exported libzvbi functions.

The Perl interface is largely based on blessed references to binary
pointers. Internally the module uses the native C structures of libzvbi
as far as possible.  Only in the last step, when a Perl script wants
to manipulate captured data directly (i.e. not via library functions),
the structures' data is converted into Perl data types.  This approach
allows for a pretty snappy performance.

Best starting point to get familiar with the module is having a look
at the *Class Hierarchy*, description of the main classes in the
<A HREF="Video-ZVBI/ZVBI.pm">API documentation</A>,
and the example scripts provided in the
<A HREF="Video-ZVBI/examples/">examples/</A> sub-directory, which
demonstrate use of all the main classes. (The examples are a more or less
direct C to Perl ports of the respective programs in the `test/`
sub-directory of the libzvbi source tree, plus a few additions, such as a
teletext level 2.5 browser implemented in apx. 300 lines of
[Perl::Tk](https://metacpan.org/pod/Tcl::Tk).)
A description of all example scripts can be found in the API documentation
in section *Examples*.  Additionally you can look at the
[ZVBI home](http://zapping.sourceforge.net/ZVBI/index.html) and the
ZVBI library documentation (unfortunately not available online; built via
doxygen when compiling the library).

## Module information

Perl DLSIP-code: RcdOg

* development stage: stable release
* C compiler required for installation
* support by developer
* object oriented using blessed references
* licensed under GPL (GNU General Public License)

Supported operating systems (as determined by ZVBI library):

* Linux
* FreeBSD
* NetBSD
* OpenBSD

## Comparison with the "Video-Capture-VBI" Perl module

You may have noticed there already is a Perl module which provides similar
functionality.  The approach is completely different though: The older VBI
module contains an actual implementation of a teletext and VPS slicers and
databases, while ZVBI is an interface layer to an external C library.

Besides that, the reason for not just contributing code to the
existing module was that libzvbi alone can almost entirely replace
the older VBI module (i.e. it covers the same functionality, except
currently for the high-level "nexTView" EPG decoding.)  So there would
not much to be gained by merging the code. On the other hand, libzvbi
supports much more platforms, drivers (e.g. V4L2, DVB, BSD) and services,
so that it seems warranted to make that available to the Perl universe.

## Installation

Pre-requisite to the installation is a C compiler and the
[libzvbi library](http://zapping.sourceforge.net/ZVBI/index.html)
(oldest supported version is 0.2.16, or 0.2.4 when disabling
`USE_DL_SYM` in <A HREF="Video-ZVBI/Makefile.PL">Makefile.PL</A>)
which in turn requires the pthreads and PNG libraries. Once you have
these, installation can be done in the usual steps:

```console
    cd Video-ZVBI
    perl Makefile.PL
    make
    make install
```

However cleaner than installing directly is generating a package and
installing that, as this will ensure dependencies are available and
allow for easy removal of installed files. The repository contains a
shell script that creates a Debian package (also works for all derived
Linux distributions such as Ubuntu).  Using that, the steps for
installing are:

```console
    (cd Video-ZVBI && perl Makefile.PL && make)
    bash create_deb.sh
    dpkg -i deb/libzvbi-perl_*_amd64.deb
```

Note there are no dependencies on other Perl modules by the module itself.
Some of provided example scripts however depend on
[Perl::Tk](https://metacpan.org/pod/Tcl::Tk)

Trouble-shooting note: By default the module compiles against an
internal copy of libzvbi.h and loads symbols added in recent library
versions during module start from the shared library. If your compiled
module doesn't load, try disabling compile switches `USE_DL_SYM` and
`USE_LIBZVBI_INT` in Makefile.PL

## Bug reports

Please submit bug reports relating to the interface module via
[CPAN](https://metacpan.org/pod/Video::ZVBI).

If your bug report or request relates to libzvbi rather than the
interface module, please contact the libzvbi authors, preferably
via the [Zapping](http://zapping.sourceforge.net/) mailing list.
In case of capture problems, please make sure to specify which
operating system and hardware you are using, and of course which
version of libzvbi and which version of Perl and the ZVBI module
respectively.

## Documentation

For further information please refer to the following files:

* <A HREF="Video-ZVBI/ZVBI.pm">ZVBI.pm</A>: API documentation
* <A HREF="Video-ZVBI/Changelog">Changelog</A>: Release history &amp; change-log
* <A HREF="Video-ZVBI/README">README</A>: same content as on this page
* <A HREF="Video-ZVBI/COPYING">COPYING</A>: GPL-2 license

## Copyright

Copyright (C) 2006-2020 T. Zoerner.

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 2 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but <B>without any warranty</B>; without even the implied warranty of
<B>merchantability or fitness for a particular purpose</B>.  See the
<A HREF="LICENSE">GNU General Public License</A> for more details.
