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

const mg_buffer_binding_t *mg_dispatch_find_buffer_binding(const mg_buffer_binding_t *bindings,
                                                           uint32_t binding_count, uint32_t index) {
    for (uint32_t i = 0; i < binding_count; ++i) {
        if (bindings[i].index == index) {
            return &bindings[i];
        }
    }
    return NULL;
}

const mg_dispatch_resource_desc_t *
mg_dispatch_find_resource(const mg_dispatch_resource_desc_t *resources, uint32_t resource_count,
                          uint32_t index) {
    for (uint32_t i = 0; i < resource_count; ++i) {
        if (resources[i].index == index) {
            return &resources[i];
        }
    }
    return NULL;
}

bool mg_dispatch_resource_range_valid(const mg_dispatch_resource_desc_t *resource,
                                      size_t buffer_length, size_t binding_offset) {
    if (!resource) {
        return binding_offset <= buffer_length;
    }
    if (resource->byte_offset > SIZE_MAX - binding_offset) {
        return false;
    }
    size_t absolute_offset = binding_offset + resource->byte_offset;
    if (resource->byte_count == 0) {
        return absolute_offset <= buffer_length;
    }
    return mg_range_valid(buffer_length, absolute_offset, resource->byte_count);
}

bool mg_dispatch_resource_offset_aligned(const mg_dispatch_resource_desc_t *resource,
                                         size_t binding_offset) {
    if (!resource) {
        return true;
    }
    size_t alignment = resource->alignment ? resource->alignment : 1;
    if (resource->byte_offset > SIZE_MAX - binding_offset) {
        return false;
    }
    return ((binding_offset + resource->byte_offset) % alignment) == 0;
}

static bool mg_resource_access_valid(mg_resource_access_t access) {
    return access == MG_RESOURCE_ACCESS_UNKNOWN || access == MG_RESOURCE_ACCESS_READ ||
           access == MG_RESOURCE_ACCESS_WRITE || access == MG_RESOURCE_ACCESS_READ_WRITE;
}

static size_t mg_tensor_data_type_size(mg_tensor_data_type_t data_type) {
    switch (data_type) {
    case MG_TENSOR_DATA_TYPE_FLOAT32:
        return sizeof(float);
    default:
        return 0;
    }
}

static bool mg_tensor_layout_valid(mg_tensor_layout_t layout) {
    return layout == MG_TENSOR_LAYOUT_CONTIGUOUS;
}

static bool mg_shape_byte_count(uint32_t rank, const size_t *shape, size_t element_size,
                                size_t *out_byte_count) {
    if (!out_byte_count || rank == 0 || !shape || element_size == 0) {
        return false;
    }

    size_t elements = 1;
    for (uint32_t i = 0; i < rank; ++i) {
        if (shape[i] == 0 || elements > SIZE_MAX / shape[i]) {
            return false;
        }
        elements *= shape[i];
    }
    if (elements > SIZE_MAX / element_size) {
        return false;
    }
    *out_byte_count = elements * element_size;
    return true;
}

static mg_status_t mg_validate_mpsgraph_tensor_desc(const mg_mpsgraph_tensor_desc_t *tensor,
                                                    mg_error_t **out_error) {
    if (!tensor || tensor->size < sizeof(*tensor) || !tensor->buffer || !tensor->shape ||
        tensor->rank == 0 || !mg_tensor_layout_valid(tensor->layout)) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_CREATE,
                            MG_NODE_ID_INVALID, "MPSGraph tensor descriptor is invalid", NULL);
    }

    size_t required_bytes = 0;
    size_t element_size = mg_tensor_data_type_size(tensor->data_type);
    if (!mg_shape_byte_count(tensor->rank, tensor->shape, element_size, &required_bytes)) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_CREATE,
                            MG_NODE_ID_INVALID, "MPSGraph tensor shape or dtype is invalid", NULL);
    }

    size_t byte_count = tensor->byte_count ? tensor->byte_count : required_bytes;
    if (byte_count < required_bytes || tensor->byte_offset != 0 ||
        !mg_range_valid(tensor->buffer->length, tensor->byte_offset, byte_count)) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_CREATE,
                            MG_NODE_ID_INVALID, "MPSGraph tensor buffer range is invalid", NULL);
    }

    return MG_STATUS_OK;
}

