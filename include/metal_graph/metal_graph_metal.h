#ifndef METAL_GRAPH_METAL_GRAPH_METAL_H
#define METAL_GRAPH_METAL_GRAPH_METAL_H

#import <Metal/Metal.h>

#include "metal_graph/metal_graph.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef enum mg_metal_buffer_access {
    MG_METAL_BUFFER_ACCESS_READ = 1,
    MG_METAL_BUFFER_ACCESS_WRITE = 2,
    MG_METAL_BUFFER_ACCESS_READ_WRITE = 3
} mg_metal_buffer_access_t;

typedef enum mg_metal_buffer_wrap_flags {
    MG_METAL_BUFFER_WRAP_NONE = 0,
    MG_METAL_BUFFER_WRAP_RETAIN_BUFFER = 1u << 0,
    MG_METAL_BUFFER_WRAP_RETAIN_OWNER = 1u << 1,
    MG_METAL_BUFFER_WRAP_HOST_VISIBLE = 1u << 2,
    MG_METAL_BUFFER_WRAP_MUTABLE = 1u << 3
} mg_metal_buffer_wrap_flags_t;

typedef struct mg_metal_buffer_wrap_desc {
    size_t size;
    __unsafe_unretained id<MTLBuffer> buffer;
    size_t byte_offset;
    size_t byte_length;
    mg_metal_buffer_access_t access;
    uint32_t flags;
    void *owner_context;
    void (*owner_retain)(void *owner_context);
    void (*owner_release)(void *owner_context);
    const char *label;
} mg_metal_buffer_wrap_desc_t;

MG_API mg_status_t mgMetalBufferWrap(mg_device_t *device,
                                     const mg_metal_buffer_wrap_desc_t *desc,
                                     mg_buffer_t **out_buffer, mg_error_t **out_error);

#ifdef __cplusplus
}
#endif

#endif
