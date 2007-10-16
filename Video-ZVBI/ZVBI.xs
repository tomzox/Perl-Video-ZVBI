/*
 * Copyright (C) 2006-2007 Tom Zoerner. All rights reserved.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * $Id$
 */

#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include <unistd.h>
#include <string.h>
#include <sys/types.h>
#include <sys/mman.h>

#include "libzvbi.h"

typedef vbi_proxy_client VbiProxyObj;
typedef vbi_capture VbiCaptureObj;
typedef vbi_capture_buffer VbiRawBuffer;
typedef vbi_capture_buffer VbiSlicedBuffer;
typedef vbi_raw_decoder VbiRawDecObj;
typedef SV * VbiBufVar;

typedef vbi_decoder VbiVtObj;
typedef vbi_export VbiExportObj;
typedef vbi_search VbiSearchObj;

typedef struct vbi_page_obj_struct {
   vbi_page * p_pg;
   vbi_bool   do_free_pg;
} VbiPageObj;

typedef vbi_dvb_demux VbiDvbDemuxObj;

static void * zvbi_xs_search_progress_cb = NULL;


#define hv_store_sv(HVPTR, NAME, SVPTR) hv_store (HVPTR, #NAME, strlen(#NAME), (SV*)(SVPTR), 0)
#define hv_store_pv(HVPTR, NAME, STR)   hv_store_sv (HVPTR, NAME, newSVpv ((STR), 0))
#define hv_store_iv(HVPTR, NAME, VAL)   hv_store_sv (HVPTR, NAME, newSViv (VAL))
#define hv_store_nv(HVPTR, NAME, VAL)   hv_store_sv (HVPTR, NAME, newSVnv (VAL))
#define hv_store_rv(HVPTR, NAME, VAL)   hv_store_sv (HVPTR, NAME, newRV_noinc (VAL))

#define hv_fetch_pv(HVPTR, NAME)        hv_fetch (HVPTR, #NAME, strlen(#NAME), 0)

static void zvbi_xs_dec_params_to_hv( HV * hv, const vbi_raw_decoder * p_par )
{
        hv_clear(hv);

        hv_store_iv(hv, scanning, p_par->scanning);
        hv_store_iv(hv, sampling_format, p_par->sampling_format);
        hv_store_iv(hv, sampling_rate, p_par->sampling_rate);
        hv_store_iv(hv, bytes_per_line, p_par->bytes_per_line);
        hv_store_iv(hv, offset, p_par->offset);
        hv_store_iv(hv, start_a, p_par->start[0]);
        hv_store_iv(hv, start_b, p_par->start[1]);
        hv_store_iv(hv, count_a, p_par->count[0]);
        hv_store_iv(hv, count_b, p_par->count[1]);
        hv_store_iv(hv, interlaced, p_par->interlaced);
        hv_store_iv(hv, synchronous, p_par->synchronous);
}

static void zvbi_xs_hv_to_dec_params( HV * hv, vbi_raw_decoder * p_rd )
{
        SV ** p_sv;

        if (NULL != (p_sv = hv_fetch_pv(hv, scanning))) {
                p_rd->scanning = SvIV(*p_sv);
        }
        if (NULL != (p_sv = hv_fetch_pv(hv, sampling_format))) {
                p_rd->sampling_format = SvIV(*p_sv);
        }
        if (NULL != (p_sv = hv_fetch_pv(hv, sampling_rate))) {
                p_rd->sampling_rate = SvIV(*p_sv);
        }
        if (NULL != (p_sv = hv_fetch_pv(hv, bytes_per_line))) {
                p_rd->bytes_per_line = SvIV(*p_sv);
        }
        if (NULL != (p_sv = hv_fetch_pv(hv, offset))) {
                p_rd->offset = SvIV(*p_sv);
        }
        if (NULL != (p_sv = hv_fetch_pv(hv, start_a))) {
                p_rd->start[0] = SvIV(*p_sv);
        }
        if (NULL != (p_sv = hv_fetch_pv(hv, start_b))) {
                p_rd->start[1] = SvIV(*p_sv);
        }
        if (NULL != (p_sv = hv_fetch_pv(hv, count_a))) {
                p_rd->count[0] = SvIV(*p_sv);
        }
        if (NULL != (p_sv = hv_fetch_pv(hv, count_b))) {
                p_rd->count[1] = SvIV(*p_sv);
        }
        if (NULL != (p_sv = hv_fetch_pv(hv, interlaced))) {
                p_rd->interlaced = SvIV(*p_sv);
        }
        if (NULL != (p_sv = hv_fetch_pv(hv, synchronous))) {
                p_rd->synchronous = SvIV(*p_sv);
        }
}

static void zvbi_xs_page_link_to_hv( HV * hv, vbi_link * p_ld )
{
        hv_store_iv(hv, type, p_ld->type);
        hv_store_iv(hv, eacem, p_ld->eacem);
        if (p_ld->name[0] != 0) {
                hv_store_pv(hv, name, p_ld->name);
        }
        if (p_ld->url[0] != 0) {
                hv_store_pv(hv, url, p_ld->url);
        }
        if (p_ld->script[0] != 0) {
                hv_store_pv(hv, script, p_ld->script);
        }
        hv_store_iv(hv, nuid, p_ld->nuid);
        hv_store_iv(hv, pgno, p_ld->pgno);
        hv_store_iv(hv, subno, p_ld->subno);
        hv_store_nv(hv, expires, p_ld->expires);
        hv_store_iv(hv, itv_type, p_ld->itv_type);
        hv_store_iv(hv, priority, p_ld->priority);
        hv_store_iv(hv, autoload, p_ld->autoload);
}

static void zvbi_xs_aspect_ratio_to_hv( HV * hv, vbi_aspect_ratio * p_asp )
{
        hv_store_iv(hv, first_line, p_asp->first_line);
        hv_store_iv(hv, last_line, p_asp->last_line);
        hv_store_nv(hv, ratio, p_asp->ratio);
        hv_store_iv(hv, film_mode, p_asp->film_mode);
        hv_store_iv(hv, open_subtitles, p_asp->open_subtitles);
}

static void zvbi_xs_prog_info_to_hv( HV * hv, vbi_program_info * p_pi )
{
        hv_store_iv(hv, future, p_pi->future);
        if (p_pi->month != -1) {
                hv_store_iv(hv, month, p_pi->month);
                hv_store_iv(hv, day, p_pi->day);
                hv_store_iv(hv, hour, p_pi->hour);
                hv_store_iv(hv, min, p_pi->min);
        }
        hv_store_iv(hv, tape_delayed, p_pi->tape_delayed);
        if (p_pi->length_hour != -1) {
                hv_store_iv(hv, length_hour, p_pi->length_hour);
                hv_store_iv(hv, length_min, p_pi->length_min);
        }
        if (p_pi->elapsed_hour != -1) {
                hv_store_iv(hv, elapsed_hour, p_pi->elapsed_hour);
                hv_store_iv(hv, elapsed_min, p_pi->elapsed_min);
                hv_store_iv(hv, elapsed_sec, p_pi->elapsed_sec);
        }
        if (p_pi->title[0] != 0) {
                hv_store_pv(hv, title, p_pi->title);
        }
        if (p_pi->type_classf != VBI_PROG_CLASSF_NONE) {
                hv_store_iv(hv, type_classf, p_pi->type_classf);
        }
        if (p_pi->type_classf == VBI_PROG_CLASSF_EIA_608) {
                AV * av = newAV();
                int idx;
                for (idx = 0; (idx < 33) && (p_pi->type_id[idx] != 0); idx++) {
                        av_push(av, newSViv(p_pi->type_id[idx]));
                }
                hv_store_rv(hv, type_classf, (SV*)av);
        }
        if (p_pi->rating_auth != VBI_RATING_AUTH_NONE) {
                hv_store_iv(hv, rating_auth, p_pi->rating_auth);
                hv_store_iv(hv, rating_id, p_pi->rating_id);
        }
        if (p_pi->rating_auth == VBI_RATING_AUTH_TV_US) {
                hv_store_iv(hv, rating_dlsv, p_pi->rating_dlsv);
        }
        if (p_pi->audio[0].mode != VBI_AUDIO_MODE_UNKNOWN) {
                hv_store_iv(hv, mode_a, p_pi->audio[0].mode);
                if (p_pi->audio[0].language != NULL) {
                        hv_store_pv(hv, language_a, p_pi->audio[0].language);
                }
        }
        if (p_pi->audio[1].mode != VBI_AUDIO_MODE_UNKNOWN) {
                hv_store_iv(hv, mode_b, p_pi->audio[1].mode);
                if (p_pi->audio[1].language != NULL) {
                        hv_store_pv(hv, language_b, p_pi->audio[1].language);
                }
        }
        if (p_pi->caption_services != -1) {
                AV * av = newAV();
                int idx;
                hv_store_iv(hv, caption_services, p_pi->caption_services);
                for (idx = 0; idx < 8; idx++) {
                        av_push(av, newSVpv(p_pi->caption_language[idx], 0));
                }
                hv_store_rv(hv, caption_language, (SV*)av);
        }
        if (p_pi->cgms_a != -1) {
                hv_store_iv(hv, cgms_a, p_pi->cgms_a);
        }
        if (p_pi->aspect.first_line != -1) {
                HV * hv = newHV();
                zvbi_xs_aspect_ratio_to_hv(hv, &p_pi->aspect);
                hv_store_rv(hv, aspect, (SV*)hv);
        }
        if (p_pi->description[0][0] != 0) {
                AV * av = newAV();
                int idx;
                for (idx = 0; idx < 8; idx++) {
                        av_push(av, newSVpv(p_pi->description[idx], 0));
                }
                hv_store_rv(hv, description, (SV*)av);
        }
}

