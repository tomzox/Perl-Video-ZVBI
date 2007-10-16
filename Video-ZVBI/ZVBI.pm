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

=item $cap = v4l2_new($dev, $buffers, $services, $strict, $errorstr, $trace)

Initializes a device using the Video4Linux API version 2.  The function
returns a blessed reference to a capture context, or C<undef> upon error.

Parameters: I<$dev> is the path of the device to open, usually one of
C</dev/vbi0> or up. I<$buffers> is the number of device buffers for
raw vbi data if the driver supports streaming. Otherwise one bounce
buffer is allocated for I<$cap->pull()>  I<$services> is a logical OR
of C<VBI_SLICED_*> symbols describing the data services to be decoded.
On return the services actually decodable will be stored here.
See I<ZVBI::raw_dec::add_services> for details.  If you want to capture
raw data only, set to C<VBI_SLICED_VBI_525>, C<VBI_SLICED_VBI_625> or
both.  If this parameter is C<undef>, no services will be installed.
You can do so later with I<$cap->update_services()> (Note the I<reset>
parameter to that function must be logically true in this case.)
I<$strict> Will be passed to I<ZVBI::raw_dec::add_services>.
I<$errorstr> is used to return an error descriptions.  I<$trace> can be
used to enable output of progress messages on I<stderr>.

=item $cap = v4l_new($dev, $scanning, $services, $strict, $errorstr, $trace)

Initializes a device using the Video4Linux API version 1. Should only
be used after trying Video4Linux API version 2.  The function returns
a blessed reference to a capture context, or C<undef> upon error.

Parameters: I<$dev> is the path of the device to open, usually one of
C</dev/vbi0> or up. I<$scanning> can be used to specify the current
TV norm for old drivers which don't support ioctls to query the current
norm.  Allowed values are: 625 for PAL/SECAM family; 525 for NTSC family;
0 if unknown or if you don't care about obsolete drivers. I<$services>,
I<$strict>, I<$errorstr>, I<$trace>: see function I<v4l2_new()> above.

=item $cap = v4l_sidecar_new($dev, $given_fd, $services, $strict, $errorstr, $trace)

Same as B<v4l_new> however working on an already open device.
Parameter B<given_fd> must be the numerical file handle, i.e. as
returned by B<fileno>.

=item $cap = bktr_new($dev, $scanning, $services, $strict, $errorstr, $trace)

Initializes a video device using the BSD driver.
Result and parameters are identical to function I<v4l2_new()>

=item $cap = dvb_new($dev, $scanning, $services, $strict, $errorstr, $trace)

Initializes a DVB video device.  This function is deprecated as it has many
bugs (see libzvbi documentation for details). Use dvb_new2() instead.

=item dvb_new2($dev, $pid, $errorstr, $trace)

Initializes a DVB video device.  The function returns a blessed reference
to a capture context, or C<undef> upon error.

Parameters: I<$dev> is the path of the DVB device to open.
I<$pid> specifies the number (PID) of a stream which contains the data.
You can pass 0 here and set or change the PID later with I<$cap->dvb_filter()>.
I<$errorstr> is used to return an error descriptions.  I<$trace> can be
used to enable output of progress messages on I<stderr>.

=item $cap = $proxy->proxy_new($buffers, $scanning, $services, $strict, $errorstr)

Open a new connection to a VBI proxy to open a VBI device for the
given services.  On side of the proxy one of the regular v4l_new() etc.
functions is invoked and if it succeeds, data slicing is started
and all captured data forwarded transparently.

Whenever possible the proxy should be used instead of opening the device
directly, since it allows the user to start multiple VBI clients in
parallel.  When this function fails (usually because the user hasn't
started the proxy daemon) applications should automatically fall back
to opening the device directly.

Result: The function returns a blessed reference to a capture context,
or C<undef> upon error.

Parameters: I<$proxy> is a reference to a previously created proxy client
context.  I<$buffers> is the number of device buffers for raw vbi data.
The same number of buffers is allocated to cache sliced data in the
proxy daemon.  I<$scanning> indicates the current norm: 625 for PAL and
525 for NTSC; set to 0 if you don't know (you should not attempt
to query the device for the norm, as this parameter is only required
for old v4l1 drivers which don't support video standard query ioctls.)
I<$services> is a set of C<VBI_SLICED_*> symbols describing the data
services to be decoded. On return I<$services> contains actually
decodable services.  See I<ZVBI::raw_dec::add_services> for details.
If you want to capture raw data only, set to C<VBI_SLICED_VBI_525>,
C<VBI_SLICED_VBI_625> or both.  I<$strict> has the same meaning as
described in the device-soecific capture context creation functions.
I<$errorstr> is used to return an error descriptions.

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

