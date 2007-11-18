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
# $Id: Makefile.PL,v 1.1 2007/11/18 18:48:51 tom Exp tom $
#

use ExtUtils::MakeMaker;

WriteMakefile(
    'NAME'	   => 'Video::ZVBI',
    'VERSION_FROM' => 'ZVBI.pm',
    'LIBS'         => [ "-lzvbi" ],
);
