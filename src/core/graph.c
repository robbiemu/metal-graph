#include "internal.h"

#include <stdlib.h>
#include <string.h>

static bool mg_dims_valid(const uint32_t dims[3]) {
    return dims[0] > 0 && dims[1] > 0 && dims[2] > 0;
}

static mg_status_t mg_graph_reserve_nodes(mg_graph_t *graph, size_t required,
                                          mg_error_t **out_error) {
    if (required <= graph->node_capacity) {
        return MG_STATUS_OK;
    }

    size_t next_capacity = graph->node_capacity ? graph->node_capacity * 2 : 4;
    while (next_capacity < required) {
        next_capacity *= 2;
    }

    mg_node_t **nodes = (mg_node_t **)realloc(graph->nodes, next_capacity * sizeof(*nodes));
    if (!nodes) {
        return mg_set_oom(out_error, MG_ERROR_STAGE_CREATE);
    }

    graph->nodes = nodes;
    graph->node_capacity = next_capacity;
    return MG_STATUS_OK;
}

static mg_status_t mg_graph_reserve_edges(mg_graph_t *graph, size_t required,
                                          mg_error_t **out_error) {
    if (required <= graph->edge_capacity) {
        return MG_STATUS_OK;
    }

    size_t next_capacity = graph->edge_capacity ? graph->edge_capacity * 2 : 4;
    while (next_capacity < required) {
        next_capacity *= 2;
    }

    mg_edge_t *edges = (mg_edge_t *)realloc(graph->edges, next_capacity * sizeof(*edges));
    if (!edges) {
        return mg_set_oom(out_error, MG_ERROR_STAGE_CREATE);
    }

    graph->edges = edges;
    graph->edge_capacity = next_capacity;
    return MG_STATUS_OK;
}

void mg_dispatch_node_clear(mg_dispatch_node_t *dispatch) {
    if (!dispatch) {
        return;
    }

    for (uint32_t i = 0; i < dispatch->buffer_count; ++i) {
        mg_buffer_release(dispatch->buffers[i].buffer);
    }

    free(dispatch->metallib_path);
    free(dispatch->kernel_name);
    free(dispatch->buffers);
    memset(dispatch, 0, sizeof(*dispatch));
}

mg_status_t mg_graph_create(mg_graph_t **out_graph, mg_error_t **out_error) {
    mg_clear_error(out_error);
    if (!out_graph) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_CREATE,
                            MG_NODE_ID_INVALID, "out_graph is required", NULL);
    }

    *out_graph = NULL;
    mg_graph_t *graph = (mg_graph_t *)calloc(1, sizeof(*graph));
    if (!graph) {
        return mg_set_oom(out_error, MG_ERROR_STAGE_CREATE);
    }

    *out_graph = graph;
    return MG_STATUS_OK;
}

void mg_graph_destroy(mg_graph_t *graph) {
    if (!graph) {
        return;
    }

    for (size_t i = 0; i < graph->node_count; ++i) {
        mg_node_t *node = graph->nodes[i];
        if (node) {
            mg_dispatch_node_clear(&node->dispatch);
            free(node);
        }
    }

    free(graph->nodes);
    free(graph->edges);
    free(graph);
}

mg_status_t mg_graph_add_dispatch_node(mg_graph_t *graph, const mg_dispatch_desc_t *desc,
                                       mg_node_t **out_node, mg_error_t **out_error) {
    mg_clear_error(out_error);
    if (out_node) {
        *out_node = NULL;
    }

    if (!graph || !desc || !out_node) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_CREATE,
                            MG_NODE_ID_INVALID, "graph, desc, and out_node are required", NULL);
    }

    if (desc->size < sizeof(*desc)) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_CREATE,
                            MG_NODE_ID_INVALID, "dispatch descriptor size is invalid", NULL);
    }

    if (!desc->metallib_path || !desc->kernel_name || !mg_dims_valid(desc->grid_size) ||
        !mg_dims_valid(desc->threads_per_threadgroup)) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_CREATE,
                            MG_NODE_ID_INVALID, "dispatch descriptor is incomplete", NULL);
    }

    if (desc->buffer_count > 0 && !desc->buffers) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_CREATE,
                            MG_NODE_ID_INVALID, "dispatch buffer bindings are required", NULL);
    }

    mg_status_t status = mg_graph_reserve_nodes(graph, graph->node_count + 1, out_error);
    if (status != MG_STATUS_OK) {
        return status;
    }

    mg_node_t *node = (mg_node_t *)calloc(1, sizeof(*node));
    if (!node) {
        return mg_set_oom(out_error, MG_ERROR_STAGE_CREATE);
    }

    node->graph = graph;
    node->id = graph->node_count + 1;
    node->index = graph->node_count;
    node->kind = MG_NODE_DISPATCH;
    node->dispatch.metallib_path = mg_strdup(desc->metallib_path);
    node->dispatch.kernel_name = mg_strdup(desc->kernel_name);
    memcpy(node->dispatch.grid_size, desc->grid_size, sizeof(node->dispatch.grid_size));
    memcpy(node->dispatch.threads_per_threadgroup, desc->threads_per_threadgroup,
           sizeof(node->dispatch.threads_per_threadgroup));

    if (!node->dispatch.metallib_path || !node->dispatch.kernel_name) {
        mg_dispatch_node_clear(&node->dispatch);
        free(node);
        return mg_set_oom(out_error, MG_ERROR_STAGE_CREATE);
    }

    for (uint32_t i = 0; i < desc->buffer_count; ++i) {
        if (!desc->buffers[i].buffer || desc->buffers[i].offset > desc->buffers[i].buffer->length) {
            mg_dispatch_node_clear(&node->dispatch);
            free(node);
            return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_CREATE,
                                MG_NODE_ID_INVALID, "dispatch buffer binding is invalid", NULL);
        }
    }

    if (desc->buffer_count > 0) {
        size_t bytes = sizeof(*node->dispatch.buffers) * desc->buffer_count;
        node->dispatch.buffers = (mg_buffer_binding_t *)malloc(bytes);
        if (!node->dispatch.buffers) {
            mg_dispatch_node_clear(&node->dispatch);
            free(node);
            return mg_set_oom(out_error, MG_ERROR_STAGE_CREATE);
        }

        memcpy(node->dispatch.buffers, desc->buffers, bytes);
        node->dispatch.buffer_count = desc->buffer_count;
        for (uint32_t i = 0; i < desc->buffer_count; ++i) {
            mg_buffer_retain(node->dispatch.buffers[i].buffer);
        }
    }

    graph->nodes[graph->node_count++] = node;
    *out_node = node;
    return MG_STATUS_OK;
}

