
 # ---------------------------------------------------------------------------
 #  DVB demux
 # ---------------------------------------------------------------------------

MODULE = Video::Capture::ZVBI	PACKAGE = Video::Capture::ZVBI::DVB	PREFIX = vbi_dvb_

VbiDvbDemuxObj *
vbi_dvb_pes_demux_new(callback, user_data=NULL)
        vbi_dvb_demux_cb *     callback
        void *                 user_data

void
DESTROY(dx)
        VbiDvbDemuxObj * dx
        CODE:
        vbi_dvb_demux_delete(dx);

typedef vbi_bool
vbi_dvb_demux_cb                (vbi_dvb_demux *        dx,
                                 void *                 user_data,
                                 const vbi_sliced *     sliced,
                                 unsigned int           sliced_lines,
                                 int64_t                pts);

void
vbi_dvb_demux_reset(dx)
        VbiDvbDemuxObj * dx

unsigned int
vbi_dvb_demux_cor(dx, sliced, sliced_lines, pts buffer, buffer_left)
        VbiDvbDemuxObj *        dx
        vbi_sliced *            sliced
        unsigned int            sliced_lines
        int64_t *               pts
        const uint8_t **        buffer
        unsigned int *          buffer_left

vbi_bool
vbi_dvb_demux_feed(dx, buffer, buffer_size)
        VbiDvbDemuxObj *        dx
        const uint8_t *         buffer
        unsigned int            buffer_size

void
vbi_dvb_demux_set_log_fn(dx, mask, log_fn, user_data)
        VbiDvbDemuxObj *        dx
        vbi_log_mask            mask
        vbi_log_fn *            log_fn
        void *                  user_data