=item $cap->update_services($reset, $commit, $services, $strict, $errorstr)

Adds and/or removes one or more services to an already initialized capture
context.  Can be used to dynamically change the set of active services.
Internally the function will restart parameter negotiation with the
VBI device driver and then call I<ZVBI::raw_dec::add_services>
You may set I<$reset> to rebuild your service mask from scratch.  Note
that the number of VBI lines may change with this call (even if a negative
result is returned) so the size of output buffers may change.

Result: Bitmask of supported services among those requested (not including
previously added services), 0 upon errors.

I<$reset> when set, clears all previous services before adding new
ones (by invoking $raw_dec->reset() at the appropriate time.)
I<$commit> when set, applies all previously added services to the device;
when doing subsequent calls of this function, commit should be set only
for the last call.  Reading data cannot continue before changes were
commited (because capturing has to be suspended to allow resizing the
VBI image.)  Note this flag is ignored when using the VBI proxy.
I<$services> contains a set of C<VBI_SLICED_*> symbols describing the
data services to be decoded. On return the services actually decodable
will be stored here, i.e. the behaviour is identical to v4l2_new() etc.
I<$strict> and I<$errorstr> are also same as during capture context
creation.

=item $cap->fd()

This function returns the file descriptor used to read from the
capture context's device. If not applicable (e.g. when using the proxy)
or the capture context is invalid -1 will be returned.

=item $cap->get_scanning()

This function is intended to allow the application to check for
asynchronous norm changes, i.e. by a different application using the
same device.  The function queries the capture device for the current
norm and returns value 625 for PAL/SECAM norms, 525 for NTSC;
0 if unknown, -1 on error.

=item $cap->flush()

After a channel change this function should be used to discard all
VBI data in intermediate buffers which may still originate from the
previous TV channel.

=item $cap->set_video_path($dev)

The function sets the path to the video device for TV norm queries.
Parameter $<dev> must refer to the same hardware as the VBI device
which is used for capturing (e.g. C</dev/video0> when capturing from
C</dev/vbi0>) Note: only useful for old video4linux drivers which don't
support norm queries through VBI devices.

=item $cap->get_fd_flags()

Returns properties of the capture context's device. The result is an OR
of one or more C<VBI_FD_*> flags.

=item $cap->vbi_capture_dvb_filter($pid)

Programs the DVB device transport stream demultiplexer to filter
out PES packets with the given I<$pid>.  Returns -1 on failure,
0 on success.

=item $cap->vbi_capture_dvb_last_pts()

Returns the presentation time stamp (33 bits) associated with the data
last read from the context. The PTS refers to the first sliced
VBI line, not the last packet containing data of that frame.

Note timestamps returned by VBI capture read functions contain
the sampling time of the data, that is the time at which the
packet containing the first sliced line arrived.

=back

=head1 Video::Capture::ZVBI::proxy

=over 4

=item $proxy = create($dev, $client_name, $flags, $errorstr, $trace)

Creates and returns a new proxy context, or C<undef> upon error.
(Note in reality this call will always succeed, since a connection to
the proxy daemon isn't established until you actually open a capture
context via I<$proxy->proxy_new()>)

Parameters: I<$dev> contains the name of the device to open, usually one of
C</dev/vbi0> and up.  Note: should be the same path as used by the proxy
daemon, else the client may not be able to connect.  I<$client_name>
names the client application, typically identical to I<$0> (without the
path though)  Can be used by the proxy daemon to fine-tune scheduling or
to present the user with a list of currently connected applications.
I<$flags> can contain one or more members of C<VBI_PROXY_CLIENT_*> flags.
I<$errorstr> is used to return an error descriptions.  I<$trace> can be
used to enable output of progress messages on I<stderr>.

=item $proxy->get_capture_if()

This function is not supported.  (In libzvbi it returns a reference to
a capture context created from the proxy context via I<$proxy->proxy_new()>)

=item $proxy->set_callback(\&callback, $data)

Installs or removes a callback function for asynchronous messages (e.g.
channel change notifications.)  The callback function is typically invoked
while processing a read from the capture device. The function will
receive the event mask (i.e. one of symbols C<VBI_PROXY_EV_*>) as only
argument.  Call without an argument to remove the callback again.
Optional argument I<$data> is currently ignored (in libzvbi it is
passed through to the callback.)

=item $proxy->get_driver_api()

Returns an identifier describing which API is used on server side,
i.e. one of the symbols C<VBI_API_*>.  This information is required to
pass channel change requests to the proxy daemon.

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

