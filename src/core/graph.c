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

static bool mg_range_valid(size_t length, size_t offset, size_t byte_count) {
    return byte_count > 0 && offset <= length && byte_count <= length - offset;
}

static mg_status_t mg_graph_alloc_node(mg_graph_t *graph, mg_node_kind_t kind, mg_node_t **out_node,
                                       mg_error_t **out_error) {
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
    node->kind = kind;
    *out_node = node;
    return MG_STATUS_OK;
}

static void mg_graph_commit_node(mg_graph_t *graph, mg_node_t *node, mg_node_t **out_node) {
    graph->nodes[graph->node_count++] = node;
    *out_node = node;
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

void mg_node_clear(mg_node_t *node) {
    if (!node) {
        return;
    }

    switch (node->kind) {
    case MG_NODE_DISPATCH:
        mg_dispatch_node_clear(&node->as.dispatch);
        break;
    case MG_NODE_COPY:
        mg_buffer_release(node->as.copy.src);
        mg_buffer_release(node->as.copy.dst);
        memset(&node->as.copy, 0, sizeof(node->as.copy));
        break;
    case MG_NODE_FILL:
        mg_buffer_release(node->as.fill.dst);
        memset(&node->as.fill, 0, sizeof(node->as.fill));
        break;
    case MG_NODE_EVENT_WAIT:
    case MG_NODE_EVENT_SIGNAL:
        mg_event_release(node->as.event.event);
        memset(&node->as.event, 0, sizeof(node->as.event));
        break;
    case MG_NODE_BARRIER:
        break;
    default:
        if ((int)node->kind == MG_NODE_INTERNAL_WORKSPACE) {
            memset(&node->as.workspace, 0, sizeof(node->as.workspace));
        } else if ((int)node->kind == MG_NODE_INTERNAL_WORKSPACE_FILL) {
            mg_buffer_release(node->as.workspace_fill.dst);
            memset(&node->as.workspace_fill, 0, sizeof(node->as.workspace_fill));
        }
        break;
    }
}

mg_status_t mgGraphCreate(mg_graph_t **out_graph, mg_error_t **out_error) {
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

void mgGraphDestroy(mg_graph_t *graph) {
    if (!graph) {
        return;
    }

    for (size_t i = 0; i < graph->node_count; ++i) {
        mg_node_t *node = graph->nodes[i];
        if (node) {
            mg_node_clear(node);
            free(node);
        }
    }

    free(graph->nodes);
    free(graph->edges);
    mg_arena_release(graph->arena);
    free(graph);
}

mg_status_t mgGraphSetArena(mg_graph_t *graph, mg_arena_t *arena, mg_error_t **out_error) {
    mg_clear_error(out_error);
    if (!graph || !arena) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_CREATE,
                            MG_NODE_ID_INVALID, "graph and arena are required", NULL);
    }

    if (graph->arena == arena) {
        return MG_STATUS_OK;
    }

    mg_arena_retain(arena);
    mg_arena_release(graph->arena);
    graph->arena = arena;
    return MG_STATUS_OK;
}

mg_status_t mgGraphAddDispatchNode(mg_graph_t *graph, const mg_dispatch_desc_t *desc,
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

    mg_node_t *node = NULL;
    mg_status_t status = mg_graph_alloc_node(graph, MG_NODE_DISPATCH, &node, out_error);
    if (status != MG_STATUS_OK) {
        return status;
    }

    node->as.dispatch.metallib_path = mg_strdup(desc->metallib_path);
    node->as.dispatch.kernel_name = mg_strdup(desc->kernel_name);
    memcpy(node->as.dispatch.grid_size, desc->grid_size, sizeof(node->as.dispatch.grid_size));
    memcpy(node->as.dispatch.threads_per_threadgroup, desc->threads_per_threadgroup,
           sizeof(node->as.dispatch.threads_per_threadgroup));

    if (!node->as.dispatch.metallib_path || !node->as.dispatch.kernel_name) {
        mg_node_clear(node);
        free(node);
        return mg_set_oom(out_error, MG_ERROR_STAGE_CREATE);
    }

    for (uint32_t i = 0; i < desc->buffer_count; ++i) {
        if (!desc->buffers[i].buffer || desc->buffers[i].offset > desc->buffers[i].buffer->length) {
            mg_node_clear(node);
            free(node);
            return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_CREATE,
                                MG_NODE_ID_INVALID, "dispatch buffer binding is invalid", NULL);
        }
    }

    if (desc->buffer_count > 0) {
        size_t bytes = sizeof(*node->as.dispatch.buffers) * desc->buffer_count;
        node->as.dispatch.buffers = (mg_buffer_binding_t *)malloc(bytes);
        if (!node->as.dispatch.buffers) {
            mg_node_clear(node);
            free(node);
            return mg_set_oom(out_error, MG_ERROR_STAGE_CREATE);
        }

        memcpy(node->as.dispatch.buffers, desc->buffers, bytes);
        node->as.dispatch.buffer_count = desc->buffer_count;
        for (uint32_t i = 0; i < desc->buffer_count; ++i) {
            mg_buffer_retain(node->as.dispatch.buffers[i].buffer);
        }
    }

    mg_graph_commit_node(graph, node, out_node);
    return MG_STATUS_OK;
}