static void zvbi_xs_event_to_hv( HV * hv, vbi_event * ev )
{
        if (ev->type == VBI_EVENT_TTX_PAGE) {
                hv_store_iv(hv, pgno, ev->ev.ttx_page.pgno);
                hv_store_iv(hv, subno, ev->ev.ttx_page.subno);
                hv_store_iv(hv, pn_offset, ev->ev.ttx_page.pn_offset);
                hv_store_sv(hv, raw_header, newSVpv(ev->ev.ttx_page.raw_header, 40));
                hv_store_iv(hv, roll_header, ev->ev.ttx_page.roll_header);
                hv_store_iv(hv, header_update, ev->ev.ttx_page.header_update);
                hv_store_iv(hv, clock_update, ev->ev.ttx_page.clock_update);

        } else if (ev->type == VBI_EVENT_CAPTION) {
                hv_store_iv(hv, pgno, ev->ev.ttx_page.pgno);

#ifdef VBI_EVENT_NETWORK_ID
        } else if ( (ev->type == VBI_EVENT_NETWORK) ||
                    (ev->type == VBI_EVENT_NETWORK_ID) ) {
                hv_store_iv(hv, nuid, ev->ev.network.nuid);
                if (ev->ev.network.name[0] != 0) {
                        hv_store_pv(hv, name, ev->ev.network.name);
                }
                if (ev->ev.network.call[0] != 0) {
                        hv_store_pv(hv, call, ev->ev.network.call);
                }
                hv_store_iv(hv, tape_delay, ev->ev.network.tape_delay);
                hv_store_iv(hv, cni_vps, ev->ev.network.cni_vps);
                hv_store_iv(hv, cni_8301, ev->ev.network.cni_8301);
                hv_store_iv(hv, cni_8302, ev->ev.network.cni_8302);
                hv_store_iv(hv, cycle, ev->ev.network.cycle);
#endif
        } else if (ev->type == VBI_EVENT_TRIGGER) {
                zvbi_xs_page_link_to_hv(hv, ev->ev.trigger);
        } else if (ev->type == VBI_EVENT_ASPECT) {
                zvbi_xs_aspect_ratio_to_hv(hv, &ev->ev.aspect);
        } else if (ev->type == VBI_EVENT_PROG_INFO) {
                zvbi_xs_prog_info_to_hv(hv, ev->ev.prog_info);
        }
}

static HV * zvbi_xs_export_info_to_hv( vbi_export_info * info )
{
        HV * hv = newHV();

        hv_store_pv(hv, keyword, info->keyword);
        hv_store_pv(hv, label, info->label);
        hv_store_pv(hv, tooltip, info->tooltip);
        hv_store_pv(hv, mime_type, info->mime_type);
        hv_store_pv(hv, extension, info->extension);

        return hv;
}

static void zvbi_xs_proxy_callback( void * p_data, VBI_PROXY_EV_TYPE ev_mask )
{
        SV * perl_cb = p_data;

        dSP ;
        ENTER ;
        SAVETMPS ;

        /* push the event mask on the Perl interpreter stack */
        PUSHMARK(SP) ;
        XPUSHs(sv_2mortal(newSViv(ev_mask)));
        PUTBACK ;

        /* invoke the Perl subroutine */
        call_sv(perl_cb, G_VOID | G_DISCARD) ;

        FREETMPS ;
        LEAVE ;
}

static void zvbi_xs_vt_event_handler( vbi_event * event, void * user_data )
{
        SV * perl_cb = user_data;
        HV * hv;

        dSP ;
        ENTER ;
        SAVETMPS ;

        /* push the event mask on the Perl interpreter stack */
        PUSHMARK(SP) ;
        hv = newHV();
        zvbi_xs_event_to_hv(hv, event);
        XPUSHs(sv_2mortal (newSViv (event->type)));
        XPUSHs(sv_2mortal (newRV_noinc ((SV*)hv)));
        PUTBACK ;

        /* invoke the Perl subroutine */
        call_sv(perl_cb, G_VOID | G_DISCARD) ;

        FREETMPS ;
        LEAVE ;
}

static int zvbi_xs_search_progress( vbi_page * p_pg )
{
        SV * perl_cb = zvbi_xs_search_progress_cb;
        SV * sv;
        VbiPageObj * pg_obj;

        I32  count;
        int  result = TRUE;

        if (perl_cb != NULL) {
                dSP ;
                ENTER ;
                SAVETMPS ;

                Newx(pg_obj, 1, VbiPageObj);
                pg_obj->do_free_pg = FALSE;
                pg_obj->p_pg = p_pg;

                sv = newSV(0);
                sv_setref_pv(sv, "Video::Capture::ZVBI::page", (void*)pg_obj);

                /* push the event mask on the Perl interpreter stack */
                PUSHMARK(SP) ;
                XPUSHs(sv_2mortal (sv));
                PUTBACK ;

                /* invoke the Perl subroutine */
                count = call_sv(perl_cb, G_SCALAR) ;

                SPAGAIN ;

                if (count == 1) {
                        result = POPi;
                }

                FREETMPS ;
                LEAVE ;
        }
        return result;
}

static void * zvbi_xs_sv_buffer_prep( SV * sv_buf, STRLEN buf_size )
{
        STRLEN l;

        if (!SvPOK(sv_buf))  {
                sv_setpv(sv_buf, "");
        }
        SvGROW(sv_buf, buf_size + 1);
        SvCUR_set(sv_buf, buf_size);
        return SvPV_force(sv_buf, l);
}

MODULE = Video::Capture::ZVBI	PACKAGE = Video::Capture::ZVBI::proxy	PREFIX = vbi_proxy_client_

PROTOTYPES: ENABLE

 # ---------------------------------------------------------------------------
 #  VBI Proxy Client
 # ---------------------------------------------------------------------------

VbiProxyObj *
vbi_proxy_client_create(dev_name, p_client_name, client_flags, errorstr, trace_level)
        const char *dev_name
        const char *p_client_name
        int client_flags
        char * &errorstr = NO_INIT
        int trace_level
        INIT:
        errorstr = NULL;
        CODE:
        RETVAL = vbi_proxy_client_create(dev_name, p_client_name, client_flags, &errorstr, trace_level);
        OUTPUT:
        errorstr
        RETVAL

void
vbi_proxy_client_DESTROY(vpc)
        VbiProxyObj * vpc
        CODE:
        vbi_proxy_client_destroy(vpc);

 # This function is currently NOT supported because we must not create a 2nd
 # reference to the C object (i.e. on Perl level there are two separate objects
 # but both share the same object on C level; so we'd have to implement a
 # secondary reference counter on C level.) It's not worth the effort anyway
 # since the application must have received the capture reference.
 #
 #VbiCaptureObj *
 #vbi_proxy_client_get_capture_if(vpc)
 #        VbiProxyObj * vpc

void
vbi_proxy_client_set_callback(vpc, callback=NULL, user_data=NULL)
        VbiProxyObj * vpc
        CV * callback
        SV * user_data
        CODE:
        /* TODO: user_data */
        if (callback != NULL) {
                vbi_proxy_client_set_callback(vpc, zvbi_xs_proxy_callback, callback);
        } else {
                vbi_proxy_client_set_callback(vpc, NULL, NULL);
        }

int
vbi_proxy_client_get_driver_api(vpc)
        VbiProxyObj * vpc

int
vbi_proxy_client_channel_request(vpc, chn_prio, profile=NULL)
        VbiProxyObj * vpc
        VBI_CHN_PRIO chn_prio
        HV * profile
        PREINIT:
        vbi_channel_profile l_profile;
        SV ** p_sv;
        CODE:
        memset(&l_profile, 0, sizeof(l_profile));
        if (profile != NULL) {
                if (NULL != (p_sv = hv_fetch_pv(profile, sub_prio))) {
                        l_profile.sub_prio = SvIV (*p_sv);
                }
                if (NULL != (p_sv = hv_fetch_pv(profile, allow_suspend))) {
                        l_profile.allow_suspend = SvIV (*p_sv);
                }
                if (NULL != (p_sv = hv_fetch_pv(profile, min_duration))) {
                        l_profile.min_duration = SvIV (*p_sv);
                }
                if (NULL != (p_sv = hv_fetch_pv(profile, exp_duration))) {
                        l_profile.exp_duration = SvIV (*p_sv);
                }
        }
        RETVAL = vbi_proxy_client_channel_request(vpc, chn_prio, &l_profile);
        OUTPUT:
        RETVAL

int
vbi_proxy_client_channel_notify(vpc, notify_flags, scanning)
        VbiProxyObj * vpc
        int notify_flags
        int scanning

int
vbi_proxy_client_channel_suspend(vpc, cmd)
        VbiProxyObj * vpc
        int cmd

int
vbi_proxy_client_device_ioctl(vpc, request, arg)
        VbiProxyObj * vpc
        int request
        SV * arg
        CODE:
        RETVAL = vbi_proxy_client_device_ioctl(vpc, request, SvPV_nolen (arg));
        OUTPUT:
        RETVAL

void
vbi_proxy_client_get_channel_desc(vpc)
        VbiProxyObj * vpc
        PREINIT:
        unsigned int scanning;
        vbi_bool granted;
        PPCODE:
        if (vbi_proxy_client_get_channel_desc(vpc, &scanning, &granted) == 0) {
                EXTEND(sp,2);
                PUSHs (sv_2mortal (newSViv (scanning)));
                PUSHs (sv_2mortal (newSViv (granted)));
        }

vbi_bool
vbi_proxy_client_has_channel_control(vpc)
        VbiProxyObj * vpc


 # ---------------------------------------------------------------------------
 #  VBI Capturing & Slicing
 # ---------------------------------------------------------------------------

MODULE = Video::Capture::ZVBI	PACKAGE = Video::Capture::ZVBI::capture	PREFIX = vbi_capture_

