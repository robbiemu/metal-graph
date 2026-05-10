#ifndef METAL_GRAPH_CORE_INTERNAL_H
#define METAL_GRAPH_CORE_INTERNAL_H

#include "metal_graph/metal_graph.h"

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct mg_edge {
    size_t before;
    size_t after;
} mg_edge_t;

typedef struct mg_dispatch_node {
    char *metallib_path;
    char *kernel_name;
    uint32_t grid_size[3];
    uint32_t threads_per_threadgroup[3];
    uint32_t max_grid_size[3];
    mg_buffer_binding_t *buffers;
    uint32_t buffer_count;
    mg_scalar_binding_t *scalars;
    uint32_t scalar_count;
    mg_dispatch_resource_desc_t *resources;
    uint32_t resource_count;
} mg_dispatch_node_t;

typedef struct mg_copy_node {
    mg_buffer_t *src;
    size_t src_offset;
    mg_buffer_t *dst;
    size_t dst_offset;
    size_t byte_count;
} mg_copy_node_t;

typedef struct mg_fill_node {
    mg_buffer_t *dst;
    size_t dst_offset;
    size_t byte_count;
    uint8_t value;
} mg_fill_node_t;

typedef struct mg_event_node {
    mg_event_t *event;
    uint64_t value;
} mg_event_node_t;

typedef struct mg_workspace_node {
    size_t size;
    size_t alignment;
} mg_workspace_node_t;

typedef struct mg_workspace_desc {
    size_t size;
    size_t byte_count;
    size_t alignment;
} mg_workspace_desc_t;

typedef struct mg_internal_workspace_fill_node {
    size_t size;
    size_t alignment;
    uint8_t value;
    mg_buffer_t *dst;
    size_t dst_offset;
} mg_internal_workspace_fill_node_t;

enum { MG_NODE_INTERNAL_WORKSPACE = 1000, MG_NODE_INTERNAL_WORKSPACE_FILL = 1001 };

struct mg_error {
    mg_status_t status;
    mg_error_stage_t stage;
    mg_node_id_t node_id;
    char *message;
    char *backend_message;
};

struct mg_device {
    void *impl;
};

struct mg_stream {
    void *impl;
};

struct mg_buffer {
    void *impl;
    void *device_impl;
    size_t length;
    uint32_t ref_count;
};

struct mg_event {
    void *impl;
    uint32_t ref_count;
};

struct mg_arena {
    size_t size;
    size_t alignment;
    uint32_t ref_count;
};

struct mg_node {
    mg_graph_t *graph;
    mg_node_id_t id;
    size_t index;
    mg_node_kind_t kind;
    mg_patch_flags_t patch_flags;
    union {
        mg_dispatch_node_t dispatch;
        mg_copy_node_t copy;
        mg_fill_node_t fill;
        mg_event_node_t event;
        mg_workspace_node_t workspace;
        mg_internal_workspace_fill_node_t workspace_fill;
    } as;
};

struct mg_graph {
    mg_node_t **nodes;
    size_t node_count;
    size_t node_capacity;
    mg_edge_t *edges;
    size_t edge_count;
    size_t edge_capacity;
    mg_arena_t *arena;
};

typedef struct mg_exec_dispatch {
    mg_node_id_t id;
    mg_patch_flags_t patch_flags;
    char *metallib_path;
    char *kernel_name;
    uint32_t grid_size[3];
    uint32_t threads_per_threadgroup[3];
    uint32_t max_grid_size[3];
    mg_buffer_binding_t *buffers;
    uint32_t buffer_count;
    mg_scalar_binding_t *scalars;
    uint32_t scalar_count;
    mg_dispatch_resource_desc_t *resources;
    uint32_t resource_count;
    void *pipeline_impl;
} mg_exec_dispatch_t;

typedef struct mg_exec_copy {
    mg_node_id_t id;
    mg_patch_flags_t patch_flags;
    mg_buffer_t *src;
    size_t src_offset;
    mg_buffer_t *dst;
    size_t dst_offset;
    size_t byte_count;
} mg_exec_copy_t;

typedef struct mg_exec_fill {
    mg_node_id_t id;
    mg_patch_flags_t patch_flags;
    mg_buffer_t *dst;
    size_t dst_offset;
    size_t byte_count;
    uint8_t value;
} mg_exec_fill_t;

typedef struct mg_exec_event {
    mg_node_id_t id;
    mg_patch_flags_t patch_flags;
    mg_event_t *event;
    uint64_t value;
} mg_exec_event_t;

typedef struct mg_exec_workspace {
    mg_node_id_t id;
    size_t size;
    size_t alignment;
    size_t offset;
} mg_exec_workspace_t;

typedef struct mg_exec_workspace_fill {
    mg_node_id_t id;
    size_t size;
    size_t alignment;
    size_t offset;
    uint8_t value;
    mg_buffer_t *dst;
    size_t dst_offset;
} mg_exec_workspace_fill_t;

