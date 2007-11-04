#!/usr/bin/perl -w
#
#  Small teletext browser
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
use Video::Capture::ZVBI qw(/^VBI_/);
use Tk;

my $cap;
my $vtdec;
my $redraw;
my $tid;
my $dec_entry = 100;
my $pg_disp = -1;
my $pg_sched = 0x100;
my $pg_lab = "";

my $main;
my $canvas;
my $img;

#
# This callback is invoked by the teletext decoder for every new page.
# The function updates the page number display on top of the window and
# updates the display if the scheduled page has been captured.
#
sub pg_handler {
   my($type, $ev, $user_data) = @_;

   $pg_lab = sprintf "Page %03x.%02x ", $ev->{pgno}, $ev->{subno} & 0xFF;

   if ($ev->{pgno} == $pg_sched) {
      $redraw = 1;
   }
}

#
# This function is called every 10ms to capture VBI data.
# VBI frames are sliced and forwarded to the teletext decoder.
#
sub cap_frame {
   my $sliced;
   my $timestamp;
   my $n_lines;
   my $res;

   $res = $cap->pull_sliced($sliced, $n_lines, $timestamp, 50);
   die "Capture error: $!\n" if $res < 0;

   if ($res > 0) {
      $vtdec->decode($sliced, $n_lines, $timestamp);
   }

   if ($redraw) {
      pg_display();
      $redraw = 0;
   }

   $tid = $main->after(10, \&cap_frame);
}

#
# This function is called once during start-up to initialize the
# capture context and the teletext decoder
#
sub cap_init {
   my $opt_device = "/dev/vbi0";
   my $opt_buf_count = 5;
   my $opt_services = VBI_SLICED_TELETEXT_B;
   my $opt_strict = 0;
   my $opt_debug_level = 0;
   my $err;

   $cap = Video::Capture::ZVBI::capture::v4l2_new($opt_device, $opt_buf_count, $opt_services, $opt_strict, $err, $opt_debug_level);
   if (!defined $cap) {
      $cap = Video::Capture::ZVBI::capture::v4l_new($opt_device, 0, $opt_services, $opt_strict, $err, $opt_debug_level);
   }
   die "Failed to open video device: $err\n" unless $cap;

   $vtdec = Video::Capture::ZVBI::vt::decoder_new();
   die "failed to create teletext decoder: $!\n" unless defined $vtdec;

   $vtdec->event_handler_add(VBI_EVENT_TTX_PAGE, \&pg_handler); 
}

#
# This function is onvoked out of the capture event handler when the page
# which is scheduled for display has been captured.
#
sub pg_display {
   my $pg = $vtdec->fetch_vt_page($pg_sched, 0, VBI_WST_LEVEL_3p5, 25, 1);
   if (defined $pg) {
      my ($h, $w) = $pg->get_page_size();
      my $fmt;
      if (Video::Capture::ZVBI::check_lib_version(0,2,26)) {
         $fmt = VBI_PIXFMT_PAL8;
      } else {
         $fmt = VBI_PIXFMT_RGBA32_LE;
      }
      my $img_canvas = $pg->draw_vt_page($fmt);
      $pg_disp = $pg_sched;

      $canvas->delete("all");
      undef $img;
      $img = $main->Pixmap(-data, $pg->canvas_to_xpm($img_canvas, $fmt, 1));

      my $cid = $canvas->createImage(2,2, -anchor, "nw", -image, $img);
      $canvas->configure(-width, $img->width(), -height, $img->height());
      $canvas->bind($cid, '<Key-q>', sub {exit;});
      $canvas->bind($cid, '<Button-1>', [\&pg_link, Ev('x'), Ev('y')]);
   }
}

#
# This callback is invoked when the user clicks into the teletext page.
# If there's a page number of FLOF link under the mouse pointer, the
# respective page is scheduled for display.
#
sub pg_link {
   my ($wid, $x, $y) = @_;

   my $pg = $vtdec->fetch_vt_page($pg_disp, 0, VBI_WST_LEVEL_1p5, 25, 1);
   if (defined $pg) {
      # note: char width 12, char height 10*2 due to scaling in XPM conversion
      my $h = $pg->resolve_link($x / 12, $y / 20);
      if ($h->{type} == VBI_LINK_PAGE) {
         $pg_sched = $h->{pgno};
         $dec_entry = sprintf "%03X", $pg_sched;
         $redraw = 1;
      }
   }
}

#
# This callback is invoked when the user hits the left/right buttons
# (actually this is redundant to the +/- buttons in the spinbox)
#
sub pg_plus_minus {
   my ($off) = @_;

   if ($off >= 0) {
      $off = 1;
   } else {
      $off = 0xF9999999;
   }
   $pg_sched = Video::Capture::ZVBI::add_bcd($pg_sched, $off);
   $dec_entry = sprintf "%03X", $pg_sched;
   $redraw = 1;
}

#
# This callback is invoked when the user edits the page number
#
sub pg_change {
   $pg_sched = Video::Capture::ZVBI::dec2bcd($dec_entry);
   $redraw = 1;
}

#
# This function is called once during start-up to create the GUI.
#
sub gui_init {
   $main = MainWindow->new();

   my $wid_f1 = $main->Frame();
   my $wid_f1_sp = $wid_f1->Spinbox(-from, 100, -to, 899, -width, 5,
                                    -textvariable, \$dec_entry,
                                    -command, \&pg_change);
   $wid_f1_sp->bind('<Return>', \&pg_change);
   $wid_f1_sp->pack(-side, "left", -anchor, "w");
   my $wid_f1_lab = $wid_f1->Label(-textvariable, \$pg_lab);
   $wid_f1_lab->pack(-side, "left",);
   $wid_f1->pack(-side, "top", -fill, "x");
   my $wid_f1_but1 = $wid_f1->Button(-text, "<<", -command, [\&pg_plus_minus, -1]);
   my $wid_f1_but2 = $wid_f1->Button(-text, ">>", -command, [\&pg_plus_minus, 1]);
   $wid_f1_but1->pack(-side, "left", -anchor, "e");
   $wid_f1_but2->pack(-side, "left", -anchor, "e");

   $canvas = $main->Canvas(-borderwidth, 1, -relief, "sunken");

   $canvas->pack();
   $canvas->focus();
}

# start capturing teletext
cap_init();

# create & display GUI
gui_init();

# install 10ms timer for capturing in the background
$tid = $main->after(10, \&cap_frame);
$redraw = 0;

# everything from here on is event driven
MainLoop;