VbiCaptureObj *
vbi_capture_v4l2_new(dev_name, buffers, services, strict, errorstr, trace)
        const char * dev_name
        int buffers
        SV * services
        int strict
        char * &errorstr = NO_INIT
        vbi_bool trace
        PREINIT:
        unsigned int l_services;
        unsigned int * p_services;
        CODE:
        if (SvOK(services)) {
                l_services = SvIV(services);
                p_services = &l_services;
        } else {
                p_services = NULL;
        }
        errorstr = NULL;
        RETVAL = vbi_capture_v4l2_new(dev_name, buffers, p_services, strict, &errorstr, trace);
        if (p_services != NULL) {
                SvIV_set(services, l_services);
        }
        OUTPUT:
        services
        errorstr
        RETVAL

VbiCaptureObj *
vbi_capture_v4l_new(dev_name, scanning, services, strict, errorstr, trace)
        const char *dev_name
        int scanning
        unsigned int &services
        int strict
        char * &errorstr = NO_INIT
        vbi_bool trace
        INIT:
        errorstr = NULL;
        OUTPUT:
        services
        errorstr
        RETVAL

VbiCaptureObj *
vbi_capture_v4l_sidecar_new(dev_name, given_fd, services, strict, errorstr, trace)
        const char *dev_name
        int given_fd
        unsigned int &services
        int strict
        char * &errorstr = NO_INIT
        vbi_bool trace
        INIT:
        errorstr = NULL;
        OUTPUT:
        services
        errorstr
        RETVAL

VbiCaptureObj *
vbi_capture_bktr_new(dev_name, scanning, services, strict, errorstr, trace)
        const char *dev_name
        int scanning
        unsigned int &services
        int strict
        char * &errorstr = NO_INIT
        vbi_bool trace
        INIT:
        errorstr = NULL;
        OUTPUT:
        services
        errorstr
        RETVAL

int vbi_capture_dvb_filter(cap, pid)
        VbiCaptureObj * cap
        int pid

VbiCaptureObj *
vbi_capture_dvb_new(dev, scanning, services, strict, errorstr, trace)
        char *dev
        int scanning
        unsigned int &services
        int strict
        char * &errorstr = NO_INIT
        vbi_bool trace
        INIT:
        errorstr = NULL;
        OUTPUT:
        services
        errorstr
        RETVAL

int64_t
vbi_capture_dvb_last_pts(cap)
        VbiCaptureObj * cap

VbiCaptureObj *
vbi_capture_dvb_new2(device_name, pid, errorstr, trace)
        const char * device_name
        unsigned int pid
        char * &errorstr = NO_INIT
        vbi_bool trace
        INIT:
        errorstr = NULL;
        OUTPUT:
        errorstr
        RETVAL

VbiCaptureObj *
vbi_capture_proxy_new(vpc, buffers, scanning, services, strict, errorstr)
        VbiProxyObj * vpc
        int buffers
        int scanning
        unsigned int &services
        int strict
        char * &errorstr = NO_INIT
        INIT:
        errorstr = NULL;
        OUTPUT:
        services
        errorstr
        RETVAL

void
vbi_capture_DESTROY(cap)
        VbiCaptureObj * cap
        CODE:
        vbi_capture_delete(cap);

int
vbi_capture_read_raw(capture, raw_buffer, timestamp, msecs)
        VbiCaptureObj * capture
        VbiBufVar raw_buffer
        double &timestamp = NO_INIT
        int msecs
        PREINIT:
        struct timeval timeout;
        vbi_raw_decoder * p_par;
        char * p;
        CODE:
        timeout.tv_sec  = msecs / 1000;
        timeout.tv_usec = (msecs % 1000) * 1000;
        p_par = vbi_capture_parameters(capture);
        if (p_par != NULL) {
                size_t size = (p_par->count[0] + p_par->count[1]) * p_par->bytes_per_line;
                p = zvbi_xs_sv_buffer_prep(raw_buffer, size);
                RETVAL = vbi_capture_read_raw(capture, p, &timestamp, &timeout);
        } else {
                RETVAL = -1;
        }
        OUTPUT:
        raw_buffer
        timestamp
        RETVAL

int
vbi_capture_read_sliced(capture, data, lines, timestamp, msecs)
        VbiCaptureObj * capture
        SV * data
        int &lines = NO_INIT
        double &timestamp = NO_INIT
        int msecs
        PREINIT:
        struct timeval timeout;
        vbi_raw_decoder * p_par;
        vbi_sliced * p_sliced;
        CODE:
        timeout.tv_sec  = msecs / 1000;
        timeout.tv_usec = (msecs % 1000) * 1000;
        p_par = vbi_capture_parameters(capture);
        if (p_par != NULL) {
                size_t size = (p_par->count[0] + p_par->count[1]) * sizeof(vbi_sliced);
                p_sliced = zvbi_xs_sv_buffer_prep(data, size);
                RETVAL = vbi_capture_read_sliced(capture, p_sliced, &lines, &timestamp, &timeout);
        } else {
                RETVAL = -1;
        }
        OUTPUT:
        data
        lines
        timestamp
        RETVAL

int
vbi_capture_read(capture, raw_data, sliced_data, lines, timestamp, msecs)
        VbiCaptureObj * capture
        SV * raw_data
        SV * sliced_data
        int &lines = NO_INIT
        double &timestamp = NO_INIT
        int msecs
        PREINIT:
        struct timeval timeout;
        vbi_raw_decoder * p_par;
        char * p_raw;
        vbi_sliced * p_sliced;
        CODE:
        timeout.tv_sec  = msecs / 1000;
        timeout.tv_usec = (msecs % 1000) * 1000;
        p_par = vbi_capture_parameters(capture);
        if (p_par != NULL) {
                size_t size_raw = (p_par->count[0] + p_par->count[1]) * sizeof(vbi_sliced);
                size_t size_sliced = (p_par->count[0] + p_par->count[1]) * p_par->bytes_per_line;
                p_raw = zvbi_xs_sv_buffer_prep(raw_data, size_raw);
                p_sliced = zvbi_xs_sv_buffer_prep(sliced_data, size_sliced);
                RETVAL = vbi_capture_read(capture, p_raw, p_sliced, &lines, &timestamp, &timeout);
        } else {
                RETVAL = -1;
        }
        OUTPUT:
        raw_data
        sliced_data
        lines
        timestamp
        RETVAL

int
vbi_capture_pull_raw(capture, buffer, timestamp, msecs)
        VbiCaptureObj * capture
        VbiRawBuffer * &buffer = NO_INIT
        double &timestamp = NO_INIT
        int msecs
        PREINIT:
        struct timeval timeout;
        CODE:
        timeout.tv_sec  = msecs / 1000;
        timeout.tv_usec = (msecs % 1000) * 1000;
        RETVAL = vbi_capture_pull_raw(capture, &buffer, &timeout);
        if (RETVAL > 0) {
                timestamp = buffer->timestamp;
        } else {
                timestamp = 0.0;
        }
        OUTPUT:
        buffer
        timestamp
        RETVAL

int
vbi_capture_pull_sliced(capture, buffer, lines, timestamp, msecs)
        VbiCaptureObj * capture
        VbiSlicedBuffer * &buffer = NO_INIT
        int &lines = NO_INIT
        double &timestamp = NO_INIT
        int msecs
        PREINIT:
        struct timeval timeout;
        CODE:
        timeout.tv_sec  = msecs / 1000;
        timeout.tv_usec = (msecs % 1000) * 1000;
        RETVAL = vbi_capture_pull_sliced(capture, &buffer, &timeout);
        if (RETVAL > 0) {
                timestamp = buffer->timestamp;
                lines = buffer->size / sizeof(vbi_sliced);
        } else {
                timestamp = 0.0;
                lines = 0;
        }
        OUTPUT:
        buffer
        lines
        timestamp
        RETVAL

int
vbi_capture_pull(capture, raw_buffer, sliced_buffer, sliced_lines, timestamp, msecs)
        VbiCaptureObj * capture
        VbiRawBuffer * &raw_buffer
        VbiSlicedBuffer * &sliced_buffer
        int &sliced_lines = NO_INIT
        double &timestamp = NO_INIT
        int msecs
        PREINIT:
        struct timeval timeout;
        CODE:
        timeout.tv_sec  = msecs / 1000;
        timeout.tv_usec = (msecs % 1000) * 1000;
        RETVAL = vbi_capture_pull(capture, &raw_buffer, &sliced_buffer, &timeout);
        if (RETVAL > 0) {
                timestamp = raw_buffer->timestamp;
                sliced_lines = sliced_buffer->size / sizeof(vbi_sliced);
        } else {
                timestamp = 0.0;
                sliced_lines = 0;
        }
        OUTPUT:
        raw_buffer
        sliced_buffer
        sliced_lines
        timestamp
        RETVAL


HV *
vbi_capture_parameters(capture)
        VbiCaptureObj * capture
        PREINIT:
        vbi_raw_decoder * p_rd;
        CODE:
        RETVAL = newHV();
        sv_2mortal((SV*)RETVAL); /* see man perlxs */
        p_rd = vbi_capture_parameters(capture);
        if (p_rd != NULL) {
                zvbi_xs_dec_params_to_hv(RETVAL, p_rd);
        }
        OUTPUT:
        RETVAL

int
vbi_capture_fd(capture)
        VbiCaptureObj * capture

unsigned int
vbi_capture_update_services(capture, reset, commit, services, strict, errorstr)
        VbiCaptureObj * capture
        vbi_bool reset
        vbi_bool commit
        unsigned int services
        int strict
        char * &errorstr = NO_INIT
        OUTPUT:
        errorstr
        RETVAL

int
vbi_capture_get_scanning(capture)
        VbiCaptureObj * capture

void
vbi_capture_flush(capture)
        VbiCaptureObj * capture

vbi_bool
vbi_capture_set_video_path(capture, p_dev_video)
        VbiCaptureObj * capture
        const char * p_dev_video

VBI_CAPTURE_FD_FLAGS
vbi_capture_get_fd_flags(capture)
        VbiCaptureObj * capture

