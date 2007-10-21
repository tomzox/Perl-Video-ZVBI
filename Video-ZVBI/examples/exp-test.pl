#!/usr/bin/perl -w
#
#  Example and test of export module options interface
#
#  Copyright (C) 2007 Tom Zoerner
#
#  This program is free software; you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation; either version 2 of the License, or
#  (at your option) any later version.
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with this program; if not, write to the Free Software
#  Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.
#

# $Id$

use blib;
use Video::Capture::ZVBI;
use POSIX;
use IO::Handle;
use strict;


sub main_func {
   my @Exp = ();
   my $h;
   my $idx = 0;
   while ( defined($h = Video::Capture::ZVBI::export::info_enum($idx)) ) {
      print "$idx $h->{keyword}: $h->{tooltip}\n";
      push @Exp, $h->{keyword};
      $idx++;
   }
   while (1) {
      print "Enter a module number:\n";
      $idx = <>;
      chomp $idx;
      if ($idx !~ /^\d+/) {
         print "This is not a number\n";
      } elsif ($idx > $#Exp) {
         print "The module number must be in range 0 ..$#Exp\n";
      } else {
         last;
      }
   }

   my $errmsg;
   my $exp = Video::Capture::ZVBI::export::new($Exp[$idx], $errmsg);
   die "Failed to open export module '$Exp[$idx]': $errmsg\n" unless defined $exp;

   my @Opt = ();
   $idx = 0;
   while ( defined($h = $exp->option_info_enum($idx)) ) {
      print "$idx $h->{keyword}: type=$h->{type}, def=$h->{def}\n";
      push @Opt, $h->{keyword};
      $idx++;
   }
   while (1) {
      print "Enter an option number: (empty to skip)\n";
      $idx = <>;
      chomp $idx;
      if ($idx eq "") {
         last
      } elsif ($idx !~ /^\d+/) {
         print "This is not a number\n";
         redo;
      } elsif ($idx > $#Opt) {
         print "The module number must be in range 0 ..$#Opt\n";
         redo;
      }
      print "Enter an option value:\n";
      my $val = <>;
      chomp $val;
      if ($exp->option_set($Opt[$idx], $val)) {
         my $opt = $exp->option_get($Opt[$idx]);
         die "failed to query option \"$Opt[$idx]\"\n" unless defined $opt;
         print "OK - reading back: $opt\n";
      } else {
         warn "Failed to set option\n";
      }
   }
}

main_func();


