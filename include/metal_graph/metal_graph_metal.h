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
    /* Owner callbacks must be thread-safe. The final owner_release can run on a runtime completion
     * or cleanup thread after handles are destroyed; context and callback code must remain valid. */
    void *owner_context;
    void (*owner_retain)(void *owner_context);
    void (*owner_release)(void *owner_context);
    const char *label;
} mg_metal_buffer_wrap_desc_t;

MG_API mg_status_t mgMetalBufferWrap(mg_device_t *device,
                                     const mg_metal_buffer_wrap_desc_t *desc,
                                     mg_buffer_t **out_buffer, mg_error_t **out_error);

/* Retains a native shared event compatible with device. Shared events are device-neutral:
 * Metal documents a nil native device for cross-device shared events; a conflicting non-nil
 * native device is rejected. The native timeline value is preserved. Graph, exec and launch
 * ownership follows the normal mg_event_t rules.
 * A non-NULL out_event is cleared before any validation failure. No host signal or wait occurs.
 * All event/graph/exec operations require caller-side serialization. */
MG_API mg_status_t mgMetalEventWrap(mg_device_t *device, id<MTLSharedEvent> shared_event,
                                    mg_event_t **out_event, mg_error_t **out_error);

/* Returns the identical native event, borrowed (+0) while the mg_event_t is alive, including
 * references owned by a graph, exec or launch. A non-NULL output is cleared on failure.
 * Under ARC pass an __unsafe_unretained id<MTLSharedEvent> local; assign it to a strong local
 * to keep it beyond wrapper lifetime. Without ARC, explicitly retain/release for that use.
 * The caller owns timeline allocation: use increasing producer epochs. A later consumer may
 * wait on a completed producer's target; a new producer must not reuse that satisfied target.
 * An event signal orders work preceding
 * that signal; it does not establish success/completion of the entire foreign or MG launch.
 * Neither API supplies an MLX asynchronous event interface. */
MG_API mg_status_t mgMetalEventGetSharedEvent(const mg_event_t *event,
                                              id<MTLSharedEvent> __unsafe_unretained *out_event,
                                              mg_error_t **out_error);

#ifdef __cplusplus
}
#endif

#endif
