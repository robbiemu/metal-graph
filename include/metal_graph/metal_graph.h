#ifndef METAL_GRAPH_METAL_GRAPH_H
#define METAL_GRAPH_METAL_GRAPH_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define MG_VERSION_MAJOR 0
#define MG_VERSION_MINOR 1
#define MG_VERSION_PATCH 0

#if defined(_WIN32)
#if defined(MG_BUILD_SHARED)
#define MG_API __declspec(dllexport)
#elif defined(MG_USE_SHARED)
#define MG_API __declspec(dllimport)
#else
#define MG_API
#endif
#else
#define MG_API __attribute__((visibility("default")))
#endif

typedef struct mg_device mg_device_t;
typedef struct mg_stream mg_stream_t;
typedef struct mg_graph mg_graph_t;
typedef struct mg_graph_exec mg_graph_exec_t;
typedef struct mg_launch mg_launch_t;
typedef struct mg_node mg_node_t;
typedef struct mg_buffer mg_buffer_t;
typedef struct mg_event mg_event_t;
typedef struct mg_error mg_error_t;

typedef uint64_t mg_node_id_t;

#define MG_NODE_ID_INVALID UINT64_MAX

typedef enum mg_status {
    MG_STATUS_OK = 0,
    MG_STATUS_INVALID_ARGUMENT = 1,
    MG_STATUS_INVALID_TOPOLOGY = 2,
    MG_STATUS_UNSUPPORTED = 3,
    MG_STATUS_OUT_OF_MEMORY = 4,
    MG_STATUS_BACKEND_ERROR = 5,
    MG_STATUS_INTERNAL_ERROR = 6
} mg_status_t;

typedef enum mg_error_stage {
    MG_ERROR_STAGE_NONE = 0,
    MG_ERROR_STAGE_CREATE = 1,
    MG_ERROR_STAGE_VALIDATE = 2,
    MG_ERROR_STAGE_INSTANTIATE = 3,
    MG_ERROR_STAGE_ENCODE = 4,
    MG_ERROR_STAGE_COMMIT = 5,
    MG_ERROR_STAGE_COMPLETE = 6,
    MG_ERROR_STAGE_SYNC = 7
} mg_error_stage_t;

typedef enum mg_node_kind {
    MG_NODE_DISPATCH = 1,
    MG_NODE_COPY = 2,
    MG_NODE_FILL = 3,
    MG_NODE_EVENT_WAIT = 4,
    MG_NODE_EVENT_SIGNAL = 5,
    MG_NODE_BARRIER = 6
} mg_node_kind_t;

typedef struct mg_version {
    uint32_t major;
    uint32_t minor;
    uint32_t patch;
} mg_version_t;

typedef struct mg_buffer_binding {
    uint32_t index;
    mg_buffer_t *buffer;
    size_t offset;
} mg_buffer_binding_t;

typedef struct mg_dispatch_desc {
    size_t size;
    const char *metallib_path;
    const char *kernel_name;
    uint32_t grid_size[3];
    uint32_t threads_per_threadgroup[3];
    const mg_buffer_binding_t *buffers;
    uint32_t buffer_count;
} mg_dispatch_desc_t;

/*
 * Copy node descriptor. src/dst must be non-NULL, byte_count must be nonzero, and both
 * [offset, offset + byte_count) ranges must fit inside their buffers. The graph retains buffers
 * during graph construction; GraphExec retains its own snapshot after instantiation.
 */
typedef struct mg_copy_desc {
    size_t size;
    mg_buffer_t *src;
    size_t src_offset;
    mg_buffer_t *dst;
    size_t dst_offset;
    size_t byte_count;
} mg_copy_desc_t;

/*
 * Fill node descriptor. Phase 1 supports an 8-bit repeated fill value. dst must be non-NULL,
 * byte_count must be nonzero, and [dst_offset, dst_offset + byte_count) must fit inside dst.
 * Fill nodes are graph-owned and are not patchable in Phase 1.
 */
typedef struct mg_fill_desc {
    size_t size;
    mg_buffer_t *dst;
    size_t dst_offset;
    size_t byte_count;
    uint8_t value;
} mg_fill_desc_t;

MG_API mg_version_t mg_version(void);
MG_API const char *mg_version_string(void);
MG_API const char *mg_status_string(mg_status_t status);

/* Errors returned through out_error are owned by the caller. Destroy with mg_error_destroy. */
MG_API void mg_error_destroy(mg_error_t *error);
MG_API mg_status_t mg_error_status(const mg_error_t *error);
MG_API mg_error_stage_t mg_error_stage(const mg_error_t *error);
MG_API mg_node_id_t mg_error_node_id(const mg_error_t *error);
MG_API const char *mg_error_message(const mg_error_t *error);
MG_API const char *mg_error_backend_message(const mg_error_t *error);

/* Creates a device handle for the system default Metal device. Destroy with mg_device_destroy. */
MG_API mg_status_t mg_device_create_system_default(mg_device_t **out_device,
                                                   mg_error_t **out_error);
MG_API void mg_device_destroy(mg_device_t *device);

/* Creates a stream backed by a Metal command queue. Destroy with mg_stream_destroy. */
MG_API mg_status_t mg_stream_create(mg_device_t *device, mg_stream_t **out_stream,
                                    mg_error_t **out_error);
MG_API void mg_stream_destroy(mg_stream_t *stream);