void
vbi_capture_copy_sliced_line(capture, sv_sliced, idx)
        VbiCaptureObj * capture
        SV * sv_sliced
        unsigned int idx
        PREINIT:
        vbi_sliced * p_sliced;
        unsigned int sliced_lines;
        PPCODE:
        if (sv_derived_from(sv_sliced, "VbiSlicedBufferPtr")) {
                IV tmp = SvIV((SV*)SvRV(sv_sliced));
                vbi_capture_buffer * p_sliced_buf = INT2PTR(vbi_capture_buffer *,tmp);
                sliced_lines = p_sliced_buf->size / sizeof(vbi_sliced);
                p_sliced = p_sliced_buf->data;
        } else {
                if (SvOK(sv_sliced)) {
                        size_t buf_size;
                        p_sliced = (void *) SvPV(sv_sliced, buf_size);
                        sliced_lines = buf_size / sizeof(vbi_sliced);
                } else {
                        Perl_croak(aTHX_ "Input raw buffer is undefined or not a scalar");
                        p_sliced = NULL;
                        sliced_lines = 0;
                }
        }
        if (idx < sliced_lines) {
                EXTEND(sp, 3);
                PUSHs (sv_2mortal (newSVpvn (p_sliced[idx].data, sizeof(p_sliced[idx].data))));
                PUSHs (sv_2mortal (newSViv (p_sliced[idx].id)));
                PUSHs (sv_2mortal (newSViv (p_sliced[idx].line)));
        }

 # ---------------------------------------------------------------------------
 #  VBI raw decoder
 # ---------------------------------------------------------------------------

MODULE = Video::Capture::ZVBI	PACKAGE = Video::Capture::ZVBI::rawdec	PREFIX = vbi_raw_decoder_

VbiRawDecObj *
vbi_raw_decoder_new(sv_init)
        SV * sv_init
        CODE:
        Newx(RETVAL, 1, VbiRawDecObj);
        vbi_raw_decoder_init(RETVAL);

        if (sv_derived_from(sv_init, "Video::Capture::ZVBI::capture")) {
                IV tmp = SvIV((SV*)SvRV(sv_init));
                vbi_capture * p_cap = INT2PTR(vbi_capture *,tmp);
                vbi_raw_decoder * p_par = vbi_capture_parameters(p_cap);
                if (p_par != NULL) {
                        RETVAL->scanning = p_par->scanning; 
                        RETVAL->sampling_format = p_par->sampling_format; 
                        RETVAL->sampling_rate = p_par->sampling_rate; 
                        RETVAL->bytes_per_line = p_par->bytes_per_line; 
                        RETVAL->offset = p_par->offset; 
                        RETVAL->start[0] = p_par->start[0]; 
                        RETVAL->start[1] = p_par->start[1]; 
                        RETVAL->count[0] = p_par->count[0]; 
                        RETVAL->count[1] = p_par->count[1]; 
                        RETVAL->interlaced = p_par->interlaced; 
                        RETVAL->synchronous = p_par->synchronous; 
                }
        } else if (SvROK(sv_init) && SvTYPE(SvRV(sv_init))==SVt_PVHV) {
                HV * hv = (HV*)SvRV(sv_init);
                zvbi_xs_hv_to_dec_params(hv, RETVAL);
        } else {
                Perl_croak(aTHX_ "Parameter is neither hash ref. nor ZVBI capture reference");
        }
        OUTPUT:
        RETVAL

void
vbi_raw_decoder_DESTROY(rd)
        VbiRawDecObj * rd
        CODE:
        vbi_raw_decoder_destroy(rd);
        Safefree(rd);

unsigned int
vbi_raw_decoder_parameters(hv, services, scanning, max_rate)
        HV * hv
        unsigned int services
        int scanning
        int &max_rate = NO_INIT
        PREINIT:
        vbi_raw_decoder rd;
        CODE:
        vbi_raw_decoder_init(&rd);
        RETVAL = vbi_raw_decoder_parameters(&rd, services, scanning, &max_rate);
        zvbi_xs_dec_params_to_hv(hv, &rd);
        vbi_raw_decoder_destroy(&rd);
        OUTPUT:
        hv
        max_rate
        RETVAL

void
vbi_raw_decoder_reset(rd)
        VbiRawDecObj * rd

unsigned int
vbi_raw_decoder_add_services(rd, services, strict)
        VbiRawDecObj * rd
        unsigned int services
        int strict

unsigned int
vbi_raw_decoder_check_services(rd, services, strict)
        VbiRawDecObj * rd
        unsigned int services
        int strict

unsigned int
vbi_raw_decoder_remove_services(rd, services)
        VbiRawDecObj * rd
        unsigned int services

void
vbi_raw_decoder_resize(rd, start_a, count_a, start_b, count_b)
        VbiRawDecObj * rd
        int start_a
        unsigned int count_a
        int start_b
        unsigned int count_b
        PREINIT:
        int start[2];
        unsigned int count[2];
        INIT:
        start[0] = start_a;
        start[1] = start_b;
        count[0] = count_a;
        count[1] = count_b;
        CODE:
        vbi_raw_decoder_resize(rd, start, count);

int
decode(rd, sv_raw, sv_sliced)
        VbiRawDecObj * rd
        SV * sv_raw
        SV * sv_sliced
        PREINIT:
        vbi_sliced * p_sliced;
        uint8_t * p_raw;
        size_t sliced_size;
        size_t raw_size;
        size_t raw_buf_size;
        CODE:
        if (sv_derived_from(sv_raw, "VbiRawBufferPtr")) {
                IV tmp = SvIV((SV*)SvRV(sv_raw));
                vbi_capture_buffer * p_raw_buf = INT2PTR(vbi_capture_buffer *,tmp);
                raw_buf_size = p_raw_buf->size;
                p_raw = p_raw_buf->data;
        } else {
                if (SvOK(sv_raw)) {
                        p_raw = (char*)SvPV(sv_raw, raw_buf_size);
                } else {
                        Perl_croak(aTHX_ "Input raw buffer is undefined or not a scalar");
                        p_raw = NULL;
                        raw_buf_size = 0;
                }
        }
        raw_size = (rd->count[0] + rd->count[1]) * rd->bytes_per_line;
        sliced_size = (rd->count[0] + rd->count[1]) * sizeof(vbi_sliced);
        if (raw_buf_size >= raw_size) {
                p_sliced = zvbi_xs_sv_buffer_prep(sv_sliced, sliced_size);
                RETVAL = vbi_raw_decode(rd, p_raw, p_sliced);
                SvCUR_set(sv_sliced, sliced_size);
        } else {
                Perl_croak(aTHX_ "Input raw buffer is smaller than required for VBI geometry");
        }
        OUTPUT:
        sv_sliced
        RETVAL

 # ---------------------------------------------------------------------------
 #  Teletext Page De-Multiplexing & Caching
 # ---------------------------------------------------------------------------

MODULE = Video::Capture::ZVBI	PACKAGE = Video::Capture::ZVBI::vt

VbiVtObj *
decoder_new()
        CODE:
        RETVAL = vbi_decoder_new();
        OUTPUT:
        RETVAL

void
DESTROY(decoder)
        VbiVtObj * decoder
        CODE:
        vbi_decoder_delete(decoder);

void
decode(vbi, sv_sliced, lines, timestamp)
        VbiVtObj * vbi
        SV * sv_sliced
        double timestamp
        PREINIT:
        vbi_sliced * p_sliced;
        int lines;
        CODE:
        if (sv_derived_from(sv_sliced, "VbiSlicedBufferPtr")) {
                IV tmp = SvIV((SV*)SvRV(sv_sliced));
                vbi_capture_buffer * p_sliced_buf = INT2PTR(vbi_capture_buffer *,tmp);
                lines = p_sliced_buf->size / sizeof(vbi_sliced);
                p_sliced = p_sliced_buf->data;
        } else {
                if (SvOK(sv_sliced)) {
                        size_t buf_size;
                        p_sliced = (void *) SvPV(sv_sliced, buf_size);
                        lines = buf_size / sizeof(vbi_sliced);
                } else {
                        Perl_croak(aTHX_ "Input raw buffer is undefined or not a scalar");
                        p_sliced = NULL;
                        lines = 0;
                }
        }
        if (lines != 0) {
                vbi_decode(vbi, p_sliced, lines, timestamp);
        }

void
channel_switched(vbi, nuid)
        VbiVtObj * vbi
        vbi_nuid nuid
        CODE:
        vbi_channel_switched(vbi, nuid);

void
classify_page(vbi, pgno)
        VbiVtObj * vbi
        vbi_pgno pgno
        PREINIT:
        vbi_page_type type;
        vbi_subno subno;
        char *language;
        PPCODE:
        type = vbi_classify_page(vbi, pgno, &subno, &language);
        EXTEND(sp, 3);
        PUSHs (sv_2mortal (newSViv (type)));
        PUSHs (sv_2mortal (newSViv (subno)));
        if (language != NULL)
                PUSHs (sv_2mortal(newSVpv(language, strlen(language))));
        else
                PUSHs (sv_2mortal(newSVpv("", 0)));

void
set_brightness(vbi, brightness)
        VbiVtObj * vbi
        int brightness
        CODE:
        vbi_set_brightness(vbi, brightness);

void
set_contrast(vbi, contrast)
        VbiVtObj * vbi
        int contrast
        CODE:
        vbi_set_contrast(vbi, contrast);

 # ---------------------------------------------------------------------------
 #  Teletext Page Caching
 # ---------------------------------------------------------------------------

void
teletext_set_default_region(vbi, default_region)
        VbiVtObj * vbi
        int default_region
        CODE:
        vbi_teletext_set_default_region(vbi, default_region);

void
teletext_set_level(vbi, level)
        VbiVtObj * vbi
        int level
        CODE:
        vbi_teletext_set_level(vbi, level);

VbiPageObj *
fetch_vt_page(vbi, pgno, subno, max_level, display_rows, navigation)
        VbiVtObj * vbi
        int pgno
        int subno
        int max_level
        int display_rows
        int navigation
        CODE:
        /* note the memory is freed by VbiPageObj::DESTROY defined below */
        Newx(RETVAL, 1, VbiPageObj);
        Newx(RETVAL->p_pg, 1, vbi_page);
        RETVAL->do_free_pg = TRUE;
        if (!vbi_fetch_vt_page(vbi, RETVAL->p_pg,
                               pgno, subno, max_level, display_rows, navigation)) {
                Safefree(RETVAL->p_pg);
                Safefree(RETVAL);
                XSRETURN_UNDEF;
        }
        OUTPUT:
        RETVAL

