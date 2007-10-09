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
# $Id$
#

package Video::Capture::ZVBI;

=head1 NAME

Video::Capture::ZVBI - VBI library

=head1 SYNOPSIS

   use Video::Capture::ZVBI;

=cut

use strict;
use warnings;

require Exporter;
require DynaLoader;

our @ISA = ('Exporter', 'DynaLoader');
our $VERSION = 0.2;
our @EXPORT = qw(
);
our @EXPORT_OK = qw();

bootstrap Video::Capture::ZVBI $VERSION;

1;

__END__

=head1 Video::Capture::ZVBI::capture

The following functions create and return capture contexts with the
given parameters.  Upon success, the returned context can be passed
to the read, pull and other control functions. The context is automatically
deleted and the device closed when the object is destroyed. The meaning
of the parameters to these function is identical to the ZVBI C library.

Upon failure, these functions return I<undef> and an explanatory text
in B<errorstr>.

=over 4

=item v4l2_new
(dev, buffers, services, strict, errorstr, trace)

Initializes a device using the Video4Linux API version 2.

=item v4l_new
(dev, scanning, services, strict, errorstr, trace)

Initializes a device using the Video4Linux API version 1. Should only
be used after trying Video4Linux API version 2.

=item v4l_sidecar_new
(dev, given_fd, services, strict, errorstr, trace)

Same as B<v4l_new> however working on an already open device.
Parameter B<given_fd> must be the numerical file handle, i.e. as
returned by B<fileno>.

=item bktr_new
(dev, scanning, services, strict, errorstr, trace)

Initializes a video device using the BSD driver.

=item dvb_new
(dev, scanning, services, strict, errorstr, trace)

Initializes a DVB video device.

=item dvb_new2
(dev, pid, errorstr, trace)

Initializes a DVB video device.

=item proxy_new
(vpc, buffers, scanning, services, strict, errorstr)

Creates a capture context based on a previously established connection
to a VBI proxy server. It's good practice to always try first if a
proxy connection can be established before opening the device directly.

=back

The following functions are used to read raw and sliced VBI data. They
all receive a previously opened capture context as first parameter. If
you use object-style invocation you must leave this one out, as it's
automatically added by Perl.

There are two different types of capture functions: The functions
named C<read...> copy captured data into the given Perl scalar. In
contrast the functions named C<pull...> leave the data in internal
buffers inside the capture context and just return a blessed reference
to this buffer. When you need to access the captured data via Perl,
choose the read functions. When you use functions of this module for
further decoding, you should use the pull functions since these are
usually more efficient.

=over 4

=item $cap->read_raw(raw_buf, timestamp, msecs)

=item $cap->read_sliced(sliced_buf, lines, timestamp, msecs)

=item $cap->read(raw_buf, sliced_buf, lines, timestamp, msecs)

=item $cap->pull_raw(buf, timestamp, msecs)

=item $cap->pull_sliced(buf, lines, timestamp, msecs)

=item $cap->pull(raw_buf, sliced_buf, sliced_lines, timestamp, msecs)

=back

All these functions return 1 upon success. They return 0 if there was
a timeout, i.e. if the device didn't deliver any data within B<msecs>
milliseconds. They return -1 upon errors.

For reasons of efficiency the data is not immediately converted into
Perl structures. Functions of the "read" variety return a single
binary string in the given scalar which contains all VBI lines.
Functions of the "pull" variety just return a binary reference
(i.e. a C pointer) which cannot be used by Perl for other purposes
than passing it to further processing functions.  To process either
read or pulled data by Perl code, use the following function:

=over 4

=item $cap->copy_sliced_line(buffer, idx)

The function takes a buffer which was filled by one of the slicer
or capture & slice functions and an index. The index must be lower
than the line count returned by the slicer.  The function returns
a list of three elements: sliced data from the respective line in
the buffer, slicer type (C<VBI_SLICED_...>) and physical line number. 

The structure of the data returned in the first element depends on
the kind of data in the VBI line (e.g. for teletext it's 42 bytes,
partly hamming 8/4 and parity encoded; the content in the scalar
after the 42 bytes is undefined.)

=back

The following control functions work as described in the libzvbi
documentation.

=over 4

=item $cap->parameters()

Returns a hash reference describing the physical parameters of the
VBI source.  This hash can be used to initialize the raw decoder
context described below.  (You should not modify the parameters,
use B<update_services> instead.)

=item $cap->fd()

=item $cap->update_services(reset, commit, services, strict, errorstr)

=item $cap->get_scanning()

=item $cap->flush()

=item $cap->set_video_path(dev_video)

=item $cap->get_fd_flags()

=item $cap->vbi_capture_dvb_filter(pid)

=item $cap->vbi_capture_dvb_last_pts()

=back

=head1 Video::Capture::ZVBI::proxy

=over 4

=item create(dev_name, client_name, flags, errorstr, trace)

Returns a new proxy context, or undef. Note this call will always
succeed, since a connection to the proxy daemon isn't established
until you try to open a capture context.

=item $proxy->get_capture_if()

This function is currently not supported.

=item $proxy->set_callback(callback)

