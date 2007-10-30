# ZVBI library interface module

This repository contains the sources of the Perl "Video-ZVBI" module, which has its
official home at [https://metacpan.org/pod/Video::ZVBI](https://metacpan.org/pod/Video::ZVBI).
Please use the ticket interfaces at CPAN for reporting issues.

This Perl extension module provides an object-oriented interface to the ZVBI
library. The ZVBI library allows to access broadcast data services such as
teletext or closed captions via analog or DVB video capture devices.

Official ZVBI library description:

> The ZVBI library provides routines to access raw VBI sampling devices
> (currently the Linux V4L and and V4L2 API and the FreeBSD, OpenBSD,
> NetBSD and BSDi bktr driver API are supported), a versatile raw VBI
> bit slicer, decoders for various data services and basic search, render
> and export functions for text pages. The library was written for the
> Zapping TV viewer and Zapzilla Teletext browser.

The ZVBI Perl module covers all exported libzvbi functions.

The Perl interface is largely based on blessed references to binary
pointers. Internally the module uses the native C structures of libzvbi
as far as possible.  Only in the last step, when a Perl script wants
to manipulate captured data directly (i.e. not via library functions),
the structures' data is copied into Perl data types.  This approach
allows for a pretty snappy performance.

Best starting point to get familiar with the module is to have a look
at the [ZVBI library documentation](http://zapping.sourceforge.net/doc/libzvbi/index.html)
and the examples scripts provided in the <A HREF="Video-ZVBI/example/">example/</A>
subdirectory: these are more or less direct C to Perl ports of the respective programs
in the `test/` subdirectory of the libzvbi source tree, plus a few additions,
such as a teletext level 2.5 browser implemented in apx. 200 lines of
[Perl::Tk](https://metacpan.org/pod/Tcl::Tk).

## Module information

Perl DLSIP-code: bcdOg

* development stage: beta testing
* C compiler required for installation
* support by developer
* object oriented using blessed references
* licensed under GPL (GNU General Public License)

Supported operating systems (as determined by ZVBI library):

* Linux
* FreeBSD
* NetBSD
* OpenBSD

## Comparison with the Video-Capture::VBI module

You may have noticed that there already is a Perl VBI module which
provides very similar functionality.  The reason that a separate
module was created is that the approach is completely different:
the VBI module contains an actual implementation of a teletext and
VPS slicers and databases, while ZVBI is just an interface layer.

libzvbi is a very sophisticated and up-to-date implementation and
as such supports a wide range of platforms, drivers and data services.
The library is actively maintained by Michael Schimek, who was one
of the authors of the VBI interfaces in V4L and V4L2 (i.e. the Linux
video capture API.)  In contrast, most of the VBI module's code
appears to date back at least to 1999.  To update it to the status
quo of libzvbi would have meant to either reinvent the wheel, i.e.
solve problems that are already solved in libzvbi (e.g. support for
capture chips with different sampling rates such as Philips SAA7134
and support for V4l2), or to duplicate code from libzvbi into the
VBI module.  That would have been much more effort and certainly
less elegant than just creating an interface to libzvbi.

Other benefits are that libzvbi has extensice documentation and is
optimized for performance (i.e. the ZVBI Perl module is about
5 to 10 times faster when capturing teletext packets into a file
than the VBI module.)  The only downside is EPG (ETS 300 707),
which is supported by the VBI module, but not by libzvbi.

## Installation

Pre-requisite to the installation is the [libzvbi library](http://zapping.sourceforge.net/doc/libzvbi/index.html)
(you need a development package which includes the `libzvbi.h` header file)
and a C compiler.  If you have these already, installation is done
in the usual steps:

```console
    perl Makefile.PL
    make
    make install
```

## Copyright

Copyright (C) 2006-2007 Th. "Tom" Zoerner. All rights reserved.

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 2 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.