VbiPageObj *
fetch_cc_page(vbi, pgno, reset=0)
        VbiVtObj * vbi
        vbi_pgno pgno
        vbi_bool reset
        CODE:
        /* note the memory is freed by VbiPageObj::DESTROY defined below */
        Newx(RETVAL, 1, VbiPageObj);
        Newx(RETVAL->p_pg, 1, vbi_page);
        RETVAL->do_free_pg = TRUE;
        if (!vbi_fetch_cc_page(vbi, RETVAL->p_pg, pgno, reset)) {
                Safefree(RETVAL->p_pg);
                Safefree(RETVAL);
                XSRETURN_UNDEF;
        }
        OUTPUT:
        RETVAL

 # NOTE: vbi_unref_page is done automatically upon unref' of the page object

int
is_cached(vbi, pgno, subno)
        VbiVtObj * vbi
        int pgno
        int subno
        CODE:
        RETVAL = vbi_is_cached(vbi, pgno, subno);
        OUTPUT:
        RETVAL

int
cache_hi_subno(vbi, pgno)
        VbiVtObj * vbi
        int pgno
        CODE:
        RETVAL = vbi_cache_hi_subno(vbi, pgno);
        OUTPUT:
        RETVAL

void
page_title(vbi, pgno, subno)
        VbiVtObj * vbi
        int pgno
        int subno
        PPCODE:
        char buf[42];
        if (vbi_page_title(vbi, pgno, subno, buf)) {
                EXTEND(sp, 1);
                PUSHs (sv_2mortal(newSVpv(buf, strlen(buf))));
        }

 # ---------------------------------------------------------------------------
 #  Event Handling
 # ---------------------------------------------------------------------------

vbi_bool
event_handler_add(vbi, event_mask, handler, user_data=NULL)
        VbiVtObj * vbi
        int event_mask
        CV * handler
        SV * user_data
        CODE:
        /* TODO: user_data */
        RETVAL = vbi_event_handler_add(vbi, event_mask, zvbi_xs_vt_event_handler, handler);
        OUTPUT:
        RETVAL

void
event_handler_remove(vbi, handler)
        VbiVtObj * vbi
        CV * handler
        CODE:
        /* TODO: user_data */
        vbi_event_handler_remove(vbi, zvbi_xs_vt_event_handler);

vbi_bool
event_handler_register(vbi, event_mask, handler, user_data=NULL)
        VbiVtObj * vbi
        int event_mask
        CV * handler
        SV * user_data
        CODE:
        /* TODO: user_data */
        RETVAL = vbi_event_handler_register(vbi, event_mask, zvbi_xs_vt_event_handler, handler);
        OUTPUT:
        RETVAL

void
event_handler_unregister(vbi, handler, user_data)
        VbiVtObj * vbi
        CV * handler
        SV * user_data
        CODE:
        /* TODO: user_data */
        vbi_event_handler_unregister(vbi, zvbi_xs_vt_event_handler, handler);

 # ---------------------------------------------------------------------------
 #  Rendering
 # ---------------------------------------------------------------------------

MODULE = Video::Capture::ZVBI	PACKAGE = Video::Capture::ZVBI::page

void
DESTROY(pg_obj)
        VbiPageObj * pg_obj
        CODE:
        if (pg_obj->do_free_pg) {
                vbi_unref_page(pg_obj->p_pg);
                Safefree(pg_obj->p_pg);
        }
        Safefree(pg_obj);

void
draw_vt_page_region(pg_obj, fmt, canvas, rowstride, column, row, width, height, reveal=0, flash_on=0)
        VbiPageObj * pg_obj
        vbi_pixfmt fmt
        SV * canvas
        int rowstride
        int column
        int row
        int width
        int height
        int reveal
        int flash_on
        PREINIT:
        int canvas_size;
        char * p_buf;
        CODE:
        if (rowstride < 0) {
                rowstride = pg_obj->p_pg->columns * 12 * sizeof(vbi_rgba);
        }
        canvas_size = rowstride * height * 10;
        p_buf = zvbi_xs_sv_buffer_prep(canvas, canvas_size);
        vbi_draw_vt_page_region(pg_obj->p_pg, fmt, p_buf, rowstride, column, row, width, height, reveal, flash_on);
        OUTPUT:
        canvas

void
draw_vt_page(pg_obj, fmt, canvas, reveal=0, flash_on=0)
        VbiPageObj * pg_obj
        vbi_pixfmt fmt
        SV * canvas
        int reveal
        int flash_on
        PREINIT:
        int canvas_size;
        char * p_buf;
        int rowstride;
        CODE:
        rowstride = pg_obj->p_pg->columns * 12 * sizeof(vbi_rgba);
        canvas_size = rowstride * pg_obj->p_pg->rows * 10;
        p_buf = zvbi_xs_sv_buffer_prep(canvas, canvas_size);
        memset(p_buf, 0, canvas_size);
        vbi_draw_vt_page_region(pg_obj->p_pg, fmt, p_buf, rowstride, 0, 0,
                                pg_obj->p_pg->columns, pg_obj->p_pg->rows, reveal, flash_on);
        OUTPUT:
        canvas

void
draw_cc_page_region(pg_obj, fmt, canvas, rowstride, column, row, width, height)
        VbiPageObj * pg_obj
        vbi_pixfmt fmt
        SV * canvas
        int rowstride
        int column
        int row
        int width
        int height
        PREINIT:
        int canvas_size;
        char * p_buf;
        CODE:
        if (rowstride < 0) {
                rowstride = pg_obj->p_pg->columns * 16 * sizeof(vbi_rgba);
        }
        canvas_size = rowstride * height * 26;
        p_buf = zvbi_xs_sv_buffer_prep(canvas, canvas_size);
        vbi_draw_cc_page_region(pg_obj->p_pg, fmt, p_buf, rowstride, column, row, width, height);
        OUTPUT:
        canvas

void
draw_cc_page(pg_obj, fmt, canvas)
        VbiPageObj * pg_obj
        vbi_pixfmt fmt
        SV * canvas
        PREINIT:
        int canvas_size;
        char * p_buf;
        CODE:
        canvas_size = (pg_obj->p_pg->columns * 16 * sizeof(vbi_rgba)) * pg_obj->p_pg->rows * 26;
        p_buf = zvbi_xs_sv_buffer_prep(canvas, canvas_size);
        vbi_draw_cc_page_region(pg_obj->p_pg, fmt, p_buf, -1, 0, 0, pg_obj->p_pg->columns, pg_obj->p_pg->rows);
        OUTPUT:
        canvas

SV *
rgba_to_xpm(sv_canvas, rowstride, width, height)
        SV * sv_canvas
        int rowstride
        int width
        int height
        PREINIT:
        vbi_rgba * p_img;
        STRLEN buf_size;
        STRLEN size;
        int idx;
        HV * hv;
        char key[20];
        char code[2];
        int col_idx;
        char * p_key;
        I32 key_len;
        SV * sv;
        int row;
        int col;
        CODE:
        if (!SvOK(sv_canvas)) {
                Perl_croak(aTHX_ "Input buffer is undefined or not a scalar");
                XSRETURN_UNDEF;
        }
        p_img = (void *) SvPV(sv_canvas, buf_size);
        if (rowstride < 0) {
                rowstride = width * 12 * sizeof(vbi_rgba);
        }
        size = rowstride * height * 10;
        if (size != buf_size) {
                Perl_croak(aTHX_ "Input buffer size mismatch");
                XSRETURN_UNDEF;
        }
        hv = newHV();
        col_idx = 0;
        for (idx = 0; idx < size / sizeof(vbi_rgba); idx++) {
                sprintf(key, "%06X", p_img[idx] & 0xFFFFFF);
                if (!hv_exists(hv, key, 6)) {
                        hv_store(hv, key, 6, newSViv(col_idx), 0);
                        col_idx += 1;
                }
        }
        RETVAL = newSVpvf("/* XPM */\n"
                          "static char *image[] = {\n"
                          "/* width height ncolors chars_per_pixel */\n"
                          "\"%d %d %d %d\",\n"
                          "/* colors */\n",
                          rowstride / sizeof(vbi_rgba), height * 10, col_idx, 1);
        hv_iterinit(hv);
        while ((sv = hv_iternextsv(hv, &p_key, &key_len)) != NULL) {
                int cval;
                sscanf(p_key, "%X", &cval);
                sv_catpvf(RETVAL, "\"%c c #%02X%02X%02X\",\n",
                                  '0' + SvIV(sv),
                                  cval & 0xFF,
                                  (cval >> 8) & 0xFF,
                                  (cval >> 16) & 0xFF);
        }
        sv_catpv(RETVAL, "/* pixels */\n");
        code[1] = 0;
        for (row = 0; row < height * 10; row++) {
                sv_catpv(RETVAL, "\"");
                idx = row * rowstride / sizeof(vbi_rgba);
                for (col = 0; col < rowstride / sizeof(vbi_rgba); col++, idx++) {
                        sprintf(key, "%06X", p_img[idx] & 0xFFFFFF);
                        sv = *hv_fetch(hv, key, 6, 0);
                        code[0] = '0' + SvIV(sv);
                        sv_catpv(RETVAL, code);
                }
                sv_catpv(RETVAL, "\",\n");
        }
        sv_catpv(RETVAL, "};\n");
        SvREFCNT_dec(hv);
        OUTPUT:
        RETVAL

void
get_max_rendered_size()
        PPCODE:
        int w, h;
        vbi_get_max_rendered_size(&w, &h);
        EXTEND(sp, 2);
        PUSHs (sv_2mortal (newSViv (w)));
        PUSHs (sv_2mortal (newSViv (h)));