/* Creates a shared, host-visible buffer. Destroy with mg_buffer_destroy. */
MG_API mg_status_t mg_buffer_create_shared(mg_device_t *device, size_t length,
                                           mg_buffer_t **out_buffer, mg_error_t **out_error);
MG_API void mg_buffer_destroy(mg_buffer_t *buffer);
MG_API size_t mg_buffer_length(const mg_buffer_t *buffer);
MG_API void *mg_buffer_contents(mg_buffer_t *buffer);

/*
 * Creates a caller-owned timeline event.
 *
 * On Apple platforms this is backed by MTLSharedEvent. The event should outlive graph node
 * creation; instantiated GraphExec objects retain events they need for relaunch and in-flight
 * launches. Timeline wait/signal values are explicit uint64_t values. Destroy with
 * mg_event_destroy. Unsupported backends return MG_STATUS_UNSUPPORTED.
 */
MG_API mg_status_t mg_event_create(mg_device_t *device, mg_event_t **out_event,
                                   mg_error_t **out_error);
MG_API void mg_event_destroy(mg_event_t *event);
MG_API mg_status_t mgEventCreate(mg_device_t *device, mg_event_t **out_event,
                                 mg_error_t **out_error);
MG_API void mgEventDestroy(mg_event_t *event);

/* Creates a mutable graph. Destroy with mg_graph_destroy. */
MG_API mg_status_t mg_graph_create(mg_graph_t **out_graph, mg_error_t **out_error);
MG_API void mg_graph_destroy(mg_graph_t *graph);

/*
 * Nodes are owned by their parent graph and are invalid after mg_graph_destroy.
 * Phase 1 nodes are not patchable; instantiate a new graph exec to change node parameters.
 */
MG_API mg_status_t mg_graph_add_dispatch_node(mg_graph_t *graph, const mg_dispatch_desc_t *desc,
                                              mg_node_t **out_node, mg_error_t **out_error);
/* Adds a graph-owned copy node. Parameters are frozen at instantiation and not patchable. */
MG_API mg_status_t mg_graph_add_copy_node(mg_graph_t *graph, const mg_copy_desc_t *desc,
                                          mg_node_t **out_node, mg_error_t **out_error);
MG_API mg_status_t mgGraphAddCopyNode(mg_graph_t *graph, const mg_copy_desc_t *desc,
                                      mg_node_t **out_node, mg_error_t **out_error);
/* Adds a graph-owned 8-bit fill node. Parameters are frozen at instantiation and not patchable. */
MG_API mg_status_t mg_graph_add_fill_node(mg_graph_t *graph, const mg_fill_desc_t *desc,
                                          mg_node_t **out_node, mg_error_t **out_error);
MG_API mg_status_t mgGraphAddFillNode(mg_graph_t *graph, const mg_fill_desc_t *desc,
                                      mg_node_t **out_node, mg_error_t **out_error);
/* Adds a graph-owned timeline wait node for event >= value. Not patchable in Phase 1. */
MG_API mg_status_t mg_graph_add_event_wait_node(mg_graph_t *graph, mg_event_t *event,
                                                uint64_t value, mg_node_t **out_node,
                                                mg_error_t **out_error);
MG_API mg_status_t mgGraphAddEventWaitNode(mg_graph_t *graph, mg_event_t *event, uint64_t value,
                                           mg_node_t **out_node, mg_error_t **out_error);
/* Adds a graph-owned timeline signal node for event = value. Not patchable in Phase 1. */
MG_API mg_status_t mg_graph_add_event_signal_node(mg_graph_t *graph, mg_event_t *event,
                                                  uint64_t value, mg_node_t **out_node,
                                                  mg_error_t **out_error);
MG_API mg_status_t mgGraphAddEventSignalNode(mg_graph_t *graph, mg_event_t *event, uint64_t value,
                                             mg_node_t **out_node, mg_error_t **out_error);
/*
 * Adds a graph-owned conservative barrier node. In Phase 1 this is an ordering node for the
 * single-queue graph plan; it does not expose or require a public fence object.
 */
MG_API mg_status_t mg_graph_add_barrier_node(mg_graph_t *graph, mg_node_t **out_node,
                                             mg_error_t **out_error);
MG_API mg_status_t mgGraphAddBarrierNode(mg_graph_t *graph, mg_node_t **out_node,
                                         mg_error_t **out_error);
MG_API mg_node_id_t mg_node_id(const mg_node_t *node);
MG_API mg_status_t mg_graph_add_dependency(mg_graph_t *graph, mg_node_t *before, mg_node_t *after,
                                           mg_error_t **out_error);
MG_API mg_status_t mg_graph_validate(const mg_graph_t *graph, mg_error_t **out_error);

/* Instantiates a frozen graph snapshot. The exec may outlive the source graph. */
MG_API mg_status_t mg_graph_instantiate(mg_graph_t *graph, mg_device_t *device,
                                        mg_graph_exec_t **out_exec, mg_error_t **out_error);
MG_API void mg_graph_exec_destroy(mg_graph_exec_t *exec);

/* Launches create fresh command buffers. Launch handles are destroyed with mg_launch_destroy. */
MG_API mg_status_t mg_graph_launch(mg_graph_exec_t *exec, mg_stream_t *stream,
                                   mg_launch_t **out_launch, mg_error_t **out_error);
MG_API mg_status_t mg_launch_synchronize(mg_launch_t *launch, mg_error_t **out_error);
MG_API void mg_launch_destroy(mg_launch_t *launch);

#ifdef __cplusplus
}
#endif

#endif