static mg_status_t mg_mpsgraph_tensor_clone(const mg_mpsgraph_tensor_desc_t *src,
                                            mg_mpsgraph_tensor_t *dst, mg_error_t **out_error) {
    memset(dst, 0, sizeof(*dst));

    size_t element_size = mg_tensor_data_type_size(src->data_type);
    size_t required_bytes = 0;
    if (!mg_shape_byte_count(src->rank, src->shape, element_size, &required_bytes)) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_CREATE,
                            MG_NODE_ID_INVALID, "MPSGraph tensor shape or dtype is invalid", NULL);
    }

    dst->shape = (size_t *)malloc(sizeof(*dst->shape) * src->rank);
    if (!dst->shape) {
        return mg_set_oom(out_error, MG_ERROR_STAGE_CREATE);
    }

    memcpy(dst->shape, src->shape, sizeof(*dst->shape) * src->rank);
    dst->buffer = src->buffer;
    dst->byte_offset = src->byte_offset;
    dst->byte_count = src->byte_count ? src->byte_count : required_bytes;
    dst->data_type = src->data_type;
    dst->layout = src->layout;
    dst->rank = src->rank;
    mg_buffer_retain(dst->buffer);
    return MG_STATUS_OK;
}

static void mg_mpsgraph_tensor_clear(mg_mpsgraph_tensor_t *tensor) {
    if (!tensor) {
        return;
    }
    mg_buffer_release(tensor->buffer);
    free(tensor->shape);
    memset(tensor, 0, sizeof(*tensor));
}

static mg_status_t mg_mpsgraph_tensor_array_clone(const mg_mpsgraph_tensor_desc_t *src,
                                                  uint32_t count,
                                                  mg_mpsgraph_tensor_t **out_tensors,
                                                  uint32_t *out_count, mg_error_t **out_error) {
    *out_tensors = NULL;
    *out_count = 0;
    if (count == 0) {
        return MG_STATUS_OK;
    }

    mg_mpsgraph_tensor_t *tensors = (mg_mpsgraph_tensor_t *)calloc(count, sizeof(*tensors));
    if (!tensors) {
        return mg_set_oom(out_error, MG_ERROR_STAGE_CREATE);
    }

    for (uint32_t i = 0; i < count; ++i) {
        mg_status_t status = mg_mpsgraph_tensor_clone(&src[i], &tensors[i], out_error);
        if (status != MG_STATUS_OK) {
            for (uint32_t j = 0; j < i; ++j) {
                mg_mpsgraph_tensor_clear(&tensors[j]);
            }
            free(tensors);
            return status;
        }
    }

    *out_tensors = tensors;
    *out_count = count;
    return MG_STATUS_OK;
}

static void mg_mpsgraph_tensor_array_clear(mg_mpsgraph_tensor_t *tensors, uint32_t count) {
    for (uint32_t i = 0; i < count; ++i) {
        mg_mpsgraph_tensor_clear(&tensors[i]);
    }
    free(tensors);
}

