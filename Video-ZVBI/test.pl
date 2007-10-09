#!/usr/bin/perl -w
#
# Copyright (C) 2006 Tom Zoerner. All rights reserved.
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
# $Id$
#

use blib;
use Video::Capture::ZVBI;

my $err;
my $cap;
my $srv = Video::Capture::ZVBI::VBI_SLICED_TELETEXT_B;

my $proxy = Video::Capture::ZVBI::proxy::create("/dev/vbi0", "test.pl", 0, $err, 1);
if ($proxy) {
   $cap = Video::Capture::ZVBI::capture::proxy_new($proxy, 6, 0, $srv, 0, $err);
   if ($cap) {
      #$proxy->channel_request(1, {"sub_prio" => 1, "allow_suspend" => 1});
   } else {
      undef $proxy;
   }
}
if (!$cap) {
   $cap = Video::Capture::ZVBI::capture::v4l2_new("/dev/vbi0", 6, $srv, 0, $err, 1);
}

#$rd = $cap->parameters();
#undef $rd;
#$rd1 = Video::Capture::ZVBI::rawdec::init();
#print $rd1."\n";
#undef $rd1;
#exit(0);

if ($cap) {
   my $vbi_fd = $cap->fd();
   while (1)
   {
      my $r = "";
      vec($r, $vbi_fd, 1) = 1;
      select $r, undef, undef, 1;

      my $buf;
      my $timestamp;
      my $n_lines;
      my $res = $cap->pull_sliced($buf, $n_lines, $timestamp, 1000);
      if ($res > 0) {
         for (my $idx = 0; $idx < $n_lines; $idx++) {
            my @a = $cap->copy_sliced_line($buf, $idx);
            if ($a[1] & Video::Capture::ZVBI::VBI_SLICED_TELETEXT_B) {
               my $mpag = Video::Capture::ZVBI::unham16p($a[0]);
               my $mag = $mpag & 7;
               my $pack = ($mpag & 0xf8) >> 3;
               if ($pack == 0) {
                  my $page = ($mag << 8) | Video::Capture::ZVBI::unham16p($a[0], 2);
                  printf("PAGE %03X\n", $page);
               } elsif($pack <= 23) {
                  $a[0] = substr($a[0], 2, 40);
                  Video::Capture::ZVBI::unpar_str($a[0]);
                  $a[0] =~ s#[\x00-\x1F]# #g;
                  print "$a[0]\n";
               }
            }
         }
      } elsif ($res == 0) {
         die "pull_sliced: timeout\n";
      } else {
         die "pull_sliced: $!\n";
      }
   }
} else {
   die "failed to open device: $err\n";
}
Video::Capture::ZVBI::capture::delete($cap);

