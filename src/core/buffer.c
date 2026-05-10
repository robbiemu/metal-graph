#include "internal.h"

#include <stdlib.h>
#include <string.h>

void mg_buffer_retain(mg_buffer_t *buffer) {
    if (buffer) {
        buffer->ref_count++;
    }
}

void mg_buffer_release(mg_buffer_t *buffer) {
    if (!buffer) {
        return;
    }

    if (buffer->ref_count > 1) {
        buffer->ref_count--;
        return;
    }

    mg_backend_buffer_destroy(buffer);
    if (buffer->owner_release) {
        buffer->owner_release(buffer->owner_context);
        buffer->owner_release = NULL;
        buffer->owner_context = NULL;
    }
    free(buffer->source_framework);
    free(buffer->fallback_reason);
    free(buffer);
}

void mgBufferDestroy(mg_buffer_t *buffer) { mg_buffer_release(buffer); }

size_t mgBufferLength(const mg_buffer_t *buffer) { return buffer ? buffer->length : 0; }

void *mgBufferContents(mg_buffer_t *buffer) { return mg_backend_buffer_contents(buffer); }

mg_status_t mgBufferGetOriginInfo(const mg_buffer_t *buffer, mg_buffer_origin_info_t *out_info,
                                  mg_error_t **out_error) {
    mg_clear_error(out_error);
    if (!buffer || !out_info || out_info->size < sizeof(*out_info)) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_CREATE,
                            MG_NODE_ID_INVALID, "buffer and origin info output are required", NULL);
    }

    memset(out_info, 0, sizeof(*out_info));
    out_info->size = sizeof(*out_info);
    out_info->origin_kind = buffer->origin_kind ? buffer->origin_kind : MG_BUFFER_ORIGIN_LIBRARY_OWNED;
    out_info->is_zero_copy = buffer->is_zero_copy;
    out_info->is_external = buffer->is_external;
    out_info->is_host_visible = buffer->is_host_visible;
    out_info->is_mutable = buffer->is_mutable;
    out_info->byte_offset = buffer->byte_offset;
    out_info->byte_length = buffer->length;
    out_info->source_framework = buffer->source_framework;
    out_info->fallback_reason = buffer->fallback_reason;
    return MG_STATUS_OK;
}

void mg_event_retain(mg_event_t *event) {
    if (event) {
        event->ref_count++;
    }
}

void mg_event_release(mg_event_t *event) {
    if (!event) {
        return;
    }

    if (event->ref_count > 1) {
        event->ref_count--;
        return;
    }

    mg_backend_event_destroy(event);
    free(event);
}

void mgEventDestroy(mg_event_t *event) { mg_event_release(event); }