void
get_vt_cell_size()
        PPCODE:
        int w, h;
        vbi_get_vt_cell_size(&w, &h);
        EXTEND(sp, 2);
        PUSHs (sv_2mortal (newSViv (w)));
        PUSHs (sv_2mortal (newSViv (h)));


int
print_page_region(pg_obj, sv_buf, size, format, table, ltr, column, row, width, height)
        VbiPageObj * pg_obj
        SV * sv_buf
        int size
        const char * format
        vbi_bool table
        vbi_bool ltr
        int column
        int row
        int width
        int height
        PREINIT:
        char * p_buf = zvbi_xs_sv_buffer_prep(sv_buf, size);
        CODE:
        RETVAL = vbi_print_page_region(pg_obj->p_pg, p_buf, size,
                                       format, table, ltr,
                                       column, row, width, height);
        p_buf[RETVAL] = 0;
        SvCUR_set(sv_buf, RETVAL);
        OUTPUT:
        sv_buf
        RETVAL

int
print_page(pg_obj, sv_buf, size, format, table, ltr)
        VbiPageObj * pg_obj
        SV * sv_buf
        int size
        const char * format
        vbi_bool table
        vbi_bool ltr
        PREINIT:
        char * p_buf = zvbi_xs_sv_buffer_prep(sv_buf, size);
        CODE:
        RETVAL = vbi_print_page_region(pg_obj->p_pg, p_buf, size,
                                       format, table, ltr,
                                       0, 0, pg_obj->p_pg->columns, pg_obj->p_pg->rows);
        p_buf[RETVAL] = 0;
        SvCUR_set(sv_buf, RETVAL);
        OUTPUT:
        sv_buf
        RETVAL

void
get_page_no(pg_obj)
        VbiPageObj * pg_obj
        PPCODE:
        EXTEND(sp, 2);
        PUSHs (sv_2mortal (newSViv (pg_obj->p_pg->pgno)));
        PUSHs (sv_2mortal (newSViv (pg_obj->p_pg->subno)));

void
get_page_size(pg_obj)
        VbiPageObj * pg_obj
        PPCODE:
        EXTEND(sp, 2);
        PUSHs (sv_2mortal (newSViv (pg_obj->p_pg->rows)));
        PUSHs (sv_2mortal (newSViv (pg_obj->p_pg->columns)));

AV *
get_page_text_properties(pg_obj)
        VbiPageObj * pg_obj
        PREINIT:
        STRLEN size;
        int idx;
        vbi_char * p;
        unsigned long val;
        CODE:
        RETVAL = newAV();
        sv_2mortal((SV*)RETVAL); /* see man perlxs */
        size = pg_obj->p_pg->rows * pg_obj->p_pg->columns;
        av_extend(RETVAL, size);
        for (idx = 0; idx < size; idx++) {
                p = &pg_obj->p_pg->text[idx];
                val = (p->foreground << 0) |
                      (p->background << 8) |
                      ((p->opacity & 0x0F) << 16) |
                      ((p->size & 0x0F) << 20) |
                      (p->underline << 24) |
                      (p->bold << 25) |
                      (p->italic << 26) |
                      (p->flash << 27) |
                      (p->conceal << 28) |
                      (p->proportional << 29) |
                      (p->link << 30);
                av_store (RETVAL, idx, newSViv (val));
        }
        OUTPUT:
        RETVAL

SV *
get_page_text(pg_obj, all_chars=0)
        VbiPageObj * pg_obj
        vbi_bool all_chars
        PREINIT:
        int row;
        int column;
        STRLEN size;
        unsigned char * p_str;
        unsigned char * p;
        vbi_char * t;
        CODE:
        /* convert UCS-2 to UTF-8 */
        size = pg_obj->p_pg->rows * pg_obj->p_pg->columns * 3;
        Newx(p_str, size + UTF8_MAXBYTES+1 + 1, char);
        p = p_str;
        t = pg_obj->p_pg->text;
        for (row = 0; row < pg_obj->p_pg->rows; row++) {
                for (column = 0; column < pg_obj->p_pg->columns; column++) {
                        /* replace "private use" charaters with space */
                        UV ucs = (t++)->unicode;
                        if ((ucs > 0xE000) && (ucs <= 0xF8FF) && !all_chars) {
                                ucs = 0x20;
                        }
                        p = uvuni_to_utf8(p, ucs);
                        if (p - p_str > size) {
                                goto end_loops;
                        }
                }
        }
        end_loops:
        RETVAL = newSVpvn(p_str, p - p_str);
        SvUTF8_on(RETVAL);
        Safefree(p_str);
        OUTPUT:
        RETVAL

HV *
vbi_resolve_link(pg_obj, column, row)
        VbiPageObj * pg_obj
        int column
        int row
        PREINIT:
        vbi_link ld;
        CODE:
        vbi_resolve_link(pg_obj->p_pg, column, row, &ld);
        RETVAL = newHV();
        sv_2mortal((SV*)RETVAL); /* see man perlxs */
        zvbi_xs_page_link_to_hv(RETVAL, &ld);
        OUTPUT:
        RETVAL

HV *
vbi_resolve_home(pg_obj)
        VbiPageObj * pg_obj
        PREINIT:
        vbi_link ld;
        CODE:
        vbi_resolve_home(pg_obj->p_pg, &ld);
        RETVAL = newHV();
        sv_2mortal((SV*)RETVAL); /* see man perlxs */
        zvbi_xs_page_link_to_hv(RETVAL, &ld);
        OUTPUT:
        RETVAL

 # ---------------------------------------------------------------------------
 #  Teletext Page Export
 # ---------------------------------------------------------------------------

MODULE = Video::Capture::ZVBI	PACKAGE = Video::Capture::ZVBI::export	PREFIX = vbi_export_

VbiExportObj *
vbi_export_new(keyword, errstr)
        const char * keyword
        char * &errstr = NO_INIT
        INIT:
        errstr = NULL;
        OUTPUT:
        errstr
        RETVAL

void
vbi_export_DESTROY(exp)
        VbiExportObj * exp
        CODE:
        vbi_export_delete(exp);

void
vbi_export_info_enum(index)
        int index
        PREINIT:
        vbi_export_info * info;
        PPCODE:
        info = vbi_export_info_enum(index);
        if (info != NULL) {
                HV * hv = zvbi_xs_export_info_to_hv(info);
                EXTEND(sp,1);
                PUSHs (sv_2mortal (newRV_noinc ((SV*)hv)));
        }

void
vbi_export_info_keyword(keyword)
        const char * keyword
        PREINIT:
        vbi_export_info * info;
        PPCODE:
        info = vbi_export_info_keyword(keyword);
        if (info != NULL) {
                HV * hv = zvbi_xs_export_info_to_hv(info);
                EXTEND(sp,1);
                PUSHs (sv_2mortal (newRV_noinc ((SV*)hv)));
        }

void
vbi_export_info_export(exp)
        VbiExportObj * exp
        PREINIT:
        vbi_export_info * info;
        PPCODE:
        info = vbi_export_info_export(exp);
        if (info != NULL) {
                HV * hv = zvbi_xs_export_info_to_hv(info);
                EXTEND(sp,1);
                PUSHs (sv_2mortal (newRV_noinc ((SV*)hv)));
        }

 #vbi_option_info *        vbi_export_option_info_enum(VbiExportObj *, int index);
 #vbi_option_info *        vbi_export_option_info_keyword(VbiExportObj *, const char *keyword);

vbi_bool
vbi_export_option_set(exp, keyword, sv)
        VbiExportObj * exp
        const char * keyword
        SV * sv
        CODE:
        /* FIXME */
        if ( (strcmp(keyword, "network") == 0) ||
             (strcmp(keyword, "creator") == 0) ) {
                RETVAL = vbi_export_option_set(exp, keyword, SvIV(sv));
        } else {
                RETVAL = vbi_export_option_set(exp, keyword, SvPV_nolen(sv));
        }
        OUTPUT:
        RETVAL

vbi_bool
vbi_export_option_get(exp, keyword, value)
        VbiExportObj * exp
        const char * keyword
        SV * value
        PREINIT:
        vbi_option_value opt_val;
        CODE:
        /* TODO: convert opt_val into SV; problem: can't easily deduce type of option value */
        RETVAL = vbi_export_option_get(exp, keyword, &opt_val);
        OUTPUT:
        value
        RETVAL

vbi_bool
vbi_export_option_menu_set(exp, keyword, entry)
        VbiExportObj * exp
        const char * keyword
        int entry

vbi_bool
vbi_export_option_menu_get(exp, keyword, entry)
        VbiExportObj * exp
        const char * keyword
        int &entry = NO_INIT
        OUTPUT:
        entry

vbi_bool
vbi_export_stdio(exp, fp, pg_obj)
        VbiExportObj * exp
        FILE * fp
        VbiPageObj * pg_obj
        CODE:
        vbi_export_stdio(exp, fp, pg_obj->p_pg);

vbi_bool
vbi_export_file(exp, name, pg_obj)
        VbiExportObj * exp
        const char * name
        VbiPageObj * pg_obj
        CODE:
        vbi_export_file(exp, name, pg_obj->p_pg);

char *
vbi_export_errstr(exp)
        VbiExportObj * exp


 # ---------------------------------------------------------------------------
 #  Search
 # ---------------------------------------------------------------------------

MODULE = Video::Capture::ZVBI	PACKAGE = Video::Capture::ZVBI::search	PREFIX = vbi_search_