mg_status_t mgGraphAddCopyNode(mg_graph_t *graph, const mg_copy_desc_t *desc, mg_node_t **out_node,
                               mg_error_t **out_error) {
    mg_clear_error(out_error);
    if (out_node) {
        *out_node = NULL;
    }

    if (!graph || !desc || !out_node) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_CREATE,
                            MG_NODE_ID_INVALID, "graph, desc, and out_node are required", NULL);
    }
    if (desc->size < sizeof(*desc) || !desc->src || !desc->dst ||
        !mg_range_valid(desc->src->length, desc->src_offset, desc->byte_count) ||
        !mg_range_valid(desc->dst->length, desc->dst_offset, desc->byte_count)) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_CREATE,
                            MG_NODE_ID_INVALID, "copy descriptor is invalid", NULL);
    }

    mg_node_t *node = NULL;
    mg_status_t status = mg_graph_alloc_node(graph, MG_NODE_COPY, &node, out_error);
    if (status != MG_STATUS_OK) {
        return status;
    }

    node->as.copy.src = desc->src;
    node->as.copy.src_offset = desc->src_offset;
    node->as.copy.dst = desc->dst;
    node->as.copy.dst_offset = desc->dst_offset;
    node->as.copy.byte_count = desc->byte_count;
    mg_buffer_retain(node->as.copy.src);
    mg_buffer_retain(node->as.copy.dst);
    mg_graph_commit_node(graph, node, out_node);
    return MG_STATUS_OK;
}

mg_status_t mgGraphAddFillNode(mg_graph_t *graph, const mg_fill_desc_t *desc, mg_node_t **out_node,
                               mg_error_t **out_error) {
    mg_clear_error(out_error);
    if (out_node) {
        *out_node = NULL;
    }

    if (!graph || !desc || !out_node) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_CREATE,
                            MG_NODE_ID_INVALID, "graph, desc, and out_node are required", NULL);
    }
    if (desc->size < sizeof(*desc) || !desc->dst ||
        !mg_range_valid(desc->dst->length, desc->dst_offset, desc->byte_count)) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_CREATE,
                            MG_NODE_ID_INVALID, "fill descriptor is invalid", NULL);
    }

    mg_node_t *node = NULL;
    mg_status_t status = mg_graph_alloc_node(graph, MG_NODE_FILL, &node, out_error);
    if (status != MG_STATUS_OK) {
        return status;
    }

    node->as.fill.dst = desc->dst;
    node->as.fill.dst_offset = desc->dst_offset;
    node->as.fill.byte_count = desc->byte_count;
    node->as.fill.value = desc->value;
    mg_buffer_retain(node->as.fill.dst);
    mg_graph_commit_node(graph, node, out_node);
    return MG_STATUS_OK;
}

static mg_status_t mg_graph_add_event_node(mg_graph_t *graph, mg_node_kind_t kind,
                                           mg_event_t *event, uint64_t value, mg_node_t **out_node,
                                           mg_error_t **out_error) {
    mg_clear_error(out_error);
    if (out_node) {
        *out_node = NULL;
    }

    if (!graph || !event || !out_node) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_CREATE,
                            MG_NODE_ID_INVALID, "graph, event, and out_node are required", NULL);
    }

    mg_node_t *node = NULL;
    mg_status_t status = mg_graph_alloc_node(graph, kind, &node, out_error);
    if (status != MG_STATUS_OK) {
        return status;
    }

    node->as.event.event = event;
    node->as.event.value = value;
    mg_event_retain(event);
    mg_graph_commit_node(graph, node, out_node);
    return MG_STATUS_OK;
}