static mg_status_t mg_validate_dispatch_resource_desc(const mg_dispatch_resource_desc_t *resource,
                                                      const mg_buffer_binding_t *bindings,
                                                      uint32_t binding_count,
                                                      mg_error_t **out_error) {
    if (!resource || resource->size < sizeof(*resource) ||
        !mg_resource_access_valid(resource->access) ||
        !mg_alignment_valid(resource->alignment ? resource->alignment : 1)) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_CREATE,
                            MG_NODE_ID_INVALID, "dispatch resource descriptor is invalid", NULL);
    }

    const mg_buffer_binding_t *binding =
        mg_dispatch_find_buffer_binding(bindings, binding_count, resource->index);
    if (!binding) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_CREATE,
                            MG_NODE_ID_INVALID,
                            "dispatch resource descriptor references a missing binding", NULL);
    }
    if (!mg_dispatch_resource_offset_aligned(resource, binding->offset) ||
        !mg_dispatch_resource_range_valid(resource, binding->buffer->length, binding->offset)) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_CREATE,
                            MG_NODE_ID_INVALID, "dispatch resource range is invalid", NULL);
    }

    return MG_STATUS_OK;
}

static mg_status_t mg_validate_dispatch_resources(const mg_dispatch_resource_desc_t *resources,
                                                  uint32_t resource_count,
                                                  const mg_buffer_binding_t *bindings,
                                                  uint32_t binding_count, mg_error_t **out_error) {
    if (resource_count > 0 && !resources) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_CREATE,
                            MG_NODE_ID_INVALID, "dispatch resource descriptors are required", NULL);
    }

    for (uint32_t i = 0; i < resource_count; ++i) {
        for (uint32_t j = i + 1; j < resource_count; ++j) {
            if (resources[i].index == resources[j].index) {
                return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_CREATE,
                                    MG_NODE_ID_INVALID, "duplicate dispatch resource descriptor",
                                    NULL);
            }
        }

        mg_status_t status =
            mg_validate_dispatch_resource_desc(&resources[i], bindings, binding_count, out_error);
        if (status != MG_STATUS_OK) {
            return status;
        }
    }

    return MG_STATUS_OK;
}

static bool mg_dispatch_all_bindings_have_range_requirements(const mg_dispatch_node_t *dispatch) {
    for (uint32_t i = 0; i < dispatch->buffer_count; ++i) {
        const mg_dispatch_resource_desc_t *resource = mg_dispatch_find_resource(
            dispatch->resources, dispatch->resource_count, dispatch->buffers[i].index);
        if (!resource || resource->byte_count == 0) {
            return false;
        }
    }
    return true;
}

static bool mg_patch_flags_allowed(mg_node_kind_t kind, mg_patch_flags_t flags) {
    mg_patch_flags_t allowed = 0;
    switch (kind) {
    case MG_NODE_DISPATCH:
        allowed = MG_PATCH_DISPATCH_GRID | MG_PATCH_DISPATCH_BUFFER | MG_PATCH_DISPATCH_SCALAR;
        break;
    case MG_NODE_COPY:
        allowed = MG_PATCH_COPY_BUFFER | MG_PATCH_COPY_RANGE;
        break;
    case MG_NODE_FILL:
        allowed = MG_PATCH_FILL_BUFFER | MG_PATCH_FILL_RANGE | MG_PATCH_FILL_VALUE;
        break;
    case MG_NODE_EVENT_WAIT:
    case MG_NODE_EVENT_SIGNAL:
        allowed = MG_PATCH_EVENT_VALUE;
        break;
    default:
        allowed = 0;
        break;
    }
    return (flags & ~allowed) == 0;
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
    for (uint32_t i = 0; i < dispatch->scalar_count; ++i) {
        free((void *)dispatch->scalars[i].data);
    }

    free(dispatch->metallib_path);
    free(dispatch->kernel_name);
    free(dispatch->buffers);
    free(dispatch->scalars);
    free(dispatch->resources);
    memset(dispatch, 0, sizeof(*dispatch));
}

