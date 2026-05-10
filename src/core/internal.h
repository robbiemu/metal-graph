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
    mg_buffer_binding_t *buffers;
    uint32_t buffer_count;
} mg_dispatch_node_t;

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
    size_t length;
    uint32_t ref_count;
};

struct mg_node {
    mg_graph_t *graph;
    mg_node_id_t id;
    size_t index;
    mg_node_kind_t kind;
    mg_dispatch_node_t dispatch;
};

struct mg_graph {
    mg_node_t **nodes;
    size_t node_count;
    size_t node_capacity;
    mg_edge_t *edges;
    size_t edge_count;
    size_t edge_capacity;
};

typedef struct mg_exec_dispatch {
    mg_node_id_t id;
    char *metallib_path;
    char *kernel_name;
    uint32_t grid_size[3];
    uint32_t threads_per_threadgroup[3];
    mg_buffer_binding_t *buffers;
    uint32_t buffer_count;
    void *pipeline_impl;
} mg_exec_dispatch_t;

struct mg_graph_exec {
    mg_exec_dispatch_t *dispatches;
    size_t dispatch_count;
    void *device_impl;
};

struct mg_launch {
    void *impl;
    mg_buffer_t **retained_buffers;
    size_t retained_buffer_count;
};

char *mg_strdup(const char *value);
void mg_clear_error(mg_error_t **out_error);
mg_status_t mg_set_error(mg_error_t **out_error, mg_status_t status, mg_error_stage_t stage,
                         mg_node_id_t node_id, const char *message, const char *backend_message);
mg_status_t mg_set_oom(mg_error_t **out_error, mg_error_stage_t stage);

void mg_dispatch_node_clear(mg_dispatch_node_t *dispatch);
mg_status_t mg_graph_topological_order(const mg_graph_t *graph, size_t *order,
                                       mg_error_t **out_error);

void mg_buffer_retain(mg_buffer_t *buffer);
void mg_buffer_release(mg_buffer_t *buffer);

void mg_backend_device_destroy(mg_device_t *device);
void mg_backend_stream_destroy(mg_stream_t *stream);
void mg_backend_buffer_destroy(mg_buffer_t *buffer);
void mg_backend_graph_exec_destroy(mg_graph_exec_t *exec);
void mg_backend_launch_destroy(mg_launch_t *launch);
void *mg_backend_buffer_contents(mg_buffer_t *buffer);

#ifdef __cplusplus
}
#endif

#endif