mg_status_t mgGraphAddEventWaitNode(mg_graph_t *graph, mg_event_t *event, uint64_t value,
                                    mg_node_t **out_node, mg_error_t **out_error) {
    return mg_graph_add_event_node(graph, MG_NODE_EVENT_WAIT, event, value, out_node, out_error);
}

mg_status_t mgGraphAddEventSignalNode(mg_graph_t *graph, mg_event_t *event, uint64_t value,
                                      mg_node_t **out_node, mg_error_t **out_error) {
    return mg_graph_add_event_node(graph, MG_NODE_EVENT_SIGNAL, event, value, out_node, out_error);
}

mg_status_t mgGraphAddBarrierNode(mg_graph_t *graph, mg_node_t **out_node, mg_error_t **out_error) {
    mg_clear_error(out_error);
    if (out_node) {
        *out_node = NULL;
    }

    if (!graph || !out_node) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_CREATE,
                            MG_NODE_ID_INVALID, "graph and out_node are required", NULL);
    }

    mg_node_t *node = NULL;
    mg_status_t status = mg_graph_alloc_node(graph, MG_NODE_BARRIER, &node, out_error);
    if (status != MG_STATUS_OK) {
        return status;
    }

    mg_graph_commit_node(graph, node, out_node);
    return MG_STATUS_OK;
}

mg_status_t mg_internal_graph_add_workspace_node(mg_graph_t *graph, const mg_workspace_desc_t *desc,
                                                 mg_node_t **out_node, mg_error_t **out_error) {
    mg_clear_error(out_error);
    if (out_node) {
        *out_node = NULL;
    }

    if (!graph || !out_node) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_CREATE,
                            MG_NODE_ID_INVALID, "graph and out_node are required", NULL);
    }

    mg_status_t status = mg_workspace_desc_validate(desc, MG_ERROR_STAGE_CREATE, out_error);
    if (status != MG_STATUS_OK) {
        return status;
    }

    mg_node_t *node = NULL;
    status =
        mg_graph_alloc_node(graph, (mg_node_kind_t)MG_NODE_INTERNAL_WORKSPACE, &node, out_error);
    if (status != MG_STATUS_OK) {
        return status;
    }

    node->as.workspace.size = desc->byte_count;
    node->as.workspace.alignment = desc->alignment;
    mg_graph_commit_node(graph, node, out_node);
    return MG_STATUS_OK;
}

mg_status_t mg_internal_graph_add_workspace_fill_node(mg_graph_t *graph,
                                                      const mg_workspace_desc_t *desc,
                                                      uint8_t value, mg_buffer_t *dst,
                                                      size_t dst_offset, mg_node_t **out_node,
                                                      mg_error_t **out_error) {
    mg_clear_error(out_error);
    if (out_node) {
        *out_node = NULL;
    }

    if (!graph || !dst || !out_node) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_CREATE,
                            MG_NODE_ID_INVALID, "graph, dst, and out_node are required", NULL);
    }

    mg_status_t status = mg_workspace_desc_validate(desc, MG_ERROR_STAGE_CREATE, out_error);
    if (status != MG_STATUS_OK) {
        return status;
    }

    if (!mg_range_valid(dst->length, dst_offset, desc->byte_count)) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_CREATE,
                            MG_NODE_ID_INVALID, "workspace fill destination range is invalid",
                            NULL);
    }

    mg_node_t *node = NULL;
    status = mg_graph_alloc_node(graph, (mg_node_kind_t)MG_NODE_INTERNAL_WORKSPACE_FILL, &node,
                                 out_error);
    if (status != MG_STATUS_OK) {
        return status;
    }

    node->as.workspace_fill.size = desc->byte_count;
    node->as.workspace_fill.alignment = desc->alignment;
    node->as.workspace_fill.value = value;
    node->as.workspace_fill.dst = dst;
    node->as.workspace_fill.dst_offset = dst_offset;
    mg_buffer_retain(dst);
    mg_graph_commit_node(graph, node, out_node);
    return MG_STATUS_OK;
}

mg_node_id_t mgNodeId(const mg_node_t *node) { return node ? node->id : MG_NODE_ID_INVALID; }

mg_status_t mgGraphAddDependency(mg_graph_t *graph, mg_node_t *before, mg_node_t *after,
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

mg_status_t mgGraphValidate(const mg_graph_t *graph, mg_error_t **out_error) {
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
