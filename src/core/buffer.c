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

void mg_buffer_destroy(mg_buffer_t *buffer) { mg_buffer_release(buffer); }

size_t mg_buffer_length(const mg_buffer_t *buffer) { return buffer ? buffer->length : 0; }

void *mg_buffer_contents(mg_buffer_t *buffer) { return mg_backend_buffer_contents(buffer); }