mg_node_id_t mg_node_id(const mg_node_t *node) { return node ? node->id : MG_NODE_ID_INVALID; }

mg_status_t mg_graph_add_dependency(mg_graph_t *graph, mg_node_t *before, mg_node_t *after,
                                    mg_error_t **out_error) {
    mg_clear_error(out_error);
    if (!graph || !before || !after || before->graph != graph || after->graph != graph) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_CREATE,
                            MG_NODE_ID_INVALID, "dependency nodes must belong to graph", NULL);
    }

    if (before == after) {
        return mg_set_error(out_error, MG_STATUS_INVALID_TOPOLOGY, MG_ERROR_STAGE_CREATE,
                            before->id, "self-dependencies are not allowed", NULL);
    }

    for (size_t i = 0; i < graph->edge_count; ++i) {
        if (graph->edges[i].before == before->index && graph->edges[i].after == after->index) {
            return MG_STATUS_OK;
        }
    }

    mg_status_t status = mg_graph_reserve_edges(graph, graph->edge_count + 1, out_error);
    if (status != MG_STATUS_OK) {
        return status;
    }

    graph->edges[graph->edge_count++] = (mg_edge_t){
        before->index,
        after->index,
    };
    return MG_STATUS_OK;
}

mg_status_t mg_graph_topological_order(const mg_graph_t *graph, size_t *order,
                                       mg_error_t **out_error) {
    if (!graph || (graph->node_count > 0 && !order)) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_VALIDATE,
                            MG_NODE_ID_INVALID, "graph and order are required", NULL);
    }

    if (graph->node_count == 0) {
        return MG_STATUS_OK;
    }

    size_t *indegree = (size_t *)calloc(graph->node_count, sizeof(*indegree));
    size_t *queue = (size_t *)malloc(graph->node_count * sizeof(*queue));
    if ((graph->node_count > 0 && !queue) || !indegree) {
        free(indegree);
        free(queue);
        return mg_set_oom(out_error, MG_ERROR_STAGE_VALIDATE);
    }

    for (size_t i = 0; i < graph->edge_count; ++i) {
        if (graph->edges[i].before >= graph->node_count ||
            graph->edges[i].after >= graph->node_count) {
            free(indegree);
            free(queue);
            return mg_set_error(out_error, MG_STATUS_INVALID_TOPOLOGY, MG_ERROR_STAGE_VALIDATE,
                                MG_NODE_ID_INVALID, "dependency references an invalid node", NULL);
        }
        indegree[graph->edges[i].after]++;
    }

    size_t head = 0;
    size_t tail = 0;
    for (size_t i = 0; i < graph->node_count; ++i) {
        if (indegree[i] == 0) {
            queue[tail++] = i;
        }
    }

    size_t produced = 0;
    while (head < tail) {
        size_t current = queue[head++];
        order[produced++] = current;

        for (size_t i = 0; i < graph->edge_count; ++i) {
            if (graph->edges[i].before != current) {
                continue;
            }
            size_t next = graph->edges[i].after;
            indegree[next]--;
            if (indegree[next] == 0) {
                queue[tail++] = next;
            }
        }
    }

    free(indegree);
    free(queue);

    if (produced != graph->node_count) {
        return mg_set_error(out_error, MG_STATUS_INVALID_TOPOLOGY, MG_ERROR_STAGE_VALIDATE,
                            MG_NODE_ID_INVALID, "graph contains a dependency cycle", NULL);
    }

    return MG_STATUS_OK;
}

mg_status_t mg_graph_validate(const mg_graph_t *graph, mg_error_t **out_error) {
    mg_clear_error(out_error);
    if (!graph) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_VALIDATE,
                            MG_NODE_ID_INVALID, "graph is required", NULL);
    }

    if (graph->node_count == 0) {
        return MG_STATUS_OK;
    }

    size_t *order = (size_t *)malloc(graph->node_count * sizeof(*order));
    if (!order) {
        return mg_set_oom(out_error, MG_ERROR_STAGE_VALIDATE);
    }

    mg_status_t status = mg_graph_topological_order(graph, order, out_error);
    free(order);
    return status;
}
