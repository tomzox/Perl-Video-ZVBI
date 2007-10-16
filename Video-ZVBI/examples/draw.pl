#!/usr/bin/perl -w
#
#  libzvbi test of teletext display
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

use strict;
use blib;
use Video::Capture::ZVBI;
use Tk;

my $cap;
my $vtdec;
my $cr;
my $found;
my $tid;

my $main;
my $canvas;
my $img;

sub pg_handler {
   my($type, $ev, $user_data) = @_;

   printf STDERR "${cr}Page %03x.%02x ",
           $ev->{pgno},
           $ev->{subno} & 0xFF;

   if ($ev->{pgno} == 0x100) {
      $found = 1;
   }
}

sub cap_init {
   my $opt_device = "/dev/vbi0";
   my $opt_buf_count = 5;
   my $opt_services = Video::Capture::ZVBI::VBI_SLICED_TELETEXT_B;
   my $opt_strict = 0;
   my $opt_debug_level = 0;
   my $err;

   $cap = Video::Capture::ZVBI::capture::v4l2_new($opt_device, $opt_buf_count, $opt_services, $opt_strict, $err, $opt_debug_level);
   if (!defined $cap) {
      $cap = Video::Capture::ZVBI::capture::v4l_new($opt_device, 0, $opt_services, $opt_strict, $err, $opt_debug_level);
   }
   die "Failed to open video device: $err\n" unless $cap;

   $cr = (-t STDERR) ? "\r" : "\n";

   $vtdec = Video::Capture::ZVBI::vt::decoder_new();
   die "failed to create teletext decoder: $!\n" unless defined $vtdec;

   $vtdec->event_handler_add(Video::Capture::ZVBI::VBI_EVENT_TTX_PAGE, \&pg_handler); 
}

sub cap_frame {
   my $sliced;
   my $timestamp;
   my $n_lines;
   my $res;

   $res = $cap->pull_sliced($sliced, $n_lines, $timestamp, 1000);
   die "Capture error: $!\n" if $res < 0;

   $vtdec->decode($sliced, $n_lines, $timestamp);

   if ($found) {
      pg_display();
      $found = 0;
   }

   $tid = $main->after(10, \&cap_frame);
}

sub pg_display {
   my $pg = $vtdec->fetch_vt_page(0x100, 0, Video::Capture::ZVBI::VBI_WST_LEVEL_3p5, 25, 1);
   if (defined $pg) {
      my ($h, $w) = $pg->get_page_size();
      my $img_canvas;
      $pg->draw_vt_page(Video::Capture::ZVBI::VBI_PIXFMT_RGBA32_LE, $img_canvas, 0, 0);

      $canvas->delete("all");
      undef $img;
      $img = $main->Pixmap(-data, Video::Capture::ZVBI::page::rgba_to_xpm($img_canvas, -1, $w, $h));
      $canvas->createImage(2,2, -anchor, "nw", -image, $img);
      $canvas->configure(-width, $img->width(), -height, $img->height());
   }
}

cap_init();

$main = MainWindow->new();

$canvas = $main->Canvas(-borderwidth, 1, -relief, "sunken");

$canvas->pack();
$canvas->bind('<q>', sub {exit;});
$canvas->focus();

$tid = $main->after(10, \&cap_frame);
$found = 0;

MainLoop;


