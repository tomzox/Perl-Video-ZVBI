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
 * $Id: ZVBI.xs,v 1.1 2007/11/18 19:34:14 tom Exp tom $
 */

#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include <unistd.h>
#include <string.h>
#include <sys/types.h>
#include <sys/mman.h>

#include "libzvbi.h"

/* macro to check for a minimum libzvbi version number */
#define LIBZVBI_VERSION(A,B,C) \
   ((VBI_VERSION_MAJOR>(A)) || \
    ((VBI_VERSION_MAJOR==(A)) && (VBI_VERSION_MINOR>(B))) || \
    ((VBI_VERSION_MAJOR==(A)) && (VBI_VERSION_MINOR==(B)) && (VBI_VERSION_MICRO>=(C))))

/* abort the calling Perl script if an unsupported function is referenced */
#define CROAK_LIB_VERSION(A,B,C) croak("Not supported before libzvbi version " #A "." #B "." #C)

/*
 *  Types of object classes. Note the class name using in blessing is
 *  automatically derived from the type name via the typemap, hence the
 *  type names must match the PACKAGE names below except for the case.
 */
typedef vbi_capture VbiCaptureObj;
typedef vbi_capture_buffer VbiRawBuffer;
typedef vbi_capture_buffer VbiSlicedBuffer;
typedef vbi_raw_decoder VbiRawDecObj;
typedef vbi_export VbiExportObj;
typedef vbi_search VbiSearchObj;

typedef struct {
        vbi_decoder *   ctx;
        SV *            old_ev_cb;
        SV *            old_ev_user_data;
} VbiVtObj;

typedef struct {
        vbi_proxy_client * ctx;
        SV *            proxy_cb;
        SV *            proxy_user_data;
} VbiProxyObj;

typedef struct vbi_page_obj_struct {
        vbi_page *      p_pg;
        vbi_bool        do_free_pg;
} VbiPageObj;

typedef struct vbi_dvb_demux_obj_struct {
        vbi_dvb_demux * ctx;
        SV *            demux_cb;
        SV *            demux_user_data;
        SV *            log_cb;
        SV *            log_user_data;
} VbiDvb_DemuxObj;

typedef struct vbi_idl_demux_obj_struct {
        vbi_idl_demux * ctx;
        SV *            demux_cb;
        SV *            demux_user_data;
} VbiIdl_DemuxObj;

typedef struct vbi_pfc_demux_obj_struct {
        vbi_pfc_demux * ctx;
        SV *            demux_cb;
        SV *            demux_user_data;
} VbiPfc_DemuxObj;

typedef struct vbi_xds_demux_obj_struct {
        vbi_xds_demux * ctx;
        SV *            demux_cb;
        SV *            demux_user_data;
} VbiXds_DemuxObj;

typedef struct {
        unsigned int    l_services;
        unsigned int *  p_services;
} zvbi_xs_srv_or_null;

/*
 * Constants for the "draw" functions
 */
#define DRAW_TTX_CELL_WIDTH     12
#define DRAW_TTX_CELL_HEIGHT    10
#define DRAW_CC_CELL_WIDTH      16
#define DRAW_CC_CELL_HEIGHT     26
#if LIBZVBI_VERSION(0,2,26)
#define GET_CANVAS_TYPE(FMT)    (((FMT)==VBI_PIXFMT_PAL8) ? sizeof(uint8_t) : sizeof(vbi_rgba))
#else
#define GET_CANVAS_TYPE(FMT)    (sizeof(vbi_rgba))
#endif

/*
 * Static storage for callback function references
 */
#define MY_CXT_KEY "Video::ZVBI::_statics" XS_VERSION
#define ZVBI_MAX_CB_COUNT   10

/*
 * Structure which is used to store callback function references and user data.
 * Required because we need to replace the callback function pointer given to
 * the C library with a wrapper function which invokes the Perl interpreter. 
 */
typedef struct
{
        SV *            p_cb;
        SV *            p_data;
        void *          p_obj;
} zvbi_xs_cb_t;

typedef struct {
        zvbi_xs_cb_t    event[ZVBI_MAX_CB_COUNT];
        zvbi_xs_cb_t    search[ZVBI_MAX_CB_COUNT];
        zvbi_xs_cb_t    log[ZVBI_MAX_CB_COUNT];
} my_cxt_t;

START_MY_CXT

#define PVOID2INT(X)    ((int)((long)(X)))
#define PVOID2UINT(X)   ((unsigned int)((unsigned long)(X)))
#define INT2PVOID(X)    ((void *)((long)(X)))
#define UINT2PVOID(X)   ((void *)((unsigned long)(X)))

#define Save_SvREFCNT_dec(P) do{if ((P)!=NULL) {SvREFCNT_dec(P);}}while(0)

static unsigned
zvbi_xs_alloc_callback( zvbi_xs_cb_t * p_list, SV * p_cb, SV * p_data, void * p_obj )
{
        unsigned idx;

        for (idx = 0; idx < ZVBI_MAX_CB_COUNT; idx++) {
                if (p_list[idx].p_cb == NULL) {
                        p_list[idx].p_cb = SvREFCNT_inc(p_cb);
                        p_list[idx].p_data = SvREFCNT_inc(p_data);
                        p_list[idx].p_obj = p_obj;
                        break;
                }
        }
        return idx;
}

static unsigned
zvbi_xs_free_callback_by_idx( zvbi_xs_cb_t * p_list, unsigned idx )
{
        if (p_list[idx].p_cb != NULL) {
                SvREFCNT_dec(p_list[idx].p_cb);
                p_list[idx].p_cb = NULL;
        }
        if (p_list[idx].p_data != NULL) {
                SvREFCNT_dec(p_list[idx].p_data);
                p_list[idx].p_data = NULL;
        }
        p_list[idx].p_obj = NULL;
}

static unsigned
zvbi_xs_free_callback_by_ptr( zvbi_xs_cb_t * p_list, void * p_obj,
                              SV * p_cb, SV * p_data, vbi_bool cmp_data )
{
        unsigned match_idx = ZVBI_MAX_CB_COUNT;
        unsigned idx;

        for (idx = 0; idx < ZVBI_MAX_CB_COUNT; idx++) {
                if ((p_list[idx].p_obj == p_obj) &&
                    (p_list[idx].p_cb == p_cb) &&
                    (!cmp_data || (p_list[idx].p_data == p_data))){

                        zvbi_xs_free_callback_by_idx(p_list, idx);

                        match_idx = idx;
                }
        }
        return match_idx;
}

static void
zvbi_xs_free_callback_by_obj( zvbi_xs_cb_t * p_list, void * p_obj )
{
        unsigned idx;

        for (idx = 0; idx < ZVBI_MAX_CB_COUNT; idx++) {
                if (p_list[idx].p_obj == p_obj) {
                        zvbi_xs_free_callback_by_idx(p_list, idx);
                }
        }
}


#define hv_store_sv(HVPTR, NAME, SVPTR) hv_store (HVPTR, #NAME, strlen(#NAME), (SV*)(SVPTR), 0)
#define hv_store_pv(HVPTR, NAME, STR)   hv_store_sv (HVPTR, NAME, newSVpv ((STR), 0))
#define hv_store_iv(HVPTR, NAME, VAL)   hv_store_sv (HVPTR, NAME, newSViv (VAL))
#define hv_store_nv(HVPTR, NAME, VAL)   hv_store_sv (HVPTR, NAME, newSVnv (VAL))
#define hv_store_rv(HVPTR, NAME, VAL)   hv_store_sv (HVPTR, NAME, newRV_noinc (VAL))

#define hv_fetch_pv(HVPTR, NAME)        hv_fetch (HVPTR, #NAME, strlen(#NAME), 0)

/*
 * Convert a raw decoder C struct into a Perl hash
 */
static void
zvbi_xs_dec_params_to_hv( HV * hv, const vbi_raw_decoder * p_par )
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

/*
 * Fill a raw decoder C struct with parameters provided in a Perl hash.
 * (This is the reverse of the previous function.)
 *
 * The raw decoder struct must have been zeroed or initialized by the caller.
 */
static void
zvbi_xs_hv_to_dec_params( HV * hv, vbi_raw_decoder * p_rd )
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

/*
 * Convert event description structs into Perl hashes
 */
static void
zvbi_xs_page_link_to_hv( HV * hv, vbi_link * p_ld )
{
        hv_store_iv(hv, type, p_ld->type);
        hv_store_iv(hv, eacem, p_ld->eacem);
        if (p_ld->name[0] != 0) {
                hv_store_pv(hv, name, (char*)p_ld->name);
        }
        if (p_ld->url[0] != 0) {
                hv_store_pv(hv, url, (char*)p_ld->url);
        }
        if (p_ld->script[0] != 0) {
                hv_store_pv(hv, script, (char*)p_ld->script);
        }
        hv_store_iv(hv, nuid, p_ld->nuid);
        hv_store_iv(hv, pgno, p_ld->pgno);
        hv_store_iv(hv, subno, p_ld->subno);
        hv_store_nv(hv, expires, p_ld->expires);
        hv_store_iv(hv, itv_type, p_ld->itv_type);
        hv_store_iv(hv, priority, p_ld->priority);
        hv_store_iv(hv, autoload, p_ld->autoload);
}

static void
zvbi_xs_aspect_ratio_to_hv( HV * hv, vbi_aspect_ratio * p_asp )
{
        hv_store_iv(hv, first_line, p_asp->first_line);
        hv_store_iv(hv, last_line, p_asp->last_line);
        hv_store_nv(hv, ratio, p_asp->ratio);
        hv_store_iv(hv, film_mode, p_asp->film_mode);
        hv_store_iv(hv, open_subtitles, p_asp->open_subtitles);
}

static void
zvbi_xs_prog_info_to_hv( HV * hv, vbi_program_info * p_pi )
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
                hv_store_pv(hv, title, (char*)p_pi->title);
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
                hv_store_rv(hv, type_id, (SV*)av);
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
                        hv_store_pv(hv, language_a, (char*)p_pi->audio[0].language);
                }
        }
        if (p_pi->audio[1].mode != VBI_AUDIO_MODE_UNKNOWN) {
                hv_store_iv(hv, mode_b, p_pi->audio[1].mode);
                if (p_pi->audio[1].language != NULL) {
                        hv_store_pv(hv, language_b, (char*)p_pi->audio[1].language);
                }
        }
        if (p_pi->caption_services != -1) {
                AV * av = newAV();
                int idx;
                hv_store_iv(hv, caption_services, p_pi->caption_services);
                for (idx = 0; idx < 8; idx++) {
                        av_push(av, newSVpv((char*)p_pi->caption_language[idx], 0));
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
                        av_push(av, newSVpv((char*)p_pi->description[idx], 0));
                }
                hv_store_rv(hv, description, (SV*)av);
        }
}