VbiSearchObj *
vbi_search_new(vbi, pgno, subno, pattern, casefold=0, regexp=0, progress=NULL)
        VbiVtObj * vbi
        vbi_pgno pgno
        vbi_subno subno
        SV * pattern
        vbi_bool casefold
        vbi_bool regexp
        CV * progress
        PREINIT:
        uint16_t * p_ucs;
        uint16_t * p;
        char * p_utf;
        STRLEN len;
        int rest;
        CODE:
        /* convert pattern string from Perl's utf8 into UCS-2 */
        p_utf = SvPVutf8_force(pattern, len);
        Newx(p_ucs, len * 2 + 2, uint16_t);
        p = p_ucs;
        rest = len;
        while (rest > 0) {
                *(p++) = utf8_to_uvchr(p_utf, &len);
                if (len > 0) {
                        p_utf += len;
                        rest -= len;
                } else {
                        break;
                }
        }
        *p = 0;
        if (progress == NULL) {
                RETVAL = vbi_search_new( vbi, pgno, subno, p_ucs, casefold, regexp, NULL );
        } else {
                zvbi_xs_search_progress_cb = progress;
                RETVAL = vbi_search_new( vbi, pgno, subno, p_ucs, casefold, regexp, zvbi_xs_search_progress );
        }
        Safefree(p_ucs);
        OUTPUT:
        RETVAL

void
DESTROY(search)
        VbiSearchObj * search
        CODE:
        vbi_search_delete(search);

int
vbi_search_next(search, pg_obj, dir)
        VbiSearchObj * search
        VbiPageObj * &pg_obj = NO_INIT
        int dir
        CODE:
        Newx(pg_obj, 1, VbiPageObj);
        pg_obj->do_free_pg = FALSE;
        pg_obj->p_pg = NULL;
        RETVAL = vbi_search_next(search, &pg_obj->p_pg, dir);
        if (pg_obj->p_pg == NULL) {
                Safefree(pg_obj);
                pg_obj = NULL;
        }
        OUTPUT:
        pg_obj
        RETVAL

 # ---------------------------------------------------------------------------
 #  Parity and Hamming decoding and encoding
 # ---------------------------------------------------------------------------

MODULE = Video::Capture::ZVBI	PACKAGE = Video::Capture::ZVBI	PREFIX = vbi_

unsigned int
par(val)
        unsigned int val
        PREINIT:
        uint8_t c;
        CODE:
        c = val;
        vbi_par(&c, 1);
        RETVAL = c;
        OUTPUT:
        RETVAL

unsigned int
unpar(val)
        unsigned int val
        PREINIT:
        uint8_t c;
        CODE:
        c = val;
        RETVAL = vbi_unpar(&c, 1);
        OUTPUT:
        RETVAL

void
par_str(data)
        SV * data
        PREINIT:
        uint8_t *p;
        STRLEN len;
        CODE:
        p = (uint8_t *)SvPV (data, len);
        vbi_par(p, len);
        OUTPUT:
        data

int
unpar_str(data)
        SV * data
        PREINIT:
        uint8_t *p;
        STRLEN len;
        CODE:
        p = (uint8_t *)SvPV (data, len);
        RETVAL = vbi_unpar(p, len);
        OUTPUT:
        data
        RETVAL

unsigned int
rev8(val)
        unsigned int val
        CODE:
        RETVAL = vbi_rev8(val);
        OUTPUT:
        RETVAL

unsigned int
rev16(val)
        unsigned int val
        CODE:
        RETVAL = vbi_rev16(val);
        OUTPUT:
        RETVAL

unsigned int
rev16p(data, offset=0)
        SV *    data
        int     offset
        PREINIT:
        uint8_t *p;
        STRLEN len;
        CODE:
        p = (uint8_t *)SvPV (data, len);
        if (len < offset + 2) {
                croak ("rev16p: input data length must greater than offset by at least 2");
        }
        RETVAL = vbi_rev16p(p + offset);
        OUTPUT:
        RETVAL

unsigned int
ham8(val)
        unsigned int val
        CODE:
        RETVAL = vbi_ham8(val);
        OUTPUT:
        RETVAL

int
unham8(val)
        unsigned int val
        CODE:
        RETVAL = vbi_unham8(val);
        OUTPUT:
        RETVAL

int
unham16p(data, offset=0)
        SV *    data
        int     offset
        PREINIT:
        unsigned char *p;
        STRLEN len;
        CODE:
        p = (unsigned char *)SvPV (data, len);
        if (len < offset + 2) {
                croak ("unham16p: input data length must greater than offset by at least 2");
        }
        RETVAL = vbi_unham16p(p + offset);
        OUTPUT:
        RETVAL

int
unham24p(data, offset=0)
        SV *    data
        int     offset
        PREINIT:
        unsigned char *p;
        STRLEN len;
        CODE:
        p = (unsigned char *)SvPV (data, len);
        if (len < offset + 3) {
                croak ("unham24p: input data length must greater than offset by at least 3");
        }
        RETVAL = vbi_unham24p(p + offset);
        OUTPUT:
        RETVAL

 # ---------------------------------------------------------------------------
 #  Miscellaneous
 # ---------------------------------------------------------------------------

MODULE = Video::Capture::ZVBI	PACKAGE = Video::Capture::ZVBI

void
lib_version()
        PPCODE:
{
        EXTEND(sp, 3);
        PUSHs (sv_2mortal (newSViv (VBI_VERSION_MAJOR)));
        PUSHs (sv_2mortal (newSViv (VBI_VERSION_MINOR)));
        PUSHs (sv_2mortal (newSViv (VBI_VERSION_MICRO)));
}

void
decode_vps_cni(data)
        SV * data
        PPCODE:
        unsigned int cni;
        unsigned char *p;
        STRLEN len;
        p = (unsigned char *)SvPV (data, len);
        if (len >= 13) {
                if (vbi_decode_vps_cni(&cni, p)) {
                        EXTEND(sp,1);
                        PUSHs (sv_2mortal (newSViv (cni)));
                }
        } else {
                croak ("decode_vps_cni: input buffer must have at least 13 bytes");
        }

void
encode_vps_cni(cni)
        unsigned int cni
        PREINIT:
        uint8_t buffer[13];
        PPCODE:
        if (vbi_encode_vps_cni(buffer, cni)) {
                EXTEND(sp,1);
                PUSHs (sv_2mortal (newSVpvn (buffer, 13)));
        }

void
rating_string(auth, id)
        int auth
        int id
        PPCODE:
        const char * p = vbi_rating_string(auth, id);
        if (p != NULL) {
                EXTEND(sp, 1);
                PUSHs (sv_2mortal(newSVpv(p, strlen(p))));
        }

void
prog_type_string(classf, id)
        int classf
        int id
        PPCODE:
        const char * p = vbi_prog_type_string(classf, id);
        if (p != NULL) {
                EXTEND(sp, 1);
                PUSHs (sv_2mortal(newSVpv(p, strlen(p))));
        }