void mg_mpsgraph_node_clear(mg_mpsgraph_node_t *mpsgraph) {
    if (!mpsgraph) {
        return;
    }

    free(mpsgraph->package_path);
    mg_mpsgraph_tensor_array_clear(mpsgraph->feeds, mpsgraph->feed_count);
    mg_mpsgraph_tensor_array_clear(mpsgraph->targets, mpsgraph->target_count);
    memset(mpsgraph, 0, sizeof(*mpsgraph));
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
    case MG_NODE_MPSGRAPH:
        mg_mpsgraph_node_clear(&node->as.mpsgraph);
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

mg_status_t mgGraphSetNodePatchFlags(mg_graph_t *graph, mg_node_t *node, mg_patch_flags_t flags,
                                     mg_error_t **out_error) {
    mg_clear_error(out_error);
    if (!graph || !node || node->graph != graph) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_CREATE,
                            MG_NODE_ID_INVALID, "node must belong to graph", NULL);
    }

    if (!mg_patch_flags_allowed(node->kind, flags)) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_CREATE, node->id,
                            "patch flags are not compatible with node kind", NULL);
    }
    if (node->kind == MG_NODE_DISPATCH && (flags & MG_PATCH_DISPATCH_BUFFER) &&
        !mg_dispatch_all_bindings_have_range_requirements(&node->as.dispatch)) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_CREATE, node->id,
                            "patchable dispatch buffers require resource range descriptors", NULL);
    }

    node->patch_flags = flags;
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

    if (desc->size < offsetof(mg_dispatch_desc_t, scalars)) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_CREATE,
                            MG_NODE_ID_INVALID, "dispatch descriptor size is invalid", NULL);
    }
    bool has_phase3_fields = desc->size >= offsetof(mg_dispatch_desc_t, resources);
    bool has_phase4_fields = desc->size >= sizeof(*desc);
    const mg_scalar_binding_t *scalars = has_phase3_fields ? desc->scalars : NULL;
    uint32_t scalar_count = has_phase3_fields ? desc->scalar_count : 0;
    const mg_dispatch_resource_desc_t *resources = has_phase4_fields ? desc->resources : NULL;
    uint32_t resource_count = has_phase4_fields ? desc->resource_count : 0;

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
    if (has_phase3_fields) {
        memcpy(node->as.dispatch.max_grid_size, desc->max_grid_size,
               sizeof(node->as.dispatch.max_grid_size));
    }
    if (!mg_dims_valid(node->as.dispatch.max_grid_size)) {
        memcpy(node->as.dispatch.max_grid_size, desc->grid_size,
               sizeof(node->as.dispatch.max_grid_size));
    }

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
        for (uint32_t j = i + 1; j < desc->buffer_count; ++j) {
            if (desc->buffers[i].index == desc->buffers[j].index) {
                mg_node_clear(node);
                free(node);
                return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_CREATE,
                                    MG_NODE_ID_INVALID, "duplicate dispatch buffer binding", NULL);
            }
        }
    }

    if (scalar_count > 0 && !scalars) {
        mg_node_clear(node);
        free(node);
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_CREATE,
                            MG_NODE_ID_INVALID, "dispatch scalar bindings are required", NULL);
    }
    for (uint32_t i = 0; i < scalar_count; ++i) {
        if (!scalars[i].data || scalars[i].byte_count == 0) {
            mg_node_clear(node);
            free(node);
            return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_CREATE,
                                MG_NODE_ID_INVALID, "dispatch scalar binding is invalid", NULL);
        }
    }
    status = mg_validate_dispatch_resources(resources, resource_count, desc->buffers,
                                            desc->buffer_count, out_error);
    if (status != MG_STATUS_OK) {
        mg_node_clear(node);
        free(node);
        return status;
    }
    for (uint32_t axis = 0; axis < 3; ++axis) {
        if (node->as.dispatch.grid_size[axis] > node->as.dispatch.max_grid_size[axis]) {
            mg_node_clear(node);
            free(node);
            return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_CREATE,
                                MG_NODE_ID_INVALID, "dispatch grid exceeds declared maximum", NULL);
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
    if (scalar_count > 0) {
        node->as.dispatch.scalars =
            (mg_scalar_binding_t *)calloc(scalar_count, sizeof(*node->as.dispatch.scalars));
        if (!node->as.dispatch.scalars) {
            mg_node_clear(node);
            free(node);
            return mg_set_oom(out_error, MG_ERROR_STAGE_CREATE);
        }

        node->as.dispatch.scalar_count = scalar_count;
        for (uint32_t i = 0; i < scalar_count; ++i) {
            void *data = malloc(scalars[i].byte_count);
            if (!data) {
                mg_node_clear(node);
                free(node);
                return mg_set_oom(out_error, MG_ERROR_STAGE_CREATE);
            }
            memcpy(data, scalars[i].data, scalars[i].byte_count);
            node->as.dispatch.scalars[i] = (mg_scalar_binding_t){
                scalars[i].index,
                data,
                scalars[i].byte_count,
            };
        }
    }
    if (resource_count > 0) {
        size_t bytes = sizeof(*node->as.dispatch.resources) * resource_count;
        node->as.dispatch.resources = (mg_dispatch_resource_desc_t *)malloc(bytes);
        if (!node->as.dispatch.resources) {
            mg_node_clear(node);
            free(node);
            return mg_set_oom(out_error, MG_ERROR_STAGE_CREATE);
        }

        memcpy(node->as.dispatch.resources, resources, bytes);
        node->as.dispatch.resource_count = resource_count;
        for (uint32_t i = 0; i < resource_count; ++i) {
            if (node->as.dispatch.resources[i].alignment == 0) {
                node->as.dispatch.resources[i].alignment = 1;
            }
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

mg_status_t mgGraphAddMPSGraphNode(mg_graph_t *graph, const mg_mpsgraph_desc_t *desc,
                                   mg_node_t **out_node, mg_error_t **out_error) {
    mg_clear_error(out_error);
    if (out_node) {
        *out_node = NULL;
    }

    if (!graph || !desc || !out_node) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_CREATE,
                            MG_NODE_ID_INVALID, "graph, desc, and out_node are required", NULL);
    }
    if (desc->size < sizeof(*desc) || !desc->package_path || !desc->feeds ||
        desc->feed_count == 0 || !desc->targets || desc->target_count == 0) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_CREATE,
                            MG_NODE_ID_INVALID, "MPSGraph descriptor is incomplete", NULL);
    }

    for (uint32_t i = 0; i < desc->feed_count; ++i) {
        mg_status_t status = mg_validate_mpsgraph_tensor_desc(&desc->feeds[i], out_error);
        if (status != MG_STATUS_OK) {
            return status;
        }
    }
    for (uint32_t i = 0; i < desc->target_count; ++i) {
        mg_status_t status = mg_validate_mpsgraph_tensor_desc(&desc->targets[i], out_error);
        if (status != MG_STATUS_OK) {
            return status;
        }
    }

    mg_node_t *node = NULL;
    mg_status_t status = mg_graph_alloc_node(graph, MG_NODE_MPSGRAPH, &node, out_error);
    if (status != MG_STATUS_OK) {
        return status;
    }

    node->as.mpsgraph.package_path = mg_strdup(desc->package_path);
    if (!node->as.mpsgraph.package_path) {
        mg_node_clear(node);
        free(node);
        return mg_set_oom(out_error, MG_ERROR_STAGE_CREATE);
    }

    status = mg_mpsgraph_tensor_array_clone(desc->feeds, desc->feed_count, &node->as.mpsgraph.feeds,
                                            &node->as.mpsgraph.feed_count, out_error);
    if (status != MG_STATUS_OK) {
        mg_node_clear(node);
        free(node);
        return status;
    }
    status = mg_mpsgraph_tensor_array_clone(desc->targets, desc->target_count,
                                            &node->as.mpsgraph.targets,
                                            &node->as.mpsgraph.target_count, out_error);
    if (status != MG_STATUS_OK) {
        mg_node_clear(node);
        free(node);
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