static void
zvbi_xs_event_to_hv( HV * hv, vbi_event * ev )
{
        if (ev->type == VBI_EVENT_TTX_PAGE) {
                hv_store_iv(hv, pgno, ev->ev.ttx_page.pgno);
                hv_store_iv(hv, subno, ev->ev.ttx_page.subno);
                hv_store_iv(hv, pn_offset, ev->ev.ttx_page.pn_offset);
                hv_store_sv(hv, raw_header, newSVpv((char*)ev->ev.ttx_page.raw_header, 40));
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

static HV *
zvbi_xs_export_info_to_hv( vbi_export_info * p_info )
{
        HV * hv = newHV();

        hv_store_pv(hv, keyword, p_info->keyword);
        hv_store_pv(hv, label, p_info->label);
        hv_store_pv(hv, tooltip, p_info->tooltip);
        hv_store_pv(hv, mime_type, p_info->mime_type);
        hv_store_pv(hv, extension, p_info->extension);

        return hv;
}

static HV *
zvbi_xs_export_option_info_to_hv( vbi_option_info * p_opt )
{
        HV * hv = newHV();
        vbi_bool has_menu;

        hv_store_iv(hv, type, p_opt->type);

        if (p_opt->keyword != NULL) {
                hv_store_pv(hv, keyword, p_opt->keyword);
        }
        if (p_opt->label != NULL) {
                hv_store_pv(hv, label, p_opt->label);
        }
        if (p_opt->tooltip != NULL) {
                hv_store_pv(hv, tooltip, p_opt->tooltip);
        }

        switch (p_opt->type) {
        case VBI_OPTION_BOOL:
        case VBI_OPTION_INT:
        case VBI_OPTION_MENU:
                hv_store_iv(hv, def, p_opt->def.num);
                hv_store_iv(hv, min, p_opt->min.num);
                hv_store_iv(hv, max, p_opt->max.num);
                hv_store_iv(hv, step, p_opt->step.num);
                has_menu = (p_opt->menu.num != NULL);
                break;
        case VBI_OPTION_REAL:
                hv_store_nv(hv, def, p_opt->def.dbl);
                hv_store_nv(hv, min, p_opt->min.dbl);
                hv_store_nv(hv, max, p_opt->max.dbl);
                hv_store_nv(hv, step, p_opt->step.dbl);
                has_menu = (p_opt->menu.dbl != NULL);
                break;
        case VBI_OPTION_STRING:
                if (p_opt->def.str != NULL) {
                        hv_store_pv(hv, def, p_opt->def.str);
                }
                if (p_opt->min.str != NULL) {
                        hv_store_pv(hv, min, p_opt->min.str);
                }
                if (p_opt->max.str != NULL) {
                        hv_store_pv(hv, max, p_opt->max.str);
                }
                if (p_opt->step.str != NULL) {
                        hv_store_pv(hv, step, p_opt->step.str);
                }
                has_menu = (p_opt->menu.str != NULL);
                break;
        default:
                /* error - the caller can detect this case by evaluating the type */
                has_menu = FALSE;
                break;
        }

        if (has_menu && (p_opt->min.num >= 0)) {
                int idx;
                AV * av = newAV();
                av_extend(av, p_opt->max.num);

                for (idx = p_opt->min.num; idx <= p_opt->max.num; idx++) {
                        switch (p_opt->type) {
                        case VBI_OPTION_BOOL:
                        case VBI_OPTION_INT:
                                av_store(av, idx, newSViv(p_opt->menu.num[idx]));
                                break;
                        case VBI_OPTION_REAL:
                                av_store(av, idx, newSVnv(p_opt->menu.dbl[idx]));
                                break;
                        case VBI_OPTION_MENU:
                        case VBI_OPTION_STRING:
                                if (p_opt->menu.str[idx] != NULL) {
                                        av_store(av, idx, newSVpv(p_opt->menu.str[idx], 0));
                                }
                                break;
                        default:
                                break;
                        }
                }
                hv_store_rv(hv, menu, (SV*)av);
        }

        return hv;
}

/*
 * Invoke callback for an event generated by the proxy client
 */
static void
zvbi_xs_proxy_callback( void * user_data, VBI_PROXY_EV_TYPE ev_mask )
{
        VbiProxyObj * ctx = user_data;
        SV * perl_cb;

        if ((ctx != NULL) && (ctx->proxy_cb != NULL)) {
                dSP ;
                ENTER ;
                SAVETMPS ;

                /* push the function parameters on the Perl interpreter stack */
                PUSHMARK(SP) ;
                XPUSHs(sv_2mortal(newSViv(ev_mask)));
                if (ctx->proxy_user_data != NULL) {
                        XPUSHs(ctx->proxy_user_data);
                }
                PUTBACK ;

                /* invoke the Perl subroutine */
                call_sv(ctx->proxy_cb, G_VOID | G_DISCARD) ;

                FREETMPS ;
                LEAVE ;
        }
}

/*
 * Invoke callback for an event generated by the VT decoder
 */
static void
zvbi_xs_vt_event_handler( vbi_event * event, void * user_data )
{
        dMY_CXT;
        SV * perl_cb;
        HV * hv;
        unsigned cb_idx = PVOID2UINT(user_data);

        if ( (cb_idx < ZVBI_MAX_CB_COUNT) &&
             ((perl_cb = MY_CXT.event[cb_idx].p_cb) != NULL) ) {

                dSP ;
                ENTER ;
                SAVETMPS ;

                hv = newHV();
                zvbi_xs_event_to_hv(hv, event);

                /* push the function parameters on the Perl interpreter stack */
                /* NOTE: must be kept in sync with the alternate event handler below! */
                PUSHMARK(SP) ;
                XPUSHs(sv_2mortal (newSViv (event->type)));
                XPUSHs(sv_2mortal (newRV_noinc ((SV*)hv)));
                if (MY_CXT.event[cb_idx].p_data != NULL) {
                        XPUSHs(MY_CXT.event[cb_idx].p_data);
                }
                PUTBACK ;

                /* invoke the Perl subroutine */
                call_sv(perl_cb, G_VOID | G_DISCARD) ;

                FREETMPS ;
                LEAVE ;
        }
}

/*
 * Alternate event callback, for event handlers with old register semantics.
 * The old semantics allow for only one callback (across all event types)
 * i.e. when a second one is installed the previous handler is removed.
 */
static void
zvbi_xs_vt_event_handler_old( vbi_event * event, void * user_data )
{
        VbiVtObj * ctx = user_data;
        HV * hv;

        if ((ctx != NULL) && (ctx->old_ev_cb != NULL)) {
                dSP ;
                ENTER ;
                SAVETMPS ;

                hv = newHV();
                zvbi_xs_event_to_hv(hv, event);

                /* push the function parameters on the Perl interpreter stack */
                /* NOTE: must be kept in sync with the new event handler above! */
                PUSHMARK(SP) ;
                XPUSHs(sv_2mortal (newSViv (event->type)));
                XPUSHs(sv_2mortal (newRV_noinc ((SV*)hv)));
                if (ctx->old_ev_user_data != NULL) {
                        XPUSHs(ctx->old_ev_user_data);
                }
                PUTBACK ;

                /* invoke the Perl subroutine */
                call_sv(ctx->old_ev_cb, G_VOID | G_DISCARD) ;

                FREETMPS ;
                LEAVE ;
        }
}

/*
 * Invoke callback for the search in the teletext cache
 * Callback can return FALSE to abort the search.
 */
static int
zvbi_xs_search_progress( vbi_page * p_pg, unsigned cb_idx )
{
        dMY_CXT;
        SV * perl_cb;
        SV * sv;
        VbiPageObj * pg_obj;

        I32  count;
        int  result = TRUE;

        if ( (cb_idx < ZVBI_MAX_CB_COUNT) &&
             ((perl_cb = MY_CXT.search[cb_idx].p_cb) != NULL) ) {
                dSP ;
                ENTER ;
                SAVETMPS ;

                Newz(0, pg_obj, 1, VbiPageObj);
                pg_obj->do_free_pg = FALSE;
                pg_obj->p_pg = p_pg;

                sv = newSV(0);
                sv_setref_pv(sv, "Video::ZVBI::page", (void*)pg_obj);

                /* push the function parameters on the Perl interpreter stack */
                PUSHMARK(SP) ;
                XPUSHs(sv_2mortal (sv));
                if (MY_CXT.search[cb_idx].p_data != NULL) {
                        XPUSHs(MY_CXT.search[cb_idx].p_data);
                }
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

/*
 * The search callbacks don't support user data, so instead of passing an
 * array index through, the index is resurrected by using different functions.
 */
static int zvbi_xs_search_progress_0( vbi_page * p_pg ) { return zvbi_xs_search_progress(p_pg, 0); }
static int zvbi_xs_search_progress_1( vbi_page * p_pg ) { return zvbi_xs_search_progress(p_pg, 1); }
static int zvbi_xs_search_progress_2( vbi_page * p_pg ) { return zvbi_xs_search_progress(p_pg, 2); }
static int zvbi_xs_search_progress_3( vbi_page * p_pg ) { return zvbi_xs_search_progress(p_pg, 3); }

static int (* const zvbi_xs_search_cb_list[])( vbi_page * pg ) =
{
        zvbi_xs_search_progress_0,
        zvbi_xs_search_progress_1,
        zvbi_xs_search_progress_2,
        zvbi_xs_search_progress_3
};

/*
 * Invoke callback in DVB PES de-multiplexer to process sliced data.
 * Callback can return FALSE to abort decoding of the current buffer
 */
vbi_bool
zvbi_xs_dvb_pes_handler( vbi_dvb_demux *        dx,
                         void *                 user_data,
                         const vbi_sliced *     sliced,
                         unsigned int           sliced_lines,
                         int64_t                pts)
{
        VbiDvb_DemuxObj * ctx = user_data;
        vbi_capture_buffer buffer;
        SV * sv_sliced;

        I32  count;
        vbi_bool result = FALSE; /* defaults to "failure" result */

        if ((ctx != NULL) && (ctx->demux_cb != NULL)) {
                dSP ;
                ENTER ;
                SAVETMPS ;

	        buffer.data = (void*)sliced;  /* cast removes "const" */
	        buffer.size = sizeof(vbi_sliced) * sliced_lines;
	        buffer.timestamp = pts * 90000.0;

                sv_sliced = newSV(0);
                sv_setref_pv(sv_sliced, "VbiSlicedBufferPtr", (void*)&buffer);

                /* push the function parameters on the Perl interpreter stack */
                PUSHMARK(SP) ;
                XPUSHs(sv_2mortal (sv_sliced));
                XPUSHs(sv_2mortal (newSVuv (sliced_lines)));
                XPUSHs(sv_2mortal (newSViv (pts)));
                if (ctx->demux_user_data != NULL) {
                        XPUSHs(ctx->demux_user_data);
                }
                PUTBACK ;

                /* invoke the Perl subroutine */
                count = call_sv(ctx->demux_cb, G_SCALAR) ;

                SPAGAIN ;

                if (count == 1) {
                        result = !! POPi;
                }

                FREETMPS ;
                LEAVE ;
        }
        return result;
}

#if LIBZVBI_VERSION(0,2,22)
void
zvbi_xs_dvb_log_handler( vbi_log_mask           level,
                         const char *           context,
                         const char *           message,
                         void *                 user_data)
{
        VbiDvb_DemuxObj * ctx = user_data;
        I32  count;

        if ((ctx != NULL) && (ctx->log_cb != NULL)) {
                dSP ;
                ENTER ;
                SAVETMPS ;

                /* push all function parameters on the Perl interpreter stack */
                PUSHMARK(SP) ;
                XPUSHs(sv_2mortal (newSViv (level)));
                mXPUSHp(context, strlen(context));
                mXPUSHp(message, strlen(message));
                if (ctx->log_user_data != NULL) {
                        XPUSHs(ctx->log_user_data);
                }
                PUTBACK ;

                /* invoke the Perl subroutine */
                count = call_sv(ctx->log_cb, G_SCALAR) ;

                SPAGAIN ;

                FREETMPS ;
                LEAVE ;
        }
}
#endif

/*
 * Invoke callback for log messages.
 */
#if LIBZVBI_VERSION(0,2,22)
static void
zvbi_xs_log_callback( vbi_log_mask           level,
                      const char *           context,
                      const char *           message,
                      void *                 user_data)
{
        dMY_CXT;
        SV * perl_cb;
        unsigned cb_idx = PVOID2UINT(user_data);

        if ( (cb_idx < ZVBI_MAX_CB_COUNT) &&
             ((perl_cb = MY_CXT.log[cb_idx].p_cb) != NULL) ) {

                dSP ;
                ENTER ;
                SAVETMPS ;

                /* push the function parameters on the Perl interpreter stack */
                PUSHMARK(SP) ;
                XPUSHs(sv_2mortal (newSViv (level)));
                mXPUSHp(context, strlen(context));
                mXPUSHp(message, strlen(message));
                if (MY_CXT.log[cb_idx].p_data != NULL) {
                        XPUSHs(MY_CXT.log[cb_idx].p_data);
                }
                PUTBACK ;

                /* invoke the Perl subroutine */
                call_sv(perl_cb, G_VOID | G_DISCARD) ;

                FREETMPS ;
                LEAVE ;
        }
}
#endif

vbi_bool
zvbi_xs_demux_idl_handler( vbi_idl_demux *        dx,
                           const uint8_t *        buffer,
                           unsigned int           n_bytes,
                           unsigned int           flags,
                           void *                 user_data)
{
        VbiIdl_DemuxObj * ctx = user_data;
        I32  count;
        vbi_bool result = FALSE;

        if ((ctx != NULL) && (ctx->demux_cb != NULL)) {
                dSP ;
                ENTER ;
                SAVETMPS ;

                /* push all function parameters on the Perl interpreter stack */
                PUSHMARK(SP) ;
                XPUSHs(sv_2mortal (newSVpvn ((char*)buffer, n_bytes)));
                XPUSHs(sv_2mortal (newSViv (flags)));
                XPUSHs(ctx->demux_user_data);
                PUTBACK ;

                /* invoke the Perl subroutine */
                count = call_sv(ctx->demux_cb, G_SCALAR) ;

                SPAGAIN ;

                if (count == 1) {
                        result = POPi;
                }

                FREETMPS ;
                LEAVE ;
        }
        return result;
}

vbi_bool
zvbi_xs_demux_pfc_handler( vbi_pfc_demux *        dx,
                           void *                 user_data,
                           const vbi_pfc_block *  block )
{
        VbiPfc_DemuxObj * ctx = user_data;
        I32  count;
        vbi_bool result = FALSE;

        if ((ctx != NULL) && (ctx->demux_cb != NULL)) {
                dSP ;
                ENTER ;
                SAVETMPS ;

                /* push all function parameters on the Perl interpreter stack */
                PUSHMARK(SP) ;
                XPUSHs(sv_2mortal (newSViv (block->pgno)));
                XPUSHs(sv_2mortal (newSViv (block->stream)));
                XPUSHs(sv_2mortal (newSViv (block->application_id)));
                XPUSHs(sv_2mortal (newSVpvn ((char*)block->block, block->block_size)));
                XPUSHs(ctx->demux_user_data);
                PUTBACK ;

                /* invoke the Perl subroutine */
                count = call_sv(ctx->demux_cb, G_SCALAR) ;

                SPAGAIN ;

                if (count == 1) {
                        result = POPi;
                }

                FREETMPS ;
                LEAVE ;
        }
        return result;
}

vbi_bool
zvbi_xs_demux_xds_handler( vbi_xds_demux *        xd,
                           const vbi_xds_packet * xp,
                           void *                 user_data)
{
        VbiXds_DemuxObj * ctx = user_data;
        I32  count;
        vbi_bool result = FALSE;

        if ((ctx != NULL) && (ctx->demux_cb != NULL)) {
                dSP ;
                ENTER ;
                SAVETMPS ;

                /* push all function parameters on the Perl interpreter stack */
                PUSHMARK(SP) ;
                XPUSHs(sv_2mortal (newSViv (xp->xds_class)));
                XPUSHs(sv_2mortal (newSViv (xp->xds_subclass)));
                XPUSHs(sv_2mortal (newSVpvn ((char*)xp->buffer, xp->buffer_size)));
                XPUSHs(ctx->demux_user_data);
                PUTBACK ;

                /* invoke the Perl subroutine */
                count = call_sv(ctx->demux_cb, G_SCALAR) ;

                SPAGAIN ;

                if (count == 1) {
                        result = POPi;
                }

                FREETMPS ;
                LEAVE ;
        }
        return result;
}

/*
 * Get slicer buffer from a blessed vbi_capture_buffer struct or a plain scalar
 */
static vbi_sliced *
zvbi_xs_sv_to_sliced( SV * sv_sliced, unsigned int * max_lines )
{
        vbi_sliced * p_sliced;

        if (sv_derived_from(sv_sliced, "VbiSlicedBufferPtr")) {
                IV tmp = SvIV((SV*)SvRV(sv_sliced));
                vbi_capture_buffer * p_sliced_buf = INT2PTR(vbi_capture_buffer *,tmp);
                *max_lines = p_sliced_buf->size / sizeof(vbi_sliced);
                p_sliced = p_sliced_buf->data;

        } else if (SvOK(sv_sliced)) {
                size_t buf_size;
                p_sliced = (void *) SvPV(sv_sliced, buf_size);
                *max_lines = buf_size / sizeof(vbi_sliced);

        } else {
                croak("Input raw buffer is undefined or not a scalar");
                p_sliced = NULL;
                *max_lines = 0;
        }

        return p_sliced;
}

/*
 * Grow the given scalar to exactly the requested size for use as data buffer
 */
static void *
zvbi_xs_sv_buffer_prep( SV * sv_buf, STRLEN buf_size )
{
        STRLEN l;

        if (!SvPOK(sv_buf))  {
                sv_setpv(sv_buf, "");
        }
        SvGROW(sv_buf, buf_size + 1);
        SvCUR_set(sv_buf, buf_size);
        return SvPV_force(sv_buf, l);
}

/*
 * Grow the given scalar to at least the requested size for use as image buffer
 * and optionally zero the memory (i.e. blank the image)
 */
static void *
zvbi_xs_sv_canvas_prep( SV * sv_buf, STRLEN buf_size, vbi_bool blank )
{
        char * p_str;
        STRLEN l;

        if (!SvPOK(sv_buf))  {
                sv_setpv(sv_buf, "");
        }
        p_str = SvPV_force(sv_buf, l);
        if (l < buf_size) {
                SvGROW(sv_buf, buf_size + 1);
                SvCUR_set(sv_buf, buf_size);
                p_str = SvPV_force(sv_buf, l);

                memset(p_str, 0, buf_size);
        } else if (blank) {
                memset(p_str, 0, buf_size);
        }
        return p_str;
}

static SV *
zvbi_xs_convert_rgba_to_xpm( VbiPageObj * pg_obj, const vbi_rgba * p_img,
                             int pix_width, int pix_height, int scale )
{
        int idx;
        HV * hv;
        char key[20];
        char code[2];
        int col_idx;
        char * p_key;
        I32 key_len;
        int row;
        int col;
        STRLEN buf_size;
        SV * sv_xpm;
        SV * sv_tmp;
        SV ** p_sv;

        /*
         * Determine the color palette
         */
        hv = newHV();
        col_idx = 0;
        for (idx = 0; idx < pix_width * pix_height; idx++) {
                sprintf(key, "%06X", p_img[idx] & 0xFFFFFF);
                if (!hv_exists(hv, key, 6)) {
                        hv_store(hv, key, 6, newSViv(col_idx), 0);
                        col_idx += 1;
                }
        }

        switch (scale) {
                case 0: pix_height /= 2; break;
                case 2: pix_height *= 2; break;
                default: break;
        }

        /*
         * Write the image header (including image dimensions)
         */
        sv_xpm = newSVpvf("/* XPM */\n"
                          "static char *image[] = {\n"
                          "/* width height ncolors chars_per_pixel */\n"
                          "\"%d %d %d %d\",\n"
                          "/* colors */\n",
                          pix_width, pix_height, col_idx, 1);

        /* pre-extend the string to avoid re-alloc */
        (void *) SvPV(sv_xpm, buf_size);
        buf_size += col_idx * 15 + 13 + pix_height * (pix_width + 4) + 3;
        SvGROW(sv_xpm, buf_size + 1);

        /*
         * Write the color palette
         */
        hv_iterinit(hv);
        while ((sv_tmp = hv_iternextsv(hv, &p_key, &key_len)) != NULL) {
                int cval;
                sscanf(p_key, "%X", &cval);
                sv_catpvf(sv_xpm, "\"%c c #%02X%02X%02X\",\n",
                                  '0' + SvIV(sv_tmp),
                                  cval & 0xFF,
                                  (cval >> 8) & 0xFF,
                                  (cval >> 16) & 0xFF);
        }

        /*
         * Write the image row by row
         */
        sv_catpv(sv_xpm, "/* pixels */\n");
        code[1] = 0;
        for (row = 0; row < pix_height; row++) {
                sv_catpv(sv_xpm, "\"");
                for (col = 0; col < pix_width; col++) {
                        sprintf(key, "%06X", *(p_img++) & 0xFFFFFF);
                        p_sv = hv_fetch(hv, key, 6, 0);
                        if (p_sv != NULL) {
                                code[0] = '0' + SvIV(*p_sv);
                        } else {
                                code[0] = 0;  /* should never happen */
                        }
                        sv_catpvn(sv_xpm, code, 1);
                }
                sv_catpv(sv_xpm, "\",\n");

                if (scale == 0) {
                        p_img += pix_width;
                } else if ((scale == 2) && ((row & 1) == 0)) {
                        p_img -= pix_width;
                }
        }
        sv_catpv(sv_xpm, "};\n");
        SvREFCNT_dec(hv);

        return sv_xpm;

}

static SV *
zvbi_xs_convert_pal8_to_xpm( VbiPageObj * pg_obj, const uint8_t * p_img,
                             int pix_width, int pix_height, int scale )
{
#if LIBZVBI_VERSION(0,2,26)
        int idx;
        int row;
        int col;
        STRLEN buf_size;
        SV * sv_xpm;
        static const uint8_t col_codes[40] = " 1234567.BCDEFGHIJKLMNOPabcdefghijklmnop";

        switch (scale) {
                case 0: pix_height /= 2; break;
                case 2: pix_height *= 2; break;
                default: break;
        }

        /*
         * Write the image header (including image dimensions)
         */
        sv_xpm = newSVpvf("/* XPM */\n"
                          "static char *image[] = {\n"
                          "/* width height ncolors chars_per_pixel */\n"
                          "\"%d %d %d %d\",\n"
                          "/* colors */\n",
                          pix_width, pix_height, 40, 1);

        /* pre-extend the string to avoid re-alloc */
        (void *) SvPV(sv_xpm, buf_size);
        buf_size += 40 * 15 + 13 + pix_height * (pix_width + 4) + 3;
        SvGROW(sv_xpm, buf_size + 1);

        /*
         * Write the color palette (always the complete palette, including unused colors)
         */
        for (idx = 0; idx < 40; idx++) {
                sv_catpvf(sv_xpm, "\"%c c #%02X%02X%02X\",\n",
                                  col_codes[idx],
                                  pg_obj->p_pg->color_map[idx] & 0xFF,
                                  (pg_obj->p_pg->color_map[idx] >> 8) & 0xFF,
                                  (pg_obj->p_pg->color_map[idx] >> 16) & 0xFF);
        }

        /*
         * Write the image row by row
         */
        sv_catpv(sv_xpm, "/* pixels */\n");
        for (row = 0; row < pix_height; row++) {
                sv_catpv(sv_xpm, "\"");
                for (col = 0; col < pix_width; col++) {
                        uint8_t c = *(p_img++);
                        if (c < 40) {
                                sv_catpvn(sv_xpm, col_codes + c, 1);
                        } else {
                                sv_catpvn(sv_xpm, " ", 1);  /* invalid input, i.e. not PAL8 */
                        }
                }
                sv_catpv(sv_xpm, "\",\n");

                if (scale == 0) {
                        p_img += pix_width;
                } else if ((scale == 2) && ((row & 1) == 0)) {
                        p_img -= pix_width;
                }
        }
        sv_catpv(sv_xpm, "};\n");

        return sv_xpm;
#else /* version >= 0.2.26 */
        croak ("only RGBA convas formats are supported prior to libzvbi 0.2.26");
        return NULL;
#endif /* version >= 0.2.26 */
}

MODULE = Video::ZVBI	PACKAGE = Video::ZVBI::proxy	PREFIX = vbi_proxy_client_

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
        Newz(0, RETVAL, 1, VbiProxyObj);
        RETVAL->ctx = vbi_proxy_client_create(dev_name, p_client_name, client_flags,
                                              &errorstr, trace_level);
        if (RETVAL->ctx == NULL) {
                Safefree(RETVAL);
                RETVAL = NULL;
        }
        OUTPUT:
        errorstr
        RETVAL

void
vbi_proxy_client_DESTROY(vpc)
        VbiProxyObj * vpc
        CODE:
        vbi_proxy_client_destroy(vpc->ctx);
        Save_SvREFCNT_dec(vpc->proxy_cb);
        Save_SvREFCNT_dec(vpc->proxy_user_data);
        Safefree(vpc);

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
        Save_SvREFCNT_dec(vpc->proxy_cb);
        Save_SvREFCNT_dec(vpc->proxy_user_data);
        if (callback != NULL) {
                vpc->proxy_cb = SvREFCNT_inc(callback);
                vpc->proxy_user_data = SvREFCNT_inc(user_data);
                vbi_proxy_client_set_callback(vpc->ctx, zvbi_xs_proxy_callback, vpc);
        } else {
                vbi_proxy_client_set_callback(vpc->ctx, NULL, NULL);
        }

int
vbi_proxy_client_get_driver_api(vpc)
        VbiProxyObj * vpc
        CODE:
        RETVAL = vbi_proxy_client_get_driver_api(vpc->ctx);

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
                l_profile.is_valid = TRUE;
        }
        RETVAL = vbi_proxy_client_channel_request(vpc->ctx, chn_prio, &l_profile);
        OUTPUT:
        RETVAL

int
vbi_proxy_client_channel_notify(vpc, notify_flags, scanning=0)
        VbiProxyObj * vpc
        int notify_flags
        int scanning
        CODE:
        RETVAL = vbi_proxy_client_channel_notify(vpc->ctx, notify_flags, scanning);

int
vbi_proxy_client_channel_suspend(vpc, cmd)
        VbiProxyObj * vpc
        int cmd
        CODE:
        RETVAL = vbi_proxy_client_channel_suspend(vpc->ctx, cmd);

int
vbi_proxy_client_device_ioctl(vpc, request, sv_buf)
        VbiProxyObj * vpc
        int request
        SV * sv_buf
        PREINIT:
        char * p_buf;
        STRLEN buf_size;
        CODE:
        if (SvOK(sv_buf)) {
                p_buf = (void *) SvPV(sv_buf, buf_size);
                RETVAL = vbi_proxy_client_device_ioctl(vpc->ctx, request, p_buf);
        } else {
                croak("Argument buffer is undefined or not a scalar");
        }
        OUTPUT:
        RETVAL

void
vbi_proxy_client_get_channel_desc(vpc)
        VbiProxyObj * vpc
        PREINIT:
        unsigned int scanning;
        vbi_bool granted;
        PPCODE:
        if (vbi_proxy_client_get_channel_desc(vpc->ctx, &scanning, &granted) == 0) {
                EXTEND(sp,2);
                PUSHs (sv_2mortal (newSVuv (scanning)));
                PUSHs (sv_2mortal (newSViv (granted)));
        }

vbi_bool
vbi_proxy_client_has_channel_control(vpc)
        VbiProxyObj * vpc
        CODE:
        RETVAL = vbi_proxy_client_has_channel_control(vpc->ctx);


 # ---------------------------------------------------------------------------
 #  VBI Capturing & Slicing
 # ---------------------------------------------------------------------------

MODULE = Video::ZVBI	PACKAGE = Video::ZVBI::capture	PREFIX = vbi_capture_

VbiCaptureObj *
vbi_capture_v4l2_new(dev_name, buffers, srv, strict, errorstr, trace)
        const char * dev_name
        int buffers
        zvbi_xs_srv_or_null srv
        int strict
        char * &errorstr = NO_INIT
        vbi_bool trace
        CODE:
        errorstr = NULL;
        RETVAL = vbi_capture_v4l2_new(dev_name, buffers, srv.p_services, strict, &errorstr, trace);
        OUTPUT:
        srv
        errorstr
        RETVAL

VbiCaptureObj *
vbi_capture_v4l_new(dev_name, scanning, srv, strict, errorstr, trace)
        const char *dev_name
        int scanning
        zvbi_xs_srv_or_null srv
        int strict
        char * &errorstr = NO_INIT
        vbi_bool trace
        CODE:
        errorstr = NULL;
        RETVAL = vbi_capture_v4l_new(dev_name, scanning, srv.p_services, strict, &errorstr, trace);
        OUTPUT:
        srv
        errorstr
        RETVAL

VbiCaptureObj *
vbi_capture_v4l_sidecar_new(dev_name, given_fd, srv, strict, errorstr, trace)
        const char *dev_name
        int given_fd
        zvbi_xs_srv_or_null srv
        int strict
        char * &errorstr = NO_INIT
        vbi_bool trace
        CODE:
        errorstr = NULL;
        RETVAL = vbi_capture_v4l_sidecar_new(dev_name, given_fd, srv.p_services, strict, &errorstr, trace);
        OUTPUT:
        srv
        errorstr
        RETVAL

VbiCaptureObj *
vbi_capture_bktr_new(dev_name, scanning, srv, strict, errorstr, trace)
        const char *dev_name
        int scanning
        zvbi_xs_srv_or_null srv
        int strict
        char * &errorstr = NO_INIT
        vbi_bool trace
        CODE:
        errorstr = NULL;
        RETVAL = vbi_capture_bktr_new(dev_name, scanning, srv.p_services, strict, &errorstr, trace);
        OUTPUT:
        srv
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
vbi_capture_proxy_new(vpc, buffers, scanning, srv, strict, errorstr)
        VbiProxyObj * vpc
        int buffers
        int scanning
        zvbi_xs_srv_or_null srv
        int strict
        char * &errorstr = NO_INIT
        CODE:
        errorstr = NULL;
        RETVAL = vbi_capture_proxy_new(vpc->ctx, buffers, scanning, srv.p_services, strict, &errorstr);
        OUTPUT:
        srv
        errorstr
        RETVAL

void
vbi_capture_DESTROY(cap)
        VbiCaptureObj * cap
        CODE:
        vbi_capture_delete(cap);

int
vbi_capture_read_raw(capture, raw_buffer, timestamp, timeout_ms)
        VbiCaptureObj * capture
        SV * raw_buffer
        double &timestamp = NO_INIT
        int timeout_ms
        PREINIT:
        struct timeval tv;
        vbi_raw_decoder * p_par;
        char * p;
        CODE:
        tv.tv_sec  = timeout_ms / 1000;
        tv.tv_usec = (timeout_ms % 1000) * 1000;
        p_par = vbi_capture_parameters(capture);
        if (p_par != NULL) {
                size_t size = (p_par->count[0] + p_par->count[1]) * p_par->bytes_per_line;
                p = zvbi_xs_sv_buffer_prep(raw_buffer, size);
                RETVAL = vbi_capture_read_raw(capture, p, &timestamp, &tv);
        } else {
                RETVAL = -1;
        }
        OUTPUT:
        raw_buffer
        timestamp
        RETVAL

int
vbi_capture_read_sliced(capture, data, n_lines, timestamp, timeout_ms)
        VbiCaptureObj * capture
        SV * data
        int &n_lines = NO_INIT
        double &timestamp = NO_INIT
        int timeout_ms
        PREINIT:
        struct timeval tv;
        vbi_raw_decoder * p_par;
        vbi_sliced * p_sliced;
        CODE:
        tv.tv_sec  = timeout_ms / 1000;
        tv.tv_usec = (timeout_ms % 1000) * 1000;
        p_par = vbi_capture_parameters(capture);
        if (p_par != NULL) {
                size_t size = (p_par->count[0] + p_par->count[1]) * sizeof(vbi_sliced);
                p_sliced = zvbi_xs_sv_buffer_prep(data, size);
                RETVAL = vbi_capture_read_sliced(capture, p_sliced, &n_lines, &timestamp, &tv);
        } else {
                RETVAL = -1;
        }
        OUTPUT:
        data
        n_lines
        timestamp
        RETVAL

int
vbi_capture_read(capture, raw_data, sliced_data, n_lines, timestamp, timeout_ms)
        VbiCaptureObj * capture
        SV * raw_data
        SV * sliced_data
        int &n_lines = NO_INIT
        double &timestamp = NO_INIT
        int timeout_ms
        PREINIT:
        struct timeval tv;
        vbi_raw_decoder * p_par;
        char * p_raw;
        vbi_sliced * p_sliced;
        CODE:
        tv.tv_sec  = timeout_ms / 1000;
        tv.tv_usec = (timeout_ms % 1000) * 1000;
        p_par = vbi_capture_parameters(capture);
        if (p_par != NULL) {
                size_t size_sliced = (p_par->count[0] + p_par->count[1]) * sizeof(vbi_sliced);
                size_t size_raw = (p_par->count[0] + p_par->count[1]) * p_par->bytes_per_line;
                p_raw = zvbi_xs_sv_buffer_prep(raw_data, size_raw);
                p_sliced = zvbi_xs_sv_buffer_prep(sliced_data, size_sliced);
                RETVAL = vbi_capture_read(capture, p_raw, p_sliced, &n_lines, &timestamp, &tv);
        } else {
                RETVAL = -1;
        }
        OUTPUT:
        raw_data
        sliced_data
        n_lines
        timestamp
        RETVAL

int
vbi_capture_pull_raw(capture, buffer, timestamp, timeout_ms)
        VbiCaptureObj * capture
        VbiRawBuffer * &buffer = NO_INIT
        double &timestamp = NO_INIT
        int timeout_ms
        PREINIT:
        struct timeval tv;
        CODE:
        tv.tv_sec  = timeout_ms / 1000;
        tv.tv_usec = (timeout_ms % 1000) * 1000;
        RETVAL = vbi_capture_pull_raw(capture, &buffer, &tv);
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
vbi_capture_pull_sliced(capture, buffer, n_lines, timestamp, timeout_ms)
        VbiCaptureObj * capture
        VbiSlicedBuffer * &buffer = NO_INIT
        int &n_lines = NO_INIT
        double &timestamp = NO_INIT
        int timeout_ms
        PREINIT:
        struct timeval tv;
        CODE:
        tv.tv_sec  = timeout_ms / 1000;
        tv.tv_usec = (timeout_ms % 1000) * 1000;
        RETVAL = vbi_capture_pull_sliced(capture, &buffer, &tv);
        if (RETVAL > 0) {
                timestamp = buffer->timestamp;
                n_lines = buffer->size / sizeof(vbi_sliced);
        } else {
                timestamp = 0.0;
                n_lines = 0;
        }
        OUTPUT:
        buffer
        n_lines
        timestamp
        RETVAL

int
vbi_capture_pull(capture, raw_buffer, sliced_buffer, sliced_lines, timestamp, timeout_ms)
        VbiCaptureObj * capture
        VbiRawBuffer * &raw_buffer
        VbiSlicedBuffer * &sliced_buffer
        int &sliced_lines = NO_INIT
        double &timestamp = NO_INIT
        int timeout_ms
        PREINIT:
        struct timeval tv;
        CODE:
        tv.tv_sec  = timeout_ms / 1000;
        tv.tv_usec = (timeout_ms % 1000) * 1000;
        RETVAL = vbi_capture_pull(capture, &raw_buffer, &sliced_buffer, &tv);
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

MODULE = Video::ZVBI	PACKAGE = Video::ZVBI

void
get_sliced_line(sv_sliced, idx)
        SV * sv_sliced
        unsigned int idx
        PREINIT:
        vbi_sliced * p_sliced;
        unsigned int max_lines;
        PPCODE:
        p_sliced = zvbi_xs_sv_to_sliced(sv_sliced, &max_lines);
        if ((p_sliced != NULL) && (idx < max_lines)) {
                EXTEND(sp, 3);
                PUSHs (sv_2mortal (newSVpvn ((char*)p_sliced[idx].data, sizeof(p_sliced[idx].data))));
                PUSHs (sv_2mortal (newSVuv (p_sliced[idx].id)));
                PUSHs (sv_2mortal (newSVuv (p_sliced[idx].line)));
        }

 # ---------------------------------------------------------------------------
 #  VBI raw decoder
 # ---------------------------------------------------------------------------

MODULE = Video::ZVBI	PACKAGE = Video::ZVBI::rawdec	PREFIX = vbi_raw_decoder_

VbiRawDecObj *
vbi_raw_decoder_new(sv_init)
        SV * sv_init
        CODE:
        New(0, RETVAL, 1, VbiRawDecObj);
        vbi_raw_decoder_init(RETVAL);

        if (sv_derived_from(sv_init, "Video::ZVBI::capture")) {
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
                croak("Parameter is neither hash ref. nor ZVBI capture reference");
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
                        p_raw = (uint8_t*)SvPV(sv_raw, raw_buf_size);
                } else {
                        croak("Input raw buffer is undefined or not a scalar");
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
                croak("Input raw buffer is smaller than required for VBI geometry");
        }
        OUTPUT:
        sv_sliced
        RETVAL

 # ---------------------------------------------------------------------------
 #  DVB demux
 # ---------------------------------------------------------------------------

MODULE = Video::ZVBI	PACKAGE = Video::ZVBI::dvb_demux	PREFIX = vbi_dvb_demux_

VbiDvb_DemuxObj *
pes_new(callback=NULL, user_data=NULL)
        CV *                   callback
        SV *                   user_data
        CODE:
        Newz(0, RETVAL, 1, VbiDvb_DemuxObj);
        if (callback != NULL) {
                RETVAL->ctx = vbi_dvb_pes_demux_new(zvbi_xs_dvb_pes_handler, RETVAL);
                if (RETVAL->ctx != NULL) {
                        RETVAL->demux_cb = SvREFCNT_inc(callback);
                        RETVAL->demux_user_data = SvREFCNT_inc(user_data);
                }
        } else {
                RETVAL->ctx = vbi_dvb_pes_demux_new(NULL, NULL);
        }
        if (RETVAL->ctx == NULL) {
                Safefree(RETVAL);
                RETVAL = NULL;
        }
        OUTPUT:
        RETVAL

void
DESTROY(dx)
        VbiDvb_DemuxObj *       dx
        CODE:
        vbi_dvb_demux_delete(dx->ctx);
        Save_SvREFCNT_dec(dx->demux_cb);
        Save_SvREFCNT_dec(dx->demux_user_data);
        Save_SvREFCNT_dec(dx->log_cb);
        Save_SvREFCNT_dec(dx->log_user_data);
        Safefree(dx);

void
vbi_dvb_demux_reset(dx)
        VbiDvb_DemuxObj *       dx
        CODE:
        vbi_dvb_demux_reset(dx->ctx);

unsigned int
vbi_dvb_demux_cor(dx, sv_sliced, sliced_lines, pts, sv_buf, buf_left)
        VbiDvb_DemuxObj *       dx
        SV *                    sv_sliced
        unsigned int            sliced_lines
        int64_t                 &pts = NO_INIT
        SV *                    sv_buf
        unsigned int            buf_left
        PREINIT:
        STRLEN buf_size;
        const uint8_t * p_buf;
        vbi_sliced * p_sliced;
        size_t size_sliced;
        CODE:
        if (dx->demux_cb != NULL) {
                croak("Use of the cor method is not supported in demux contexts with handler function");

        } else if (SvOK(sv_buf)) {
                p_buf = (void *) SvPV(sv_buf, buf_size);
                if (buf_left <= buf_size) {
                        p_buf += buf_size - buf_left;

                        size_sliced = sliced_lines * sizeof(vbi_sliced);
                        p_sliced = (void *)zvbi_xs_sv_buffer_prep(sv_sliced, size_sliced);

                        RETVAL = vbi_dvb_demux_cor(dx->ctx, p_sliced, sliced_lines, &pts,
                                                   &p_buf, &buf_left);
                } else {
                        croak("Input buffer size %d is less than left count %d", buf_size, buf_left);
                        RETVAL = 0;
                }
        } else {
                croak("Input buffer is undefined or not a scalar");
                RETVAL = 0;
        }
        OUTPUT:
        sv_sliced
        pts
        buf_left
        RETVAL

vbi_bool
vbi_dvb_demux_feed(dx, sv_buf)
        VbiDvb_DemuxObj *       dx
        SV *                    sv_buf
        PREINIT:
        STRLEN buf_size;
        uint8_t * p_buf;
        CODE:
        if (dx->demux_cb == NULL) {
                croak("Use of the feed method is not possible in demux contexts without handler function");

        } else if (SvOK(sv_buf)) {
                p_buf = (uint8_t *) SvPV(sv_buf, buf_size);
                RETVAL = vbi_dvb_demux_feed(dx->ctx, p_buf, buf_size);
        } else {
                croak("Input buffer is undefined or not a scalar");
                RETVAL = FALSE;
        }
        OUTPUT:
        RETVAL

void
vbi_dvb_demux_set_log_fn(dx, mask, log_fn=NULL, user_data=NULL)
        VbiDvb_DemuxObj *       dx
        int                     mask
        CV *                    log_fn
        SV *                    user_data
        CODE:
#if LIBZVBI_VERSION(0,2,22)
        Save_SvREFCNT_dec(dx->log_cb);
        Save_SvREFCNT_dec(dx->log_user_data);
        if (log_fn != NULL) {
                dx->log_cb = SvREFCNT_inc(log_fn);
                dx->demux_user_data = SvREFCNT_inc(user_data);
                vbi_dvb_demux_set_log_fn(dx->ctx, mask, zvbi_xs_dvb_log_handler, dx);
        } else {
                dx->log_cb = NULL;
                dx->log_user_data = NULL;
                vbi_dvb_demux_set_log_fn(dx->ctx, mask, NULL, NULL);
        }
#else
        CROAK_LIB_VERSION(0,2,22);
#endif

 # ---------------------------------------------------------------------------
 # IDL Demux
 # ---------------------------------------------------------------------------

MODULE = Video::ZVBI	PACKAGE = Video::ZVBI::idl_demux	PREFIX = vbi_idl_demux_

VbiIdl_DemuxObj *
new(channel, address, callback=NULL, user_data=NULL)
        unsigned int           channel
        unsigned int           address
        CV *                   callback
        SV *                   user_data
        CODE:
        Newz(0, RETVAL, 1, VbiIdl_DemuxObj);
        if (callback != NULL) {
                RETVAL->ctx = vbi_idl_a_demux_new(channel, address,
                                                  zvbi_xs_demux_idl_handler, RETVAL);
                if (RETVAL->ctx != NULL) {
                        RETVAL->demux_cb = SvREFCNT_inc(callback);
                        RETVAL->demux_user_data = SvREFCNT_inc(user_data);
                }
        } else {
                RETVAL->ctx = vbi_idl_a_demux_new(channel, address, NULL, NULL);
        }
        if (RETVAL->ctx == NULL) {
                Safefree(RETVAL);
                RETVAL = NULL;
        }
        OUTPUT:
        RETVAL

void
DESTROY(dx)
        VbiIdl_DemuxObj * dx
        CODE:
        vbi_idl_demux_delete(dx->ctx);
        Save_SvREFCNT_dec(dx->demux_cb);
        Save_SvREFCNT_dec(dx->demux_user_data);
        Safefree(dx);

void
vbi_idl_demux_reset(dx)
        VbiIdl_DemuxObj * dx
        CODE:
        vbi_idl_demux_reset(dx->ctx);

vbi_bool
vbi_idl_demux_feed(dx, sv_buf)
        VbiIdl_DemuxObj * dx
        SV * sv_buf
        PREINIT:
        uint8_t * p_buf;
        STRLEN buf_size;
        CODE:
        if (SvOK(sv_buf)) {
                p_buf = (uint8_t *) SvPV(sv_buf, buf_size);
                if (buf_size >= 42) {
                        RETVAL = vbi_idl_demux_feed(dx->ctx, p_buf);
                } else {
                        croak("Input buffer has less than 42 bytes");
                        RETVAL = FALSE;
                }
        } else {
                croak("Input buffer is undefined or not a scalar");
                RETVAL = FALSE;
        }
        OUTPUT:
        RETVAL

vbi_bool
vbi_idl_demux_feed_frame(dx, sv_sliced, n_lines)
        VbiIdl_DemuxObj * dx
        SV * sv_sliced
        unsigned int n_lines
        PREINIT:
        vbi_sliced * p_sliced;
        unsigned int max_lines;
        CODE:
#if LIBZVBI_VERSION(0,2,26)
        p_sliced = zvbi_xs_sv_to_sliced(sv_sliced, &max_lines);
        if (p_sliced != NULL) {
                if (n_lines <= max_lines) {
                        vbi_idl_demux_feed_frame(dx->ctx, p_sliced, n_lines);
                } else {
                        croak("Invalid line count %d for buffer size (max. %d lines)", n_lines, max_lines);
                }
        }
#else
        CROAK_LIB_VERSION(0,2,26);
#endif
        OUTPUT:
        RETVAL

 # ---------------------------------------------------------------------------
 # PFC (Page Format Clear Demultiplexer ETS 300 708)
 # ---------------------------------------------------------------------------

MODULE = Video::ZVBI	PACKAGE = Video::ZVBI::pfc_demux	PREFIX = vbi_pfc_demux_

VbiPfc_DemuxObj *
vbi_pfc_demux_new(pgno, stream, callback=NULL, user_data=NULL)
        vbi_pgno               pgno
        unsigned int           stream
        CV *                   callback
        SV *                   user_data
        CODE:
        Newz(0, RETVAL, 1, VbiPfc_DemuxObj);
        if (callback != NULL) {
                /* note: libzvbi prior to version 0.2.26 had an incorrect type definition
                 * for the callback, hence the compiler will warn about a type mismatch */
                RETVAL->ctx = vbi_pfc_demux_new(pgno, stream, zvbi_xs_demux_pfc_handler, RETVAL);

                if (RETVAL->ctx != NULL) {
                        RETVAL->demux_cb = SvREFCNT_inc(callback);
                        RETVAL->demux_user_data = SvREFCNT_inc(user_data);
                }
        } else {
                RETVAL->ctx = vbi_pfc_demux_new(pgno, stream, NULL, NULL);
        }
        if (RETVAL->ctx == NULL) {
                Safefree(RETVAL);
                RETVAL = NULL;
        }
        OUTPUT:
        RETVAL

void
DESTROY(dx)
        VbiPfc_DemuxObj * dx
        CODE:
        vbi_pfc_demux_delete(dx->ctx);
        Save_SvREFCNT_dec(dx->demux_cb);
        Save_SvREFCNT_dec(dx->demux_user_data);
        Safefree(dx);

void
vbi_pfc_demux_reset(dx)
        VbiPfc_DemuxObj * dx
        CODE:
        vbi_pfc_demux_reset(dx->ctx);

vbi_bool
vbi_pfc_demux_feed(dx, sv_buf)
        VbiPfc_DemuxObj * dx
        SV * sv_buf
        PREINIT:
        uint8_t * p_buf;
        STRLEN buf_size;
        CODE:
        if (SvOK(sv_buf)) {
                p_buf = (uint8_t *) SvPV(sv_buf, buf_size);
                if (buf_size >= 42) {
                        RETVAL = vbi_pfc_demux_feed(dx->ctx, p_buf);
                } else {
                        croak("Input buffer has less than 42 bytes");
                        RETVAL = FALSE;
                }
        } else {
                croak("Input buffer is undefined or not a scalar");
                RETVAL = FALSE;
        }
        OUTPUT:
        RETVAL

vbi_bool
vbi_pfc_demux_feed_frame(dx, sv_sliced, n_lines)
        VbiPfc_DemuxObj * dx
        SV * sv_sliced
        unsigned int n_lines
        PREINIT:
        vbi_sliced * p_sliced;
        unsigned int max_lines;
        CODE:
#if LIBZVBI_VERSION(0,2,26)
        p_sliced = zvbi_xs_sv_to_sliced(sv_sliced, &max_lines);
        if (p_sliced != NULL) {
                if (n_lines <= max_lines) {
                        vbi_pfc_demux_feed_frame(dx->ctx, p_sliced, n_lines);
                } else {
                        croak("Invalid line count %d for buffer size (max. %d lines)", n_lines, max_lines);
                }
        }
#else
        CROAK_LIB_VERSION(0,2,26);
#endif
        OUTPUT:
        RETVAL

 # ---------------------------------------------------------------------------
 # XDS Demux
 # ---------------------------------------------------------------------------

MODULE = Video::ZVBI	PACKAGE = Video::ZVBI::xds_demux	PREFIX = vbi_xds_demux_

VbiXds_DemuxObj *
vbi_xds_demux_new(callback=NULL, user_data=NULL)
        CV * callback
        SV * user_data
        CODE:
        Newz(0, RETVAL, 1, VbiXds_DemuxObj);
        if (callback != NULL) {
                RETVAL->ctx = vbi_xds_demux_new(zvbi_xs_demux_xds_handler, RETVAL);

                if (RETVAL->ctx != NULL) {
                        RETVAL->demux_cb = SvREFCNT_inc(callback);
                        RETVAL->demux_user_data = SvREFCNT_inc(user_data);
                }
        } else {
                RETVAL->ctx = vbi_xds_demux_new(NULL, NULL);
        }
        if (RETVAL->ctx == NULL) {
                Safefree(RETVAL);
                RETVAL = NULL;
        }
        OUTPUT:
        RETVAL

void
DESTROY(xd)
        VbiXds_DemuxObj * xd
        CODE:
        vbi_xds_demux_delete(xd->ctx);
        Save_SvREFCNT_dec(xd->demux_cb);
        Save_SvREFCNT_dec(xd->demux_user_data);
        Safefree(xd);

void
vbi_xds_demux_reset(xd)
        VbiXds_DemuxObj * xd
        CODE:
        vbi_xds_demux_reset(xd->ctx);

vbi_bool
vbi_xds_demux_feed(xd, sv_buf)
        VbiXds_DemuxObj * xd
        SV * sv_buf
        PREINIT:
        uint8_t * p_buf;
        STRLEN buf_size;
        CODE:
        if (SvOK(sv_buf)) {
                p_buf = (uint8_t *) SvPV(sv_buf, buf_size);
                if (buf_size >= 2) {
                        RETVAL = vbi_xds_demux_feed(xd->ctx, p_buf);
                } else {
                        croak("Input buffer has less than 2 bytes");
                        RETVAL = FALSE;
                }
        } else {
                croak("Input buffer is undefined or not a scalar");
                RETVAL = FALSE;
        }
        OUTPUT:
        RETVAL

vbi_bool
vbi_xds_demux_feed_frame(xd, sv_sliced, n_lines)
        VbiXds_DemuxObj * xd
        SV * sv_sliced
        unsigned int n_lines
        PREINIT:
        vbi_sliced * p_sliced;
        unsigned int max_lines;
        CODE:
#if LIBZVBI_VERSION(0,2,26)
        p_sliced = zvbi_xs_sv_to_sliced(sv_sliced, &max_lines);
        if (p_sliced != NULL) {
                if (n_lines <= max_lines) {
                        vbi_xds_demux_feed_frame(xd->ctx, p_sliced, n_lines);
                } else {
                        croak("Invalid line count %d for buffer size (max. %d lines)", n_lines, max_lines);
                }
        }
#else
        CROAK_LIB_VERSION(0,2,26);
#endif
        OUTPUT:
        RETVAL

 # ---------------------------------------------------------------------------
 #  Teletext Page De-Multiplexing & Caching
 # ---------------------------------------------------------------------------

MODULE = Video::ZVBI	PACKAGE = Video::ZVBI::vt

VbiVtObj *
decoder_new()
        CODE:
        Newz(0, RETVAL, 1, VbiVtObj);
        RETVAL->ctx = vbi_decoder_new();
        if (RETVAL->ctx == NULL) {
                Safefree(RETVAL);
        }
        OUTPUT:
        RETVAL

void
DESTROY(vbi)
        VbiVtObj * vbi
        CODE:
        vbi_decoder_delete(vbi->ctx);
        Save_SvREFCNT_dec(vbi->old_ev_cb);
        Save_SvREFCNT_dec(vbi->old_ev_user_data);
        Safefree(vbi);

void
decode(vbi, sv_sliced, n_lines, timestamp)
        VbiVtObj * vbi
        SV * sv_sliced
        unsigned int n_lines;
        double timestamp
        PREINIT:
        vbi_sliced * p_sliced;
        unsigned int max_lines;
        CODE:
        p_sliced = zvbi_xs_sv_to_sliced(sv_sliced, &max_lines);
        if (p_sliced != NULL) {
                if (n_lines <= max_lines) {
                        vbi_decode(vbi->ctx, p_sliced, n_lines, timestamp);
                } else {
                        croak("Invalid line count %d for buffer size (max. %d lines)", n_lines, max_lines);
                }
        }

void
channel_switched(vbi, nuid=0)
        VbiVtObj * vbi
        vbi_nuid nuid
        CODE:
        vbi_channel_switched(vbi->ctx, nuid);

void
classify_page(vbi, pgno)
        VbiVtObj * vbi
        vbi_pgno pgno
        PREINIT:
        vbi_page_type type;
        vbi_subno subno;
        char *language;
        PPCODE:
        type = vbi_classify_page(vbi->ctx, pgno, &subno, &language);
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
        vbi_set_brightness(vbi->ctx, brightness);

void
set_contrast(vbi, contrast)
        VbiVtObj * vbi
        int contrast
        CODE:
        vbi_set_contrast(vbi->ctx, contrast);

 # ---------------------------------------------------------------------------
 #  Teletext Page Caching
 # ---------------------------------------------------------------------------

void
teletext_set_default_region(vbi, default_region)
        VbiVtObj * vbi
        int default_region
        CODE:
        vbi_teletext_set_default_region(vbi->ctx, default_region);

void
teletext_set_level(vbi, level)
        VbiVtObj * vbi
        int level
        CODE:
        vbi_teletext_set_level(vbi->ctx, level);

VbiPageObj *
fetch_vt_page(vbi, pgno, subno, max_level=VBI_WST_LEVEL_3p5, display_rows=25, navigation=1)
        VbiVtObj * vbi
        int pgno
        int subno
        int max_level
        int display_rows
        int navigation
        CODE:
        /* note the memory is freed by VbiPageObj::DESTROY defined below */
        Newz(0, RETVAL, 1, VbiPageObj);
        New(0, RETVAL->p_pg, 1, vbi_page);
        RETVAL->do_free_pg = TRUE;
        if (!vbi_fetch_vt_page(vbi->ctx, RETVAL->p_pg,
                               pgno, subno, max_level, display_rows, navigation)) {
                Safefree(RETVAL->p_pg);
                Safefree(RETVAL);
                XSRETURN_UNDEF;
        }
        OUTPUT:
        RETVAL

VbiPageObj *
fetch_cc_page(vbi, pgno, reset=1)
        VbiVtObj * vbi
        vbi_pgno pgno
        vbi_bool reset
        CODE:
        /* note the memory is freed by VbiPageObj::DESTROY defined below */
        Newz(0, RETVAL, 1, VbiPageObj);
        New(0, RETVAL->p_pg, 1, vbi_page);
        RETVAL->do_free_pg = TRUE;
        if (!vbi_fetch_cc_page(vbi->ctx, RETVAL->p_pg, pgno, reset)) {
                Safefree(RETVAL->p_pg);
                Safefree(RETVAL);
                XSRETURN_UNDEF;
        }
        OUTPUT:
        RETVAL

int
is_cached(vbi, pgno, subno)
        VbiVtObj * vbi
        int pgno
        int subno
        CODE:
        RETVAL = vbi_is_cached(vbi->ctx, pgno, subno);
        OUTPUT:
        RETVAL

int
cache_hi_subno(vbi, pgno)
        VbiVtObj * vbi
        int pgno
        CODE:
        RETVAL = vbi_cache_hi_subno(vbi->ctx, pgno);
        OUTPUT:
        RETVAL

void
page_title(vbi, pgno, subno)
        VbiVtObj * vbi
        int pgno
        int subno
        PPCODE:
        char buf[42];
        if (vbi_page_title(vbi->ctx, pgno, subno, buf)) {
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
        if (vbi->old_ev_cb != NULL) {
                warn("Video::ZVBI::vt is overwriting a previous event handler\n"
                     "Call event_handler_remove or "
                     "use event_handler_register instead when using multiple callbacks\n");
                Save_SvREFCNT_dec(vbi->old_ev_cb);
                Save_SvREFCNT_dec(vbi->old_ev_user_data);
                vbi->old_ev_cb = NULL;
                vbi->old_ev_user_data = NULL;
        }
        RETVAL = vbi_event_handler_add(vbi->ctx, event_mask, zvbi_xs_vt_event_handler_old, vbi);
        if (RETVAL) {
                vbi->old_ev_cb = SvREFCNT_inc(handler);
                vbi->old_ev_user_data = SvREFCNT_inc(user_data);
        }
        OUTPUT:
        RETVAL

void
event_handler_remove(vbi, handler=NULL)
        VbiVtObj * vbi
        CV * handler
        CODE:
        if (vbi->old_ev_cb != NULL) {
                Save_SvREFCNT_dec(vbi->old_ev_cb);
                Save_SvREFCNT_dec(vbi->old_ev_user_data);
                vbi->old_ev_cb = NULL;
                vbi->old_ev_user_data = NULL;
        }
        vbi_event_handler_remove(vbi->ctx, zvbi_xs_vt_event_handler_old);

vbi_bool
event_handler_register(vbi, event_mask, handler, user_data=NULL)
        VbiVtObj * vbi
        int event_mask
        CV * handler
        SV * user_data
        PREINIT:
        dMY_CXT;
        unsigned cb_idx;
        CODE:
        zvbi_xs_free_callback_by_ptr(MY_CXT.event, vbi, (SV*)handler, user_data, TRUE);
        cb_idx = zvbi_xs_alloc_callback(MY_CXT.event, (SV*)handler, user_data, vbi);
        if (cb_idx < ZVBI_MAX_CB_COUNT) {
                RETVAL = vbi_event_handler_register(vbi->ctx, event_mask,
                                                    zvbi_xs_vt_event_handler,
                                                    UINT2PVOID(cb_idx));
                if (RETVAL == FALSE) {
                        zvbi_xs_free_callback_by_idx(MY_CXT.event, cb_idx);
                }
        } else {
                RETVAL = FALSE;
        }
        OUTPUT:
        RETVAL

void
event_handler_unregister(vbi, handler, user_data=NULL)
        VbiVtObj * vbi
        CV * handler
        SV * user_data
        PREINIT:
        dMY_CXT;
        unsigned cb_idx;
        CODE:
        cb_idx = zvbi_xs_free_callback_by_ptr(MY_CXT.event, vbi, (SV*)handler, user_data, TRUE);
        vbi_event_handler_unregister(vbi->ctx, zvbi_xs_vt_event_handler, UINT2PVOID(cb_idx));


 # ---------------------------------------------------------------------------
 #  Rendering
 # ---------------------------------------------------------------------------

MODULE = Video::ZVBI	PACKAGE = Video::ZVBI::page

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
unref_page(pg_obj)
        SV * pg_obj
        CODE:
        if (SvROK(pg_obj)) {
                sv_unref(pg_obj);
        } else {
                croak("Operand is not a reference");
        }

SV *
draw_vt_page(pg_obj, fmt=VBI_PIXFMT_RGBA32_LE, reveal=0, flash_on=0)
        VbiPageObj * pg_obj
        vbi_pixfmt fmt
        int reveal
        int flash_on
        PREINIT:
        int canvas_size;
        int canvas_type;
        char * p_buf;
        int rowstride;
        CODE:
        RETVAL = newSVpvn("", 0);
        canvas_type = GET_CANVAS_TYPE(fmt);  /* prior to 0.2.26 only RGBA is supported */
        rowstride = pg_obj->p_pg->columns * DRAW_TTX_CELL_WIDTH * canvas_type;
        canvas_size = rowstride * pg_obj->p_pg->rows * DRAW_TTX_CELL_HEIGHT;
        p_buf = zvbi_xs_sv_canvas_prep(RETVAL, canvas_size, 1);
        vbi_draw_vt_page_region(pg_obj->p_pg, fmt, p_buf, rowstride,
                                0, 0, pg_obj->p_pg->columns, pg_obj->p_pg->rows,
                                reveal, flash_on);
        OUTPUT:
        RETVAL

void
draw_vt_page_region(pg_obj, fmt, canvas, img_pix_width, col_pix_off, row_pix_off, column, row, width, height, reveal=0, flash_on=0)
        VbiPageObj * pg_obj
        vbi_pixfmt fmt
        SV * canvas
        int img_pix_width
        int col_pix_off
        int row_pix_off
        int column
        int row
        int width
        int height
        int reveal
        int flash_on
        PREINIT:
        int canvas_size;
        int canvas_type;
        char * p_buf;
        CODE:
        if (img_pix_width < 0) {
                img_pix_width = pg_obj->p_pg->columns * DRAW_TTX_CELL_WIDTH;
        }
        if ((width > 0) && (height > 0) &&
            (column + width <= pg_obj->p_pg->columns) &&
            (row + height <= pg_obj->p_pg->rows) &&
            (col_pix_off >= 0) && (row_pix_off >= 0) &&
            (img_pix_width >= (col_pix_off + (width * DRAW_TTX_CELL_WIDTH)))) {

                canvas_type = GET_CANVAS_TYPE(fmt);  /* prior to 0.2.26 only RGBA is supported */
                canvas_size = img_pix_width * (row_pix_off + height * DRAW_TTX_CELL_HEIGHT) * canvas_type;
                p_buf = zvbi_xs_sv_canvas_prep(canvas, canvas_size, 0);
                vbi_draw_vt_page_region(pg_obj->p_pg, fmt,
                                        p_buf + (row_pix_off * img_pix_width * canvas_type) + col_pix_off,
                                        img_pix_width * canvas_type,
                                        column, row, width, height, reveal, flash_on);
        } else {
                croak("invalid width %d or height %d for image width %d and page geometry %dx%d",
                      width, height, img_pix_width, pg_obj->p_pg->columns, pg_obj->p_pg->rows);
        }
        OUTPUT:
        canvas

SV *
draw_cc_page(pg_obj, fmt=VBI_PIXFMT_RGBA32_LE)
        VbiPageObj * pg_obj
        vbi_pixfmt fmt
        PREINIT:
        int canvas_size;
        int canvas_type;
        int rowstride;
        char * p_buf;
        CODE:
        RETVAL = newSVpvn("", 0);
        canvas_type = GET_CANVAS_TYPE(fmt);  /* prior to 0.2.26 only RGBA is supported */
        rowstride = pg_obj->p_pg->columns * DRAW_CC_CELL_WIDTH * canvas_type;
        canvas_size = rowstride * pg_obj->p_pg->rows * DRAW_CC_CELL_HEIGHT;
        p_buf = zvbi_xs_sv_canvas_prep(RETVAL, canvas_size, 1);
        vbi_draw_cc_page_region(pg_obj->p_pg, fmt, p_buf, rowstride,
                                0, 0, pg_obj->p_pg->columns, pg_obj->p_pg->rows);
        OUTPUT:
        RETVAL

void
draw_cc_page_region(pg_obj, fmt, canvas, img_pix_width, column, row, width, height)
        VbiPageObj * pg_obj
        vbi_pixfmt fmt
        SV * canvas
        int img_pix_width
        int column
        int row
        int width
        int height
        PREINIT:
        int canvas_size;
        int canvas_type;
        char * p_buf;
        CODE:
        if (img_pix_width < 0) {
                img_pix_width = pg_obj->p_pg->columns * DRAW_CC_CELL_WIDTH;
        }
        if ((width > 0) && (height > 0) &&
            (column + width <= pg_obj->p_pg->columns) &&
            (row + height <= pg_obj->p_pg->rows) &&
            (img_pix_width >= width * DRAW_CC_CELL_WIDTH)) {

                canvas_type = GET_CANVAS_TYPE(fmt);  /* prior to 0.2.26 only RGBA is supported */
                canvas_size = img_pix_width * height * DRAW_CC_CELL_HEIGHT * canvas_type;
                p_buf = zvbi_xs_sv_canvas_prep(canvas, canvas_size, 0);
                vbi_draw_cc_page_region(pg_obj->p_pg, fmt, p_buf, img_pix_width * canvas_type,
                                        column, row, width, height);
        } else {
                croak("invalid width %d or height %d for img_pix_width %d and page geometry %dx%d",
                      width, height, img_pix_width, pg_obj->p_pg->columns, pg_obj->p_pg->rows);
        }
        OUTPUT:
        canvas

SV *
draw_blank(pg_obj, fmt=VBI_PIXFMT_RGBA32_LE, pix_height=0, img_pix_width=-1)
        VbiPageObj * pg_obj
        vbi_pixfmt fmt
        int pix_height
        int img_pix_width
        PREINIT:
        int canvas_size;
        int canvas_type;
        CODE:
        RETVAL = newSVpvn("", 0);
        if (pix_height <= 0) {
                if (pg_obj->p_pg->pgno <= 8) {
                        pix_height = pg_obj->p_pg->rows * DRAW_CC_CELL_HEIGHT;
                } else {
                        pix_height = pg_obj->p_pg->rows * DRAW_TTX_CELL_HEIGHT;
                }
        }
        if (img_pix_width <= 0) {
                if (pg_obj->p_pg->pgno <= 8) {
                        img_pix_width = pg_obj->p_pg->columns * DRAW_CC_CELL_WIDTH;
                } else {
                        img_pix_width = pg_obj->p_pg->columns * DRAW_TTX_CELL_WIDTH;
                }
        }
        canvas_type = GET_CANVAS_TYPE(fmt);  /* prior to 0.2.26 only RGBA is supported */
        canvas_size = img_pix_width * pix_height * canvas_type;
        zvbi_xs_sv_canvas_prep(RETVAL, canvas_size, 1);
        OUTPUT:
        RETVAL

SV *
canvas_to_xpm(pg_obj, sv_canvas, fmt=VBI_PIXFMT_RGBA32_LE, aspect=1, img_pix_width=-1)
        VbiPageObj * pg_obj
        SV * sv_canvas
        vbi_pixfmt fmt
        vbi_bool aspect;
        int img_pix_width
        PREINIT:
        void * p_img;
        STRLEN buf_size;
        int canvas_type;
        int img_pix_height;
        int scale;
        CODE:
        if (!SvOK(sv_canvas)) {
                croak("Input buffer is undefined or not a scalar");
                XSRETURN_UNDEF;
        }
        p_img = SvPV(sv_canvas, buf_size);
        if (img_pix_width <= 0) {
                if (pg_obj->p_pg->pgno <= 8) {
                        img_pix_width = pg_obj->p_pg->columns * DRAW_CC_CELL_WIDTH;
                } else {
                        img_pix_width = pg_obj->p_pg->columns * DRAW_TTX_CELL_WIDTH;
                }
        }
        if (pg_obj->p_pg->pgno <= 8) {
                scale = aspect ? 1 : 0;  /* CC: is already line-doubled */
        } else {
                scale = aspect ? 2 : 1;  /* TTX: correct aspect ratio by doubling lines in Y dimension */
        }
        canvas_type = GET_CANVAS_TYPE(fmt);  /* prior to 0.2.26 only RGBA is supported */
        if (buf_size % (img_pix_width * canvas_type) != 0) {
                croak("Input buffer size %d doesn't match img_pix_width %d (pixel size %d)",
                      buf_size, img_pix_width, canvas_type);
                XSRETURN_UNDEF;
        }
        img_pix_height = buf_size / (img_pix_width * canvas_type);
        if (fmt == VBI_PIXFMT_RGBA32_LE) {
                RETVAL = zvbi_xs_convert_rgba_to_xpm(pg_obj, p_img, img_pix_width, img_pix_height, scale);
        } else {
                RETVAL = zvbi_xs_convert_pal8_to_xpm(pg_obj, p_img, img_pix_width, img_pix_height, scale);
        }
        OUTPUT:
        RETVAL

void
get_max_rendered_size()
        PPCODE:
        int w, h;
        vbi_get_max_rendered_size(&w, &h);
        EXTEND(sp, 2);
        PUSHs (sv_2mortal (newSVuv (w)));
        PUSHs (sv_2mortal (newSVuv (h)));

void
get_vt_cell_size()
        PPCODE:
        int w, h;
        vbi_get_vt_cell_size(&w, &h);
        EXTEND(sp, 2);
        PUSHs (sv_2mortal (newSVuv (w)));
        PUSHs (sv_2mortal (newSVuv (h)));

int
print_page_region(pg_obj, sv_buf, size, format, table, rtl, column, row, width, height)
        VbiPageObj * pg_obj
        SV * sv_buf
        int size
        const char * format
        vbi_bool table
        vbi_bool rtl
        int column
        int row
        int width
        int height
        PREINIT:
        char * p_buf = zvbi_xs_sv_buffer_prep(sv_buf, size);
        CODE:
        RETVAL = vbi_print_page_region(pg_obj->p_pg, p_buf, size,
                                       format, table, rtl,
                                       column, row, width, height);
        p_buf[RETVAL] = 0;
        SvCUR_set(sv_buf, RETVAL);
        OUTPUT:
        sv_buf
        RETVAL

SV *
print_page(pg_obj, table=0, rtl=0)
        VbiPageObj * pg_obj
        vbi_bool table
        vbi_bool rtl
        PREINIT:
        const int max_size = 40 * 25 * 4;
        int size;
        char * p_buf;
        CODE:
        RETVAL = newSVpvn("", 0);
        p_buf = zvbi_xs_sv_buffer_prep(RETVAL, max_size);
        size = vbi_print_page_region(pg_obj->p_pg, p_buf, max_size,
                                     "UTF-8", table, rtl,
                                     0, 0, pg_obj->p_pg->columns, pg_obj->p_pg->rows);
        if ((size < 0) || (size >= max_size)) {
                size = 0;
        }
        p_buf[size] = 0;
        SvCUR_set(RETVAL, size);
        SvUTF8_on(RETVAL);
        OUTPUT:
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

void
get_page_dirty_range(pg_obj)
        VbiPageObj * pg_obj
        PPCODE:
        EXTEND(sp, 3);
        PUSHs (sv_2mortal (newSViv (pg_obj->p_pg->dirty.y0)));
        PUSHs (sv_2mortal (newSViv (pg_obj->p_pg->dirty.y1)));
        PUSHs (sv_2mortal (newSViv (pg_obj->p_pg->dirty.roll)));

AV *
get_page_color_map(pg_obj)
        VbiPageObj * pg_obj
        PREINIT:
        int idx;
        CODE:
        RETVAL = newAV();
        av_extend(RETVAL, 40);
        sv_2mortal((SV*)RETVAL); /* see man perlxs */
        for (idx = 0; idx < 40; idx++) {
                av_store (RETVAL, idx, newSVuv (pg_obj->p_pg->color_map[idx]));
        }
        OUTPUT:
        RETVAL

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
        U8 * p_str;
        U8 * p;
        vbi_char * t;
        CODE:
        /* convert UCS-2 to UTF-8 */
        size = pg_obj->p_pg->rows * pg_obj->p_pg->columns * 3;
        New(0, p_str, size + UTF8_MAXBYTES+1 + 1, U8);
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
        RETVAL = newSVpvn((char*)p_str, p - p_str);
        SvUTF8_on(RETVAL);
        Safefree(p_str);
        OUTPUT:
        RETVAL

HV *
resolve_link(pg_obj, column, row)
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
resolve_home(pg_obj)
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

MODULE = Video::ZVBI	PACKAGE = Video::ZVBI::export	PREFIX = vbi_export_

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
        vbi_export_info * p_info;
        PPCODE:
        p_info = vbi_export_info_enum(index);
        if (p_info != NULL) {
                HV * hv = zvbi_xs_export_info_to_hv(p_info);
                EXTEND(sp,1);
                PUSHs (sv_2mortal (newRV_noinc ((SV*)hv)));
        }

void
vbi_export_info_keyword(keyword)
        const char * keyword
        PREINIT:
        vbi_export_info * p_info;
        PPCODE:
        p_info = vbi_export_info_keyword(keyword);
        if (p_info != NULL) {
                HV * hv = zvbi_xs_export_info_to_hv(p_info);
                EXTEND(sp,1);
                PUSHs (sv_2mortal (newRV_noinc ((SV*)hv)));
        }

void
vbi_export_info_export(exp)
        VbiExportObj * exp
        PREINIT:
        vbi_export_info * p_info;
        PPCODE:
        p_info = vbi_export_info_export(exp);
        if (p_info != NULL) {
                HV * hv = zvbi_xs_export_info_to_hv(p_info);
                EXTEND(sp,1);
                PUSHs (sv_2mortal (newRV_noinc ((SV*)hv)));
        }

void
vbi_export_option_info_enum(exp, index)
        VbiExportObj * exp
        int index
        PREINIT:
        vbi_option_info * p_opt;
        PPCODE:
        p_opt = vbi_export_option_info_enum(exp, index);
        if (p_opt != NULL) {
                HV * hv = zvbi_xs_export_option_info_to_hv(p_opt);
                EXTEND(sp, 1);
                PUSHs (sv_2mortal (newRV_noinc ((SV*)hv)));
        }

void
vbi_export_option_info_keyword(exp, keyword)
        VbiExportObj * exp
        const char *keyword
        PREINIT:
        vbi_option_info * p_opt;
        PPCODE:
        p_opt = vbi_export_option_info_keyword(exp, keyword);
        if (p_opt != NULL) {
                HV * hv = zvbi_xs_export_option_info_to_hv(p_opt);
                EXTEND(sp, 1);
                PUSHs (sv_2mortal (newRV_noinc ((SV*)hv)));
        }

vbi_bool
vbi_export_option_set(exp, keyword, sv)
        VbiExportObj * exp
        const char * keyword
        SV * sv
        PREINIT:
        vbi_option_info * p_info;
        CODE:
        RETVAL = 0;
        p_info = vbi_export_option_info_keyword(exp, keyword);
        if (p_info != NULL) {
                switch (p_info->type) {
                case VBI_OPTION_BOOL:
                case VBI_OPTION_INT:
                case VBI_OPTION_MENU:
                        RETVAL = vbi_export_option_set(exp, keyword, SvIV(sv));
                        break;
                case VBI_OPTION_REAL:
                        RETVAL = vbi_export_option_set(exp, keyword, SvNV(sv));
                        break;
                case VBI_OPTION_STRING:
                        RETVAL = vbi_export_option_set(exp, keyword, SvPV_nolen(sv));
                        break;
                default:
                        break;
                }
        }
        OUTPUT:
        RETVAL

void
vbi_export_option_get(exp, keyword)
        VbiExportObj * exp
        const char * keyword
        PREINIT:
        vbi_option_value opt_val;
        vbi_option_info * p_info;
        PPCODE:
        p_info = vbi_export_option_info_keyword(exp, keyword);
        if (p_info != NULL) {
                if (vbi_export_option_get(exp, keyword, &opt_val)) {
                        switch (p_info->type) {
                        case VBI_OPTION_BOOL:
                        case VBI_OPTION_INT:
                        case VBI_OPTION_MENU:
                                EXTEND(sp, 1);
                                PUSHs (sv_2mortal (newSViv (opt_val.num)));
                                break;
                        case VBI_OPTION_REAL:
                                EXTEND(sp, 1);
                                PUSHs (sv_2mortal (newSVnv (opt_val.dbl)));
                                break;
                        case VBI_OPTION_STRING:
                                EXTEND(sp, 1);
                                PUSHs (sv_2mortal (newSVpv (opt_val.str, 0)));
                                free(opt_val.str);
                                break;
                        default:
                                break;
                        }
                }
        }

vbi_bool
vbi_export_option_menu_set(exp, keyword, entry)
        VbiExportObj * exp
        const char * keyword
        int entry

void
vbi_export_option_menu_get(exp, keyword)
        VbiExportObj * exp
        const char * keyword
        PREINIT:
        int entry;
        PPCODE:
        if (vbi_export_option_menu_get(exp, keyword, &entry)) {
                EXTEND(sp, 1);
                PUSHs (sv_2mortal (newSViv (entry)));
        }

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

int
vbi_export_mem(exp, sv_buf, pg_obj)
        VbiExportObj * exp
        SV * sv_buf
        VbiPageObj * pg_obj
        PREINIT:
        char * p_buf;
        STRLEN buf_size;
        CODE:
#if LIBZVBI_VERSION(0,2,26)
        if (SvOK(sv_buf))  {
                p_buf = SvPV_force(sv_buf, buf_size);
                RETVAL = vbi_export_mem(exp, p_buf, buf_size + 1, pg_obj->p_pg);
        } else {
                croak("Input buffer is undefined or not a scalar");
        }
#else
        CROAK_LIB_VERSION(0,2,26)
#endif
        OUTPUT:
        sv_buf
        RETVAL

void
vbi_export_alloc(exp, pg_obj)
        VbiExportObj * exp
        VbiPageObj * pg_obj
        PREINIT:
        char * p_buf;
        size_t buf_size;
        SV * sv;
        PPCODE:
#if LIBZVBI_VERSION(0,2,26)
        if (vbi_export_alloc(exp, (void**)&p_buf, &buf_size, pg_obj->p_pg)) {
                sv = newSV(0);
                sv_usepvn(sv, p_buf, buf_size);
                /* now the pointer is managed by perl -> no free() */
                EXTEND(sp, 1);
                PUSHs (sv_2mortal (sv));
        }
#else
        CROAK_LIB_VERSION(0,2,26);
#endif

char *
vbi_export_errstr(exp)
        VbiExportObj * exp


 # ---------------------------------------------------------------------------
 #  Search
 # ---------------------------------------------------------------------------

MODULE = Video::ZVBI	PACKAGE = Video::ZVBI::search	PREFIX = vbi_search_

VbiSearchObj *
vbi_search_new(vbi, pgno, subno, sv_pattern, casefold=0, regexp=0, progress=NULL, user_data=NULL)
        VbiVtObj * vbi
        vbi_pgno pgno
        vbi_subno subno
        SV * sv_pattern
        vbi_bool casefold
        vbi_bool regexp
        CV * progress
        SV * user_data
        PREINIT:
        dMY_CXT;
        uint16_t * p_ucs;
        uint16_t * p;
        char * p_utf;
        STRLEN len;
        int rest;
        unsigned cb_idx;
        CODE:
        /* convert pattern string from Perl's utf8 into UCS-2 */
        p_utf = SvPVutf8_force(sv_pattern, len);
        New(0, p_ucs, len * 2 + 2, uint16_t);
        p = p_ucs;
        rest = len;
        while (rest > 0) {
                *(p++) = utf8_to_uvchr((U8*)p_utf, &len);
                if (len > 0) {
                        p_utf += len;
                        rest -= len;
                } else {
                        break;
                }
        }
        *p = 0;
        if (progress == NULL) {
                RETVAL = vbi_search_new(vbi->ctx, pgno, subno, p_ucs, casefold, regexp, NULL);
        } else {
                cb_idx = zvbi_xs_alloc_callback(MY_CXT.search, (SV*)progress, user_data, NULL);
                if (cb_idx < ZVBI_MAX_CB_COUNT) {
                        RETVAL = vbi_search_new(vbi->ctx, pgno, subno, p_ucs, casefold, regexp,
                                                zvbi_xs_search_cb_list[cb_idx]);

                        if (RETVAL != NULL) {
                                MY_CXT.search[cb_idx].p_obj = RETVAL;
                        } else {
                                zvbi_xs_free_callback_by_idx(MY_CXT.search, cb_idx);
                        }
                } else {
                        croak ("Max. search callback count exceeded");
                }
        }
        Safefree(p_ucs);
        OUTPUT:
        RETVAL

void
DESTROY(search)
        VbiSearchObj * search
        PREINIT:
        dMY_CXT;
        CODE:
        vbi_search_delete(search);
        zvbi_xs_free_callback_by_obj(MY_CXT.search, search);

int
vbi_search_next(search, pg_obj, dir)
        VbiSearchObj * search
        VbiPageObj * &pg_obj = NO_INIT
        int dir
        CODE:
        Newz(0, pg_obj, 1, VbiPageObj);
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

MODULE = Video::ZVBI	PACKAGE = Video::ZVBI	PREFIX = vbi_

unsigned int
vbi_par8(val)
        unsigned int val

int
vbi_unpar8(val)
        unsigned int val

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
vbi_rev8(val)
        unsigned int val

unsigned int
vbi_rev16(val)
        unsigned int val

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
vbi_ham8(val)
        unsigned int val

int
vbi_unham8(val)
        unsigned int val

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
 #  BCD arithmetic
 # ---------------------------------------------------------------------------

int
vbi_dec2bcd(dec)
        unsigned int dec

unsigned int
vbi_bcd2dec(bcd)
        unsigned int bcd

unsigned int
vbi_add_bcd(a, b)
   unsigned int a
   unsigned int b

vbi_bool
vbi_is_bcd(bcd)
        unsigned int bcd

 # ---------------------------------------------------------------------------
 #  Miscellaneous
 # ---------------------------------------------------------------------------

MODULE = Video::ZVBI	PACKAGE = Video::ZVBI

void
lib_version()
        PPCODE:
        EXTEND(sp, 3);
        PUSHs (sv_2mortal (newSVuv (VBI_VERSION_MAJOR)));
        PUSHs (sv_2mortal (newSVuv (VBI_VERSION_MINOR)));
        PUSHs (sv_2mortal (newSVuv (VBI_VERSION_MICRO)));

vbi_bool
check_lib_version(major,minor,micro)
        int major
        int minor
        int micro
        CODE:
        RETVAL = LIBZVBI_VERSION(major,minor,micro);
        OUTPUT:
        RETVAL

void
set_log_fn(mask, log_fn=NULL, user_data=NULL)
        unsigned int mask
        CV * log_fn
        SV * user_data
        PREINIT:
        dMY_CXT;
        unsigned cb_idx;
        CODE:
#if LIBZVBI_VERSION(0,2,22)
        zvbi_xs_free_callback_by_obj(MY_CXT.log, NULL);
        if (log_fn != NULL) {
                cb_idx = zvbi_xs_alloc_callback(MY_CXT.log, (SV*)log_fn, user_data, NULL);
                if (cb_idx < ZVBI_MAX_CB_COUNT) {
                        vbi_set_log_fn(mask, zvbi_xs_log_callback, UINT2PVOID(cb_idx));
                } else {
                        vbi_set_log_fn(mask, NULL, NULL);
                        croak ("Max. log callback count exceeded");
                }
        } else {
                vbi_set_log_fn(mask, NULL, NULL);
        }
#else
        CROAK_LIB_VERSION(0,2,22);
#endif

void
set_log_on_stderr(mask)
        unsigned int mask
        PREINIT:
        dMY_CXT;
        CODE:
#if LIBZVBI_VERSION(0,2,22)
        zvbi_xs_free_callback_by_obj(MY_CXT.log, NULL);
        vbi_set_log_fn(mask, vbi_log_on_stderr, NULL);
#else
        CROAK_LIB_VERSION(0,2,22);
#endif

void
decode_vps_cni(data)
        SV * data
        PPCODE:
#if LIBZVBI_VERSION(0,2,20)
        unsigned int cni;
        unsigned char *p;
        STRLEN len;
        p = (unsigned char *)SvPV (data, len);
        if (len >= 13) {
                if (vbi_decode_vps_cni(&cni, p)) {
                        EXTEND(sp,1);
                        PUSHs (sv_2mortal (newSVuv (cni)));
                }
        } else {
                croak ("decode_vps_cni: input buffer must have at least 13 bytes");
        }
#else
        CROAK_LIB_VERSION(0,2,20);
#endif

void
encode_vps_cni(cni)
        unsigned int cni
        PREINIT:
        uint8_t buffer[13];
        PPCODE:
#if LIBZVBI_VERSION(0,2,20)
        if (vbi_encode_vps_cni(buffer, cni)) {
                EXTEND(sp,1);
                PUSHs (sv_2mortal (newSVpvn ((char*)buffer, 13)));
        }
#else
        CROAK_LIB_VERSION(0,2,20);
#endif

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

void
iconv_caption(sv_src, repl_char=0)
        SV * sv_src
        int repl_char
        PREINIT:
        char * p_src;
        char * p_buf;
        STRLEN src_len;
        SV * sv;
        PPCODE:
#if LIBZVBI_VERSION(0,2,23)
        p_src = (void *) SvPV(sv_src, src_len);
        p_buf = vbi_strndup_iconv_caption("UTF-8", p_src, src_len, '?');
        if (p_buf != NULL) {
                sv = newSV(0);
                sv_usepvn(sv, p_buf, strlen(p_buf));
                /* now the pointer is managed by perl -> no free() */
                SvUTF8_on(sv);
                EXTEND(sp, 1);
                PUSHs (sv_2mortal (sv));
        }
#else
        CROAK_LIB_VERSION(0,2,23);
#endif

void
caption_unicode(c, to_upper=0)
        unsigned int c
        vbi_bool to_upper
        PREINIT:
        UV ucs;
        U8 buf[10];
        U8 * p;
        SV * sv;
        PPCODE:
#if LIBZVBI_VERSION(0,2,23)
        ucs = vbi_caption_unicode(c, to_upper);
        if (ucs != 0) {
                p = uvuni_to_utf8(buf, ucs);
                sv = sv_2mortal(newSVpvn(buf, p - buf));
                SvUTF8_on(sv);
        } else {
                sv = sv_2mortal(newSVpvn("", 0));
        }
        EXTEND(sp, 1);
        PUSHs (sv);
#else
        CROAK_LIB_VERSION(0,2,23);
#endif

BOOT:
{
        HV *stash = gv_stashpv("Video::ZVBI", TRUE);
        AV * exports;

        MY_CXT_INIT;

        exports = get_av("Video::ZVBI::EXPORT_OK", 1);
        if (exports == NULL) {
                croak("Failed to create EXPORT_OK array");
                return;
        }
#define EXPORT_XS_CONST(NAME) \
                newCONSTSUB(stash, #NAME, newSViv (NAME)); \
                av_push (exports, newSVpv (#NAME, strlen (#NAME)));

        /* capture interface */
        EXPORT_XS_CONST( VBI_SLICED_NONE );
        EXPORT_XS_CONST( VBI_SLICED_UNKNOWN );
        EXPORT_XS_CONST( VBI_SLICED_ANTIOPE );
        EXPORT_XS_CONST( VBI_SLICED_TELETEXT_A );
        EXPORT_XS_CONST( VBI_SLICED_TELETEXT_B_L10_625 );
        EXPORT_XS_CONST( VBI_SLICED_TELETEXT_B_L25_625 );
        EXPORT_XS_CONST( VBI_SLICED_TELETEXT_B );
        EXPORT_XS_CONST( VBI_SLICED_TELETEXT_B_625 );
        EXPORT_XS_CONST( VBI_SLICED_TELETEXT_C_625 );
        EXPORT_XS_CONST( VBI_SLICED_TELETEXT_D_625 );
        EXPORT_XS_CONST( VBI_SLICED_VPS );
        EXPORT_XS_CONST( VBI_SLICED_VPS_F2 );
        EXPORT_XS_CONST( VBI_SLICED_CAPTION_625_F1 );
        EXPORT_XS_CONST( VBI_SLICED_CAPTION_625_F2 );
        EXPORT_XS_CONST( VBI_SLICED_CAPTION_625 );
        EXPORT_XS_CONST( VBI_SLICED_WSS_625 );
        EXPORT_XS_CONST( VBI_SLICED_CAPTION_525_F1 );
        EXPORT_XS_CONST( VBI_SLICED_CAPTION_525_F2 );
        EXPORT_XS_CONST( VBI_SLICED_CAPTION_525 );
        EXPORT_XS_CONST( VBI_SLICED_2xCAPTION_525 );
        EXPORT_XS_CONST( VBI_SLICED_TELETEXT_B_525 );
        EXPORT_XS_CONST( VBI_SLICED_NABTS );
        EXPORT_XS_CONST( VBI_SLICED_TELETEXT_C_525 );
        EXPORT_XS_CONST( VBI_SLICED_TELETEXT_BD_525 );
        EXPORT_XS_CONST( VBI_SLICED_TELETEXT_D_525 );
        EXPORT_XS_CONST( VBI_SLICED_WSS_CPR1204 );
        EXPORT_XS_CONST( VBI_SLICED_VBI_625 );
        EXPORT_XS_CONST( VBI_SLICED_VBI_525 );

        EXPORT_XS_CONST( VBI_FD_HAS_SELECT );
        EXPORT_XS_CONST( VBI_FD_HAS_MMAP );
        EXPORT_XS_CONST( VBI_FD_IS_DEVICE );

        /* proxy interface */
        EXPORT_XS_CONST( VBI_PROXY_CLIENT_NO_TIMEOUTS );
        EXPORT_XS_CONST( VBI_PROXY_CLIENT_NO_STATUS_IND );

        EXPORT_XS_CONST( VBI_CHN_PRIO_BACKGROUND );
        EXPORT_XS_CONST( VBI_CHN_PRIO_INTERACTIVE );
        EXPORT_XS_CONST( VBI_CHN_PRIO_DEFAULT );
        EXPORT_XS_CONST( VBI_CHN_PRIO_RECORD );

        EXPORT_XS_CONST( VBI_CHN_SUBPRIO_MINIMAL );
        EXPORT_XS_CONST( VBI_CHN_SUBPRIO_CHECK );
        EXPORT_XS_CONST( VBI_CHN_SUBPRIO_UPDATE );
        EXPORT_XS_CONST( VBI_CHN_SUBPRIO_INITIAL );
        EXPORT_XS_CONST( VBI_CHN_SUBPRIO_VPS_PDC );

        EXPORT_XS_CONST( VBI_PROXY_CHN_RELEASE );
        EXPORT_XS_CONST( VBI_PROXY_CHN_TOKEN );
        EXPORT_XS_CONST( VBI_PROXY_CHN_FLUSH );
        EXPORT_XS_CONST( VBI_PROXY_CHN_NORM );
        EXPORT_XS_CONST( VBI_PROXY_CHN_FAIL );
        EXPORT_XS_CONST( VBI_PROXY_CHN_NONE );

        EXPORT_XS_CONST( VBI_API_UNKNOWN );
        EXPORT_XS_CONST( VBI_API_V4L1 );
        EXPORT_XS_CONST( VBI_API_V4L2 );
        EXPORT_XS_CONST( VBI_API_BKTR );

        EXPORT_XS_CONST( VBI_PROXY_EV_CHN_GRANTED );
        EXPORT_XS_CONST( VBI_PROXY_EV_CHN_CHANGED );
        EXPORT_XS_CONST( VBI_PROXY_EV_NORM_CHANGED );
        EXPORT_XS_CONST( VBI_PROXY_EV_CHN_RECLAIMED );
        EXPORT_XS_CONST( VBI_PROXY_EV_NONE );

        /* demux */
        EXPORT_XS_CONST( VBI_IDL_DATA_LOST );
        EXPORT_XS_CONST( VBI_IDL_DEPENDENT );

        /* vt object */
        EXPORT_XS_CONST( VBI_EVENT_NONE );
        EXPORT_XS_CONST( VBI_EVENT_CLOSE );
        EXPORT_XS_CONST( VBI_EVENT_TTX_PAGE );
        EXPORT_XS_CONST( VBI_EVENT_CAPTION );
        EXPORT_XS_CONST( VBI_EVENT_NETWORK );
        EXPORT_XS_CONST( VBI_EVENT_TRIGGER );
        EXPORT_XS_CONST( VBI_EVENT_ASPECT );
        EXPORT_XS_CONST( VBI_EVENT_PROG_INFO );
#ifdef VBI_EVENT_NETWORK_ID
        EXPORT_XS_CONST( VBI_EVENT_NETWORK_ID );
#endif

        EXPORT_XS_CONST( VBI_WST_LEVEL_1 );
        EXPORT_XS_CONST( VBI_WST_LEVEL_1p5 );
        EXPORT_XS_CONST( VBI_WST_LEVEL_2p5 );
        EXPORT_XS_CONST( VBI_WST_LEVEL_3p5 );

        /* VT pages */
        EXPORT_XS_CONST( VBI_LINK_NONE );
        EXPORT_XS_CONST( VBI_LINK_MESSAGE );
        EXPORT_XS_CONST( VBI_LINK_PAGE );
        EXPORT_XS_CONST( VBI_LINK_SUBPAGE );
        EXPORT_XS_CONST( VBI_LINK_HTTP );
        EXPORT_XS_CONST( VBI_LINK_FTP );
        EXPORT_XS_CONST( VBI_LINK_EMAIL );
        EXPORT_XS_CONST( VBI_LINK_LID );
        EXPORT_XS_CONST( VBI_LINK_TELEWEB );

        EXPORT_XS_CONST( VBI_WEBLINK_UNKNOWN );
        EXPORT_XS_CONST( VBI_WEBLINK_PROGRAM_RELATED );
        EXPORT_XS_CONST( VBI_WEBLINK_NETWORK_RELATED );
        EXPORT_XS_CONST( VBI_WEBLINK_STATION_RELATED );
        EXPORT_XS_CONST( VBI_WEBLINK_SPONSOR_MESSAGE );
        EXPORT_XS_CONST( VBI_WEBLINK_OPERATOR );

        EXPORT_XS_CONST( VBI_SUBT_NONE );
        EXPORT_XS_CONST( VBI_SUBT_ACTIVE );
        EXPORT_XS_CONST( VBI_SUBT_MATTE );
        EXPORT_XS_CONST( VBI_SUBT_UNKNOWN );

        EXPORT_XS_CONST( VBI_BLACK );
        EXPORT_XS_CONST( VBI_RED );
        EXPORT_XS_CONST( VBI_GREEN );
        EXPORT_XS_CONST( VBI_YELLOW );
        EXPORT_XS_CONST( VBI_BLUE );
        EXPORT_XS_CONST( VBI_MAGENTA );
        EXPORT_XS_CONST( VBI_CYAN );
        EXPORT_XS_CONST( VBI_WHITE );

        EXPORT_XS_CONST( VBI_TRANSPARENT_SPACE );
        EXPORT_XS_CONST( VBI_TRANSPARENT_FULL );
        EXPORT_XS_CONST( VBI_SEMI_TRANSPARENT );
        EXPORT_XS_CONST( VBI_OPAQUE );

        EXPORT_XS_CONST( VBI_NORMAL_SIZE );
        EXPORT_XS_CONST( VBI_DOUBLE_WIDTH );
        EXPORT_XS_CONST( VBI_DOUBLE_HEIGHT );
        EXPORT_XS_CONST( VBI_DOUBLE_SIZE );
        EXPORT_XS_CONST( VBI_OVER_TOP );
        EXPORT_XS_CONST( VBI_OVER_BOTTOM );
        EXPORT_XS_CONST( VBI_DOUBLE_HEIGHT2 );
        EXPORT_XS_CONST( VBI_DOUBLE_SIZE2 );

        EXPORT_XS_CONST( VBI_NO_PAGE );
        EXPORT_XS_CONST( VBI_NORMAL_PAGE );
        EXPORT_XS_CONST( VBI_SUBTITLE_PAGE );
        EXPORT_XS_CONST( VBI_SUBTITLE_INDEX );
        EXPORT_XS_CONST( VBI_NONSTD_SUBPAGES );
        EXPORT_XS_CONST( VBI_PROGR_WARNING );
        EXPORT_XS_CONST( VBI_CURRENT_PROGR );
        EXPORT_XS_CONST( VBI_NOW_AND_NEXT );
        EXPORT_XS_CONST( VBI_PROGR_INDEX );
        EXPORT_XS_CONST( VBI_PROGR_SCHEDULE );
        EXPORT_XS_CONST( VBI_UNKNOWN_PAGE );

        /* search */
        EXPORT_XS_CONST( VBI_ANY_SUBNO );
        EXPORT_XS_CONST( VBI_SEARCH_ERROR );
        EXPORT_XS_CONST( VBI_SEARCH_CACHE_EMPTY );
        EXPORT_XS_CONST( VBI_SEARCH_CANCELED );
        EXPORT_XS_CONST( VBI_SEARCH_NOT_FOUND );
        EXPORT_XS_CONST( VBI_SEARCH_SUCCESS );

        /* export */
        EXPORT_XS_CONST( VBI_PIXFMT_RGBA32_LE );
        EXPORT_XS_CONST( VBI_PIXFMT_YUV420 );
#if LIBZVBI_VERSION(0,2,26)
        EXPORT_XS_CONST( VBI_PIXFMT_PAL8 );
#endif

        EXPORT_XS_CONST( VBI_OPTION_BOOL );
        EXPORT_XS_CONST( VBI_OPTION_INT );
        EXPORT_XS_CONST( VBI_OPTION_REAL );
        EXPORT_XS_CONST( VBI_OPTION_STRING );
        EXPORT_XS_CONST( VBI_OPTION_MENU );

        /* logging */
#if LIBZVBI_VERSION(0,2,22)
        EXPORT_XS_CONST( VBI_LOG_ERROR );
        EXPORT_XS_CONST( VBI_LOG_WARNING );
        EXPORT_XS_CONST( VBI_LOG_NOTICE );
        EXPORT_XS_CONST( VBI_LOG_INFO );
        EXPORT_XS_CONST( VBI_LOG_DEBUG );
        EXPORT_XS_CONST( VBI_LOG_DRIVER );
        EXPORT_XS_CONST( VBI_LOG_DEBUG2 );
        EXPORT_XS_CONST( VBI_LOG_DEBUG3 );
#endif
}