BOOT:
{
        HV *stash = gv_stashpvn("Video::Capture::ZVBI", 75, TRUE);

        /* capture interface */
        newCONSTSUB(stash, "VBI_SLICED_NONE", newSViv(VBI_SLICED_NONE));
        newCONSTSUB(stash, "VBI_SLICED_UNKNOWN", newSViv(VBI_SLICED_UNKNOWN));
        newCONSTSUB(stash, "VBI_SLICED_ANTIOPE", newSViv(VBI_SLICED_ANTIOPE));
        newCONSTSUB(stash, "VBI_SLICED_TELETEXT_A", newSViv(VBI_SLICED_TELETEXT_A));
        newCONSTSUB(stash, "VBI_SLICED_TELETEXT_B_L10_625", newSViv(VBI_SLICED_TELETEXT_B_L10_625));
        newCONSTSUB(stash, "VBI_SLICED_TELETEXT_B_L25_625", newSViv(VBI_SLICED_TELETEXT_B_L25_625));
        newCONSTSUB(stash, "VBI_SLICED_TELETEXT_B", newSViv(VBI_SLICED_TELETEXT_B));
        newCONSTSUB(stash, "VBI_SLICED_TELETEXT_B_625", newSViv(VBI_SLICED_TELETEXT_B_625));
        newCONSTSUB(stash, "VBI_SLICED_TELETEXT_C_625", newSViv(VBI_SLICED_TELETEXT_C_625));
        newCONSTSUB(stash, "VBI_SLICED_TELETEXT_D_625", newSViv(VBI_SLICED_TELETEXT_D_625));
        newCONSTSUB(stash, "VBI_SLICED_VPS", newSViv(VBI_SLICED_VPS));
        newCONSTSUB(stash, "VBI_SLICED_VPS_F2", newSViv(VBI_SLICED_VPS_F2));
        newCONSTSUB(stash, "VBI_SLICED_CAPTION_625_F1", newSViv(VBI_SLICED_CAPTION_625_F1));
        newCONSTSUB(stash, "VBI_SLICED_CAPTION_625_F2", newSViv(VBI_SLICED_CAPTION_625_F2));
        newCONSTSUB(stash, "VBI_SLICED_CAPTION_625", newSViv(VBI_SLICED_CAPTION_625));
        newCONSTSUB(stash, "VBI_SLICED_WSS_625", newSViv(VBI_SLICED_WSS_625));
        newCONSTSUB(stash, "VBI_SLICED_CAPTION_525_F1", newSViv(VBI_SLICED_CAPTION_525_F1));
        newCONSTSUB(stash, "VBI_SLICED_CAPTION_525_F2", newSViv(VBI_SLICED_CAPTION_525_F2));
        newCONSTSUB(stash, "VBI_SLICED_CAPTION_525", newSViv(VBI_SLICED_CAPTION_525));
        newCONSTSUB(stash, "VBI_SLICED_2xCAPTION_525", newSViv(VBI_SLICED_2xCAPTION_525));
        newCONSTSUB(stash, "VBI_SLICED_TELETEXT_B_525", newSViv(VBI_SLICED_TELETEXT_B_525));
        newCONSTSUB(stash, "VBI_SLICED_NABTS", newSViv(VBI_SLICED_NABTS));
        newCONSTSUB(stash, "VBI_SLICED_TELETEXT_C_525", newSViv(VBI_SLICED_TELETEXT_C_525));
        newCONSTSUB(stash, "VBI_SLICED_TELETEXT_BD_525", newSViv(VBI_SLICED_TELETEXT_BD_525));
        newCONSTSUB(stash, "VBI_SLICED_TELETEXT_D_525", newSViv(VBI_SLICED_TELETEXT_D_525));
        newCONSTSUB(stash, "VBI_SLICED_WSS_CPR1204", newSViv(VBI_SLICED_WSS_CPR1204));
        newCONSTSUB(stash, "VBI_SLICED_VBI_625", newSViv(VBI_SLICED_VBI_625));
        newCONSTSUB(stash, "VBI_SLICED_VBI_525", newSViv(VBI_SLICED_VBI_525));

        newCONSTSUB(stash, "VBI_FD_HAS_SELECT", newSViv(VBI_FD_HAS_SELECT));
        newCONSTSUB(stash, "VBI_FD_HAS_MMAP", newSViv(VBI_FD_HAS_MMAP));
        newCONSTSUB(stash, "VBI_FD_IS_DEVICE", newSViv(VBI_FD_IS_DEVICE));

        /* proxy interface */
        newCONSTSUB(stash, "VBI_PROXY_CLIENT_NO_TIMEOUTS", newSViv(VBI_PROXY_CLIENT_NO_TIMEOUTS));
        newCONSTSUB(stash, "VBI_PROXY_CLIENT_NO_STATUS_IND", newSViv(VBI_PROXY_CLIENT_NO_STATUS_IND));

        newCONSTSUB(stash, "VBI_CHN_PRIO_BACKGROUND", newSViv(VBI_CHN_PRIO_BACKGROUND));
        newCONSTSUB(stash, "VBI_CHN_PRIO_INTERACTIVE", newSViv(VBI_CHN_PRIO_INTERACTIVE));
        newCONSTSUB(stash, "VBI_CHN_PRIO_DEFAULT", newSViv(VBI_CHN_PRIO_DEFAULT));
        newCONSTSUB(stash, "VBI_CHN_PRIO_RECORD", newSViv(VBI_CHN_PRIO_RECORD));

        newCONSTSUB(stash, "VBI_CHN_SUBPRIO_MINIMAL", newSViv(VBI_CHN_SUBPRIO_MINIMAL));
        newCONSTSUB(stash, "VBI_CHN_SUBPRIO_CHECK", newSViv(VBI_CHN_SUBPRIO_CHECK));
        newCONSTSUB(stash, "VBI_CHN_SUBPRIO_UPDATE", newSViv(VBI_CHN_SUBPRIO_UPDATE));
        newCONSTSUB(stash, "VBI_CHN_SUBPRIO_INITIAL", newSViv(VBI_CHN_SUBPRIO_INITIAL));
        newCONSTSUB(stash, "VBI_CHN_SUBPRIO_VPS_PDC", newSViv(VBI_CHN_SUBPRIO_VPS_PDC));

        newCONSTSUB(stash, "VBI_PROXY_CHN_RELEASE", newSViv(VBI_PROXY_CHN_RELEASE));
        newCONSTSUB(stash, "VBI_PROXY_CHN_TOKEN", newSViv(VBI_PROXY_CHN_TOKEN));
        newCONSTSUB(stash, "VBI_PROXY_CHN_FLUSH", newSViv(VBI_PROXY_CHN_FLUSH));
        newCONSTSUB(stash, "VBI_PROXY_CHN_NORM", newSViv(VBI_PROXY_CHN_NORM));
        newCONSTSUB(stash, "VBI_PROXY_CHN_FAIL", newSViv(VBI_PROXY_CHN_FAIL));
        newCONSTSUB(stash, "VBI_PROXY_CHN_NONE", newSViv(VBI_PROXY_CHN_NONE));

        newCONSTSUB(stash, "VBI_API_UNKNOWN", newSViv(VBI_API_UNKNOWN));
        newCONSTSUB(stash, "VBI_API_V4L1", newSViv(VBI_API_V4L1));
        newCONSTSUB(stash, "VBI_API_V4L2", newSViv(VBI_API_V4L2));
        newCONSTSUB(stash, "VBI_API_BKTR", newSViv(VBI_API_BKTR));

        newCONSTSUB(stash, "VBI_PROXY_EV_CHN_GRANTED", newSViv(VBI_PROXY_EV_CHN_GRANTED));
        newCONSTSUB(stash, "VBI_PROXY_EV_CHN_CHANGED", newSViv(VBI_PROXY_EV_CHN_CHANGED));
        newCONSTSUB(stash, "VBI_PROXY_EV_NORM_CHANGED", newSViv(VBI_PROXY_EV_NORM_CHANGED));
        newCONSTSUB(stash, "VBI_PROXY_EV_CHN_RECLAIMED", newSViv(VBI_PROXY_EV_CHN_RECLAIMED));
        newCONSTSUB(stash, "VBI_PROXY_EV_NONE", newSViv(VBI_PROXY_EV_NONE));

        /* vt object */
        newCONSTSUB(stash, "VBI_EVENT_NONE", newSViv(VBI_EVENT_NONE));
        newCONSTSUB(stash, "VBI_EVENT_CLOSE", newSViv(VBI_EVENT_CLOSE));
        newCONSTSUB(stash, "VBI_EVENT_TTX_PAGE", newSViv(VBI_EVENT_TTX_PAGE));
        newCONSTSUB(stash, "VBI_EVENT_CAPTION", newSViv(VBI_EVENT_CAPTION));
        newCONSTSUB(stash, "VBI_EVENT_NETWORK", newSViv(VBI_EVENT_NETWORK));
        newCONSTSUB(stash, "VBI_EVENT_TRIGGER", newSViv(VBI_EVENT_TRIGGER));
        newCONSTSUB(stash, "VBI_EVENT_ASPECT", newSViv(VBI_EVENT_ASPECT));
        newCONSTSUB(stash, "VBI_EVENT_PROG_INFO", newSViv(VBI_EVENT_PROG_INFO));
#ifdef VBI_EVENT_NETWORK_ID
        newCONSTSUB(stash, "VBI_EVENT_NETWORK_ID", newSViv(VBI_EVENT_NETWORK_ID));
#endif

        newCONSTSUB(stash, "VBI_WST_LEVEL_1", newSViv(VBI_WST_LEVEL_1));
        newCONSTSUB(stash, "VBI_WST_LEVEL_1p5", newSViv(VBI_WST_LEVEL_1p5));
        newCONSTSUB(stash, "VBI_WST_LEVEL_2p5", newSViv(VBI_WST_LEVEL_2p5));
        newCONSTSUB(stash, "VBI_WST_LEVEL_3p5", newSViv(VBI_WST_LEVEL_3p5));

        /* VT pages */
        newCONSTSUB(stash, "VBI_LINK_NONE", newSViv(VBI_LINK_NONE));
        newCONSTSUB(stash, "VBI_LINK_MESSAGE", newSViv(VBI_LINK_MESSAGE));
        newCONSTSUB(stash, "VBI_LINK_PAGE", newSViv(VBI_LINK_PAGE));
        newCONSTSUB(stash, "VBI_LINK_SUBPAGE", newSViv(VBI_LINK_SUBPAGE));
        newCONSTSUB(stash, "VBI_LINK_HTTP", newSViv(VBI_LINK_HTTP));
        newCONSTSUB(stash, "VBI_LINK_FTP", newSViv(VBI_LINK_FTP));
        newCONSTSUB(stash, "VBI_LINK_EMAIL", newSViv(VBI_LINK_EMAIL));
        newCONSTSUB(stash, "VBI_LINK_LID", newSViv(VBI_LINK_LID));
        newCONSTSUB(stash, "VBI_LINK_TELEWEB", newSViv(VBI_LINK_TELEWEB));

        newCONSTSUB(stash, "VBI_WEBLINK_UNKNOWN", newSViv(VBI_WEBLINK_UNKNOWN));
        newCONSTSUB(stash, "VBI_WEBLINK_PROGRAM_RELATED", newSViv(VBI_WEBLINK_PROGRAM_RELATED));
        newCONSTSUB(stash, "VBI_WEBLINK_NETWORK_RELATED", newSViv(VBI_WEBLINK_NETWORK_RELATED));
        newCONSTSUB(stash, "VBI_WEBLINK_STATION_RELATED", newSViv(VBI_WEBLINK_STATION_RELATED));
        newCONSTSUB(stash, "VBI_WEBLINK_SPONSOR_MESSAGE", newSViv(VBI_WEBLINK_SPONSOR_MESSAGE));
        newCONSTSUB(stash, "VBI_WEBLINK_OPERATOR", newSViv(VBI_WEBLINK_OPERATOR));

        newCONSTSUB(stash, "VBI_SUBT_NONE", newSViv(VBI_SUBT_NONE));
        newCONSTSUB(stash, "VBI_SUBT_ACTIVE", newSViv(VBI_SUBT_ACTIVE));
        newCONSTSUB(stash, "VBI_SUBT_MATTE", newSViv(VBI_SUBT_MATTE));
        newCONSTSUB(stash, "VBI_SUBT_UNKNOWN", newSViv(VBI_SUBT_UNKNOWN));

        /* search */
        newCONSTSUB(stash, "VBI_ANY_SUBNO", newSViv(VBI_ANY_SUBNO));
        newCONSTSUB(stash, "VBI_SEARCH_ERROR", newSViv(VBI_SEARCH_ERROR));
        newCONSTSUB(stash, "VBI_SEARCH_CACHE_EMPTY", newSViv(VBI_SEARCH_CACHE_EMPTY));
        newCONSTSUB(stash, "VBI_SEARCH_CANCELED", newSViv(VBI_SEARCH_CANCELED));
        newCONSTSUB(stash, "VBI_SEARCH_NOT_FOUND", newSViv(VBI_SEARCH_NOT_FOUND));
        newCONSTSUB(stash, "VBI_SEARCH_SUCCESS", newSViv(VBI_SEARCH_SUCCESS));

        /* export */
        newCONSTSUB(stash, "VBI_PIXFMT_RGBA32_LE", newSViv(VBI_PIXFMT_RGBA32_LE));
}
