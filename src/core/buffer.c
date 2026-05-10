#include "internal.h"

#include <stdlib.h>

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
    free(buffer);
}

void mgBufferDestroy(mg_buffer_t *buffer) { mg_buffer_release(buffer); }

size_t mgBufferLength(const mg_buffer_t *buffer) { return buffer ? buffer->length : 0; }

void *mgBufferContents(mg_buffer_t *buffer) { return mg_backend_buffer_contents(buffer); }

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