typedef struct mg_exec_node {
    mg_node_kind_t kind;
    union {
        mg_exec_dispatch_t dispatch;
        mg_exec_copy_t copy;
        mg_exec_fill_t fill;
        mg_exec_event_t event;
        mg_node_id_t barrier_id;
        mg_exec_workspace_t workspace;
        mg_exec_workspace_fill_t workspace_fill;
    } as;
} mg_exec_node_t;

typedef struct mg_workspace_record {
    mg_node_id_t node_id;
    size_t size;
    size_t alignment;
    size_t offset;
} mg_workspace_record_t;

typedef struct mg_workspace_plan {
    mg_workspace_record_t *records;
    size_t record_count;
    size_t total_size;
    size_t alignment;
    mg_arena_t *arena;
    void *backend_impl;
} mg_workspace_plan_t;

typedef struct mg_icb_plan {
    mg_optimization_flags_t enabled_flags;
    uint32_t available;
    uint32_t groups_planned;
    uint32_t groups_used;
    uint32_t groups_fallback;
    mg_icb_fallback_reason_t last_fallback_reason;
    void *backend_impl;
    size_t command_count;
} mg_icb_plan_t;

struct mg_graph_exec {
    mg_exec_node_t *nodes;
    size_t node_count;
    void *device_impl;
    mg_workspace_plan_t workspace;
    mg_icb_plan_t icb;
    uint32_t in_flight_count;
};

struct mg_launch {
    void *impl;
    mg_graph_exec_t *exec;
    bool completed;
    mg_buffer_t **retained_buffers;
    size_t retained_buffer_count;
    mg_event_t **retained_events;
    size_t retained_event_count;
    void *retained_workspace_impl;
};

char *mg_strdup(const char *value);
void mg_clear_error(mg_error_t **out_error);
mg_status_t mg_set_error(mg_error_t **out_error, mg_status_t status, mg_error_stage_t stage,
                         mg_node_id_t node_id, const char *message, const char *backend_message);
mg_status_t mg_set_oom(mg_error_t **out_error, mg_error_stage_t stage);

void mg_dispatch_node_clear(mg_dispatch_node_t *dispatch);
void mg_node_clear(mg_node_t *node);
mg_status_t mg_graph_topological_order(const mg_graph_t *graph, size_t *order,
                                       mg_error_t **out_error);
const mg_buffer_binding_t *mg_dispatch_find_buffer_binding(const mg_buffer_binding_t *bindings,
                                                           uint32_t binding_count, uint32_t index);
const mg_dispatch_resource_desc_t *
mg_dispatch_find_resource(const mg_dispatch_resource_desc_t *resources, uint32_t resource_count,
                          uint32_t index);
bool mg_dispatch_resource_range_valid(const mg_dispatch_resource_desc_t *resource,
                                      size_t buffer_length, size_t binding_offset);
bool mg_dispatch_resource_offset_aligned(const mg_dispatch_resource_desc_t *resource,
                                         size_t binding_offset);

void mg_buffer_retain(mg_buffer_t *buffer);
void mg_buffer_release(mg_buffer_t *buffer);
void mg_event_retain(mg_event_t *event);
void mg_event_release(mg_event_t *event);
void mg_arena_retain(mg_arena_t *arena);
void mg_arena_release(mg_arena_t *arena);

bool mg_alignment_valid(size_t alignment);
bool mg_align_up_size(size_t value, size_t alignment, size_t *out_value);
mg_status_t mg_workspace_desc_validate(const mg_workspace_desc_t *desc, mg_error_stage_t stage,
                                       mg_error_t **out_error);
mg_status_t mg_graph_plan_workspace(const mg_graph_t *graph, const size_t *order,
                                    mg_workspace_plan_t *out_plan, mg_error_t **out_error);
void mg_workspace_plan_clear(mg_workspace_plan_t *plan);
mg_status_t mg_workspace_plan_offset_for_node(const mg_workspace_plan_t *plan, mg_node_id_t node_id,
                                              size_t *out_offset, mg_error_t **out_error);

mg_status_t mg_internal_graph_add_workspace_node(mg_graph_t *graph, const mg_workspace_desc_t *desc,
                                                 mg_node_t **out_node, mg_error_t **out_error);
mg_status_t mg_internal_graph_add_workspace_fill_node(mg_graph_t *graph,
                                                      const mg_workspace_desc_t *desc,
                                                      uint8_t value, mg_buffer_t *dst,
                                                      size_t dst_offset, mg_node_t **out_node,
                                                      mg_error_t **out_error);

void mg_backend_device_destroy(mg_device_t *device);
void mg_backend_stream_destroy(mg_stream_t *stream);
void mg_backend_buffer_destroy(mg_buffer_t *buffer);
void mg_backend_event_destroy(mg_event_t *event);
void mg_backend_graph_exec_destroy(mg_graph_exec_t *exec);
void mg_backend_launch_destroy(mg_launch_t *launch);
void *mg_backend_buffer_contents(mg_buffer_t *buffer);

#ifdef __cplusplus
}
#endif

#endif
