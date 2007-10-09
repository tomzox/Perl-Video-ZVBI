#!/usr/bin/perl -w
#
#  libzvbi test
#
#  Copyright (C) 2000, 2001 Michael H. Schimek
#  Perl Port: Copyright (C) 2006 Tom Zoerner
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

# Perl $Id$
# ZVBI #Id: export.c,v 1.13 2005/10/04 10:06:11 mschimek Exp #

use blib;
use Video::Capture::ZVBI;
use POSIX;
use IO::Handle;
use strict;

my $vbi;
my $quit = 0;
my $pgno;
my $ex;
my $extension;
my $cr;
#my $dx;


sub handler {
        my($type, $ev, $user_data) = @_;

        my $page;

        printf STDERR "${cr}Page %03x.%02x ",
                $ev->{pgno},
                $ev->{subno} & 0xFF;

        if ($pgno != -1 && $ev->{pgno} != $pgno) {
                return;
        }

        print STDERR "\nSaving... ";
        if (-t STDERR) {
                print STDERR "\n";
        }
        #IO::Handle::flush(fileno(STDERR));

        # Fetching & exporting here is a bad idea,
        # but this is only a test.
        $page = $vbi->fetch_vt_page($ev->{pgno}, $ev->{subno},
                                    Video::Capture::ZVBI::VBI_WST_LEVEL_3p5, 25, 1) || die;

        my $io = new IO::Handle;
        # Just for fun
        if ($pgno == -1) {
                my $name = sprintf("test-%03x-%02x.%s",
                                   $ev->{pgno},
                                   $ev->{subno},
                                   $extension);

                $io->open($name, "w") || die "create $name: $!\n";
        } else {
                $io->fdopen(fileno(STDOUT), "w")
        }

        if (!$ex->stdio($io, $page)) {
                print STDERR "failed: ". $ex->errstr() ."\n";
                exit(-1);
        } else {
                print STDERR "done\n";
        }

        undef $page;

        if ($pgno != -1) {
                $quit = 1;
        }
}

#sub pes_mainloop
#{
#        my $buffer;
#
#        while (sysread (STDIN, $buffer, 2048) > 0) {
#                const uint8_t *bp;
#                unsigned int left;
#
#                bp = buffer;
#                left = sizeof (buffer);
#
#                while (left > 0) {
#                        vbi_sliced sliced[64];
#                        unsigned int lines;
#                        int64_t pts;
#
#                        $lines = vbi_dvb_demux_cor (dx, sliced, 64,
#                                                    &pts, &bp, &left);
#                        if ($lines > 0) {
#                                $vbi->decode (sliced, lines, pts / 90000.0);
#                        }
#
#                        return if $quit;
#                }
#        }
#
#        printf STDERR "\rEnd of stream, page %03x not found\n", $pgno;
#}

sub old_mainloop
{
        my $opt_device = "/dev/vbi0";
        my $opt_buf_count = 5;
        my $opt_services = Video::Capture::ZVBI::VBI_SLICED_TELETEXT_B;
        my $opt_strict = 0;
        my $opt_debug_level = 0;

        my $err;
        my $cap = Video::Capture::ZVBI::capture::v4l2_new($opt_device, $opt_buf_count, $opt_services, $opt_strict, $err, $opt_debug_level) || die "V4l open: $!\n";

        while (!$quit) {
                my $sliced;
                my $timestamp;
                my $n_lines;

                #my $res = $cap->read_sliced($sliced, $n_lines, $timestamp, 1000);
                my $res = $cap->pull_sliced($sliced, $n_lines, $timestamp, 1000);
                die if $res < 0;

                $vbi->decode($sliced, $n_lines, $timestamp);
        }

        printf STDERR "\rEnd of stream, page %03x not found\n", $pgno;
}

sub main_func
{
        my $module;
        my $t;

        if ($#ARGV < 1) {
                print STDERR "Usage: $0 module[;options] pgno <vbi_data >file\n".
                                "module eg. \"text\" or \"ppm\", pgno eg. 100 (hex)\n";
                exit(-1);
        }

        #if (-t) {
        #        print STDERR "No vbi data on stdin\n";
        #        exit(-1);
        #}

        $cr = (-t STDERR) ? "\r" : "\n";

        $module = $ARGV[0];
        $pgno = hex($ARGV[1]);
        die "Invalid page number: $ARGV[1]\n" if ($pgno < 0x100) || ($pgno > 0x8FF);

        $ex = Video::Capture::ZVBI::export::new($module, $t);
        if (!defined $ex) {
                print STDERR "Failed to open export module '$module': $t\n";
                exit(-1);
        }

        my $xi = $ex->info_export() || die;
        $extension = $xi->{extension};
        $extension =~ s#,.*##;
        undef $xi;

        $vbi = Video::Capture::ZVBI::vt::decoder_new() || die;

        $vbi->event_handler_add(Video::Capture::ZVBI::VBI_EVENT_TTX_PAGE, \&handler); 

        my $c = 1;
        #my $c = getc();
        #IO::Handle::ungetc($c);

        if (0 == $c) {
                #dx = vbi_dvb_pes_demux_new (/* callback */ NULL, NULL) || die;

                #pes_mainloop ();
        } else {
                old_mainloop ();
        }

        exit(-1);
}

main_func();