Installs a callback function for asynchronous messages (e.g. channel
change notifications.)  The callback function is typically invoked
while processing a read from the capture device. The function will
receive the event mask as only argument.  Call without an argument
to remove the callback again.

=item $proxy->get_driver_api()

Returns an identifier describing which API is used on server side.
This information is required to pass channel change requests.

=item $proxy->channel_request(chn_prio [,profile])

=item $proxy->channel_notify(notify_flags, scanning)

=item $proxy->channel_suspend(cmd)

=item $proxy->device_ioctl(request, arg)

=item $proxy->get_channel_desc()

=item $proxy->has_channel_control()

=back

=head1 Video::Capture::ZVBI::rawdec

=over 4

=item $rd = Video::Capture::ZVBI::rawdec::new(par)

Creates and initializes a new raw decoder context. Takes a capture
context or a hash reference  (the latter must contain physical parameters
as returned by ZVBI::capture->parameters())

=item $sup = parameters(par, services, scanning, max_rate)

=item $rd->reset()

=item $rd->add_services(services, strict)

=item $rd->check_services(services, strict)

=item $rd->remove_services(services)

=item $rd->resize(start_a, count_a, start_b, count_b)

=item $rd->decode(sv_raw, sv_sliced)

=back

=head1 Video::Capture::ZVBI::vt

=over 4

=item decoder_new()

Creates a new teletext decoder object.

=item vt->decode(sliced_data, lines, timestamp)

Passes a buffer with one field's sliced data to the decoder. The buffer
is of the same type as returned by the capture functions or the raw
decoder.

=item vt->channel_switched(nuid)

=item vt->classify_page(pgno)

=item vt->set_brightness(brightness)

=item vt->set_contrast(contrast)

=item vt->teletext_set_default_region(default_region)

=item vt->teletext_set_level(level)

=item vt->fetch_vt_page(pgno, subno, max_level, display_rows, navigation)

Renders and returns a teletext page as a binary object. The object can
then be passed to an export function or the unpack function if you want
to process the data at Perl level.

The returned reference must be destroyed to release resources which are
locked internally in the library during the fetch.  The destruction is
done automatically when a local variable falls out of scope, or it can
be forced by use of the B<undef> operator.  Note there's no Perl equivalent
to the C library function I<vbi_unref_page> since it's not needed.

=item vt->fetch_cc_page(pgno, reset=0)

Renders and returns a closed caption page as a binary object.

=item vt->is_cached(pgno, subno)

=item vt->cache_hi_subno(pgno)

=item vt->page_title(pgno, subno)

=item rating_string(auth, id)

=item prog_type_string(classf, id)

=back

=head1 Video::Capture::ZVBI::export

=over 4

=item new(keyword, errstr)

Creates and initializes a new export context.

=item $exp->info_enum(index)

=item $exp->info_keyword(keyword)

=item $exp->info_export(exp)

=item $exp->stdio(exp, fp, pg)

=item $exp->file(exp, name, pg)

=item $exp->errstr(exp)

=back

=head1 Miscellaneous (Video::Capture::ZVBI)

=over 4

=item lib_version()

Returns the version of the ZVBI library.

=item par(val)

This function encodes the given value with Parity.

=item unpar(val)

This function decodes the given Parity encoded 8-bit value. The result
is a 7-bit value in the range 0...127 or a negative value when a
parity error is detected.  (Note: to decode parity while ignoring
errors, simply mask out the highest bit, i.e. $val &= 0x7F)

=item par_str(data)

This function encodes a string with parity in place, i.e. the given
string contains the result after the call.

=item unpar_str(data)

This function decodes a Parity encoded string in place, i.e. the
parity bit is removed from all characters in the given string.
The result is negative when a decoding error is detected, else
the result is positive or zero.

=item rev8(val)

This function reverses the order of all bits of the given 8-bit value
and returns the result. This conversion is required for decoding certain
teletext elements which are transmitted MSB first instead of the usual
LSB first (the teletext VBI slicer already inverts the bit order so that
LSB are in bit #0)

=item rev16(val)

This function reverses the order of all bits of the given 16-bit value
and returns the result.

=item rev16p(data, offset=0)

This function reverses 2 bytes from the string representation of the
given scalar at the given offset and returns them as a numerical value.

=item ham8(val)

This function encodes the given 4-bit value (i.e. range 0..15) with
Hamming-8/4.  The result is an 8-bit value in the range 0..255.

=item unham8(val)

This function decodes the given Hamming-8/4 encoded value. The result
is a 4-bit value, or -1 when there are uncorrectable errors.

=item unham16p(data, offset=0)

This function decodes 2 Hamming-8/4 encoded bytes (taken from the string
in parameter "data" at the given offset) The result is an 8-bit value,
or -1 when there are uncorrectable errors.

=item unham24p(data, offset=0)

This function decodes 3 Hamming-24/18 encoded bytes (taken from the string
in parameter "data" at the given offset) The result is an 8-bit value,
or -1 when there are uncorrectable errors.

=item vbi_decode_vps_cni(data)

This function receives a sliced VPS line and returns a 16-bit CNI value,
or undef in case of errors.

=item vbi_encode_vps_cni(cni)

This function receives a 16-bit CNI value and returns a VPS line,
or undef in case of errors.

=back

