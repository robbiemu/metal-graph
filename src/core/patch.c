#include "internal.h"

#include <string.h>

static bool mg_patch_range_valid(size_t length, size_t offset, size_t byte_count) {
    return byte_count > 0 && offset <= length && byte_count <= length - offset;
}

static bool mg_patch_dims_valid(const uint32_t dims[3]) {
    return dims && dims[0] > 0 && dims[1] > 0 && dims[2] > 0;
}

static mg_status_t mg_patch_ready(mg_graph_exec_t *exec, mg_error_t **out_error) {
    if (!exec) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_PATCH,
                            MG_NODE_ID_INVALID, "exec is required", NULL);
    }

    if (exec->in_flight_count > 0) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_PATCH,
                            MG_NODE_ID_INVALID, "exec has an in-flight launch", NULL);
    }

    return MG_STATUS_OK;
}

static mg_exec_node_t *mg_patch_find_node(mg_graph_exec_t *exec, mg_node_id_t node_id,
                                          mg_error_t **out_error) {
    if (node_id == MG_NODE_ID_INVALID) {
        mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_PATCH, node_id,
                     "node_id is invalid", NULL);
        return NULL;
    }

    for (size_t i = 0; i < exec->node_count; ++i) {
        mg_exec_node_t *node = &exec->nodes[i];
        switch (node->kind) {
        case MG_NODE_DISPATCH:
            if (node->as.dispatch.id == node_id) {
                return node;
            }
            break;
        case MG_NODE_COPY:
            if (node->as.copy.id == node_id) {
                return node;
            }
            break;
        case MG_NODE_FILL:
            if (node->as.fill.id == node_id) {
                return node;
            }
            break;
        case MG_NODE_EVENT_WAIT:
        case MG_NODE_EVENT_SIGNAL:
            if (node->as.event.id == node_id) {
                return node;
            }
            break;
        case MG_NODE_BARRIER:
            if (node->as.barrier_id == node_id) {
                return node;
            }
            break;
        default:
            break;
        }
    }

    mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_PATCH, node_id,
                 "node_id does not exist in exec", NULL);
    return NULL;
}

static mg_status_t mg_patch_require_flag(mg_patch_flags_t flags, mg_patch_flags_t required,
                                         mg_node_id_t node_id, mg_error_t **out_error) {
    if ((flags & required) == 0) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_PATCH, node_id,
                            "field is not declared patchable", NULL);
    }
    return MG_STATUS_OK;
}

mg_status_t mgGraphExecPatchDispatchGrid(mg_graph_exec_t *exec, mg_node_id_t node_id,
                                         const uint32_t grid_size[3], mg_error_t **out_error) {
    mg_clear_error(out_error);
    mg_status_t status = mg_patch_ready(exec, out_error);
    if (status != MG_STATUS_OK) {
        return status;
    }

    mg_exec_node_t *node = mg_patch_find_node(exec, node_id, out_error);
    if (!node) {
        return MG_STATUS_INVALID_ARGUMENT;
    }
    if (node->kind != MG_NODE_DISPATCH) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_PATCH, node_id,
                            "node is not a dispatch node", NULL);
    }

    mg_exec_dispatch_t *dispatch = &node->as.dispatch;
    status =
        mg_patch_require_flag(dispatch->patch_flags, MG_PATCH_DISPATCH_GRID, node_id, out_error);
    if (status != MG_STATUS_OK) {
        return status;
    }
    if (!mg_patch_dims_valid(grid_size)) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_PATCH, node_id,
                            "dispatch grid size is invalid", NULL);
    }
    for (uint32_t axis = 0; axis < 3; ++axis) {
        if (grid_size[axis] > dispatch->max_grid_size[axis]) {
            return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_PATCH,
                                node_id, "dispatch grid exceeds declared maximum", NULL);
        }
    }

    memcpy(dispatch->grid_size, grid_size, sizeof(dispatch->grid_size));
    return MG_STATUS_OK;
}

mg_status_t mgGraphExecPatchDispatchBuffer(mg_graph_exec_t *exec, mg_node_id_t node_id,
                                           uint32_t index, mg_buffer_t *buffer, size_t offset,
                                           mg_error_t **out_error) {
    mg_clear_error(out_error);
    mg_status_t status = mg_patch_ready(exec, out_error);
    if (status != MG_STATUS_OK) {
        return status;
    }

    mg_exec_node_t *node = mg_patch_find_node(exec, node_id, out_error);
    if (!node) {
        return MG_STATUS_INVALID_ARGUMENT;
    }
    if (node->kind != MG_NODE_DISPATCH) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_PATCH, node_id,
                            "node is not a dispatch node", NULL);
    }

    mg_exec_dispatch_t *dispatch = &node->as.dispatch;
    status =
        mg_patch_require_flag(dispatch->patch_flags, MG_PATCH_DISPATCH_BUFFER, node_id, out_error);
    if (status != MG_STATUS_OK) {
        return status;
    }
    if (!buffer || offset > buffer->length) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_PATCH, node_id,
                            "dispatch buffer patch is invalid", NULL);
    }
    if (exec->device_impl && buffer->device_impl && exec->device_impl != buffer->device_impl) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_PATCH, node_id,
                            "dispatch buffer belongs to a different device", NULL);
    }

    for (uint32_t i = 0; i < dispatch->buffer_count; ++i) {
        if (dispatch->buffers[i].index != index) {
            continue;
        }
        const mg_dispatch_resource_desc_t *resource =
            mg_dispatch_find_resource(dispatch->resources, dispatch->resource_count, index);
        if (!resource || resource->byte_count == 0) {
            return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_PATCH,
                                node_id, "dispatch buffer patch requires a declared resource range",
                                NULL);
        }
        if (!mg_dispatch_resource_offset_aligned(resource, offset) ||
            !mg_dispatch_resource_range_valid(resource, buffer->length, offset)) {
            return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_PATCH,
                                node_id, "dispatch buffer patch range is incompatible", NULL);
        }
        mg_buffer_retain(buffer);
        mg_buffer_release(dispatch->buffers[i].buffer);
        dispatch->buffers[i].buffer = buffer;
        dispatch->buffers[i].offset = offset;
        return MG_STATUS_OK;
    }

    return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_PATCH, node_id,
                        "dispatch buffer binding index is not present", NULL);
}

mg_status_t mgGraphExecPatchDispatchScalar(mg_graph_exec_t *exec, mg_node_id_t node_id,
                                           uint32_t index, const void *data, size_t byte_count,
                                           mg_error_t **out_error) {
    mg_clear_error(out_error);
    mg_status_t status = mg_patch_ready(exec, out_error);
    if (status != MG_STATUS_OK) {
        return status;
    }

    mg_exec_node_t *node = mg_patch_find_node(exec, node_id, out_error);
    if (!node) {
        return MG_STATUS_INVALID_ARGUMENT;
    }
    if (node->kind != MG_NODE_DISPATCH) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_PATCH, node_id,
                            "node is not a dispatch node", NULL);
    }

    mg_exec_dispatch_t *dispatch = &node->as.dispatch;
    status =
        mg_patch_require_flag(dispatch->patch_flags, MG_PATCH_DISPATCH_SCALAR, node_id, out_error);
    if (status != MG_STATUS_OK) {
        return status;
    }
    if (!data || byte_count == 0) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_PATCH, node_id,
                            "dispatch scalar patch is invalid", NULL);
    }

    for (uint32_t i = 0; i < dispatch->scalar_count; ++i) {
        if (dispatch->scalars[i].index != index) {
            continue;
        }
        if (dispatch->scalars[i].byte_count != byte_count) {
            return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_PATCH,
                                node_id, "dispatch scalar size is incompatible", NULL);
        }
        memcpy((void *)dispatch->scalars[i].data, data, byte_count);
        return MG_STATUS_OK;
    }

    return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_PATCH, node_id,
                        "dispatch scalar binding index is not present", NULL);
}

mg_status_t mgGraphExecPatchCopyNode(mg_graph_exec_t *exec, mg_node_id_t node_id,
                                     const mg_copy_desc_t *desc, mg_error_t **out_error) {
    mg_clear_error(out_error);
    mg_status_t status = mg_patch_ready(exec, out_error);
    if (status != MG_STATUS_OK) {
        return status;
    }

    mg_exec_node_t *node = mg_patch_find_node(exec, node_id, out_error);
    if (!node) {
        return MG_STATUS_INVALID_ARGUMENT;
    }
    if (node->kind != MG_NODE_COPY) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_PATCH, node_id,
                            "node is not a copy node", NULL);
    }
    if (!desc || desc->size < sizeof(*desc) || !desc->src || !desc->dst ||
        !mg_patch_range_valid(desc->src->length, desc->src_offset, desc->byte_count) ||
        !mg_patch_range_valid(desc->dst->length, desc->dst_offset, desc->byte_count)) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_PATCH, node_id,
                            "copy patch descriptor is invalid", NULL);
    }

    mg_exec_copy_t *copy = &node->as.copy;
    bool changes_buffer = desc->src != copy->src || desc->dst != copy->dst;
    bool changes_range = desc->src_offset != copy->src_offset ||
                         desc->dst_offset != copy->dst_offset ||
                         desc->byte_count != copy->byte_count;
    if (changes_buffer) {
        status = mg_patch_require_flag(copy->patch_flags, MG_PATCH_COPY_BUFFER, node_id, out_error);
        if (status != MG_STATUS_OK) {
            return status;
        }
    }
    if (changes_range) {
        status = mg_patch_require_flag(copy->patch_flags, MG_PATCH_COPY_RANGE, node_id, out_error);
        if (status != MG_STATUS_OK) {
            return status;
        }
    }

    mg_buffer_retain(desc->src);
    mg_buffer_retain(desc->dst);
    mg_buffer_release(copy->src);
    mg_buffer_release(copy->dst);
    copy->src = desc->src;
    copy->src_offset = desc->src_offset;
    copy->dst = desc->dst;
    copy->dst_offset = desc->dst_offset;
    copy->byte_count = desc->byte_count;
    return MG_STATUS_OK;
}

mg_status_t mgGraphExecPatchFillNode(mg_graph_exec_t *exec, mg_node_id_t node_id,
                                     const mg_fill_desc_t *desc, mg_error_t **out_error) {
    mg_clear_error(out_error);
    mg_status_t status = mg_patch_ready(exec, out_error);
    if (status != MG_STATUS_OK) {
        return status;
    }

    mg_exec_node_t *node = mg_patch_find_node(exec, node_id, out_error);
    if (!node) {
        return MG_STATUS_INVALID_ARGUMENT;
    }
    if (node->kind != MG_NODE_FILL) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_PATCH, node_id,
                            "node is not a fill node", NULL);
    }
    if (!desc || desc->size < sizeof(*desc) || !desc->dst ||
        !mg_patch_range_valid(desc->dst->length, desc->dst_offset, desc->byte_count)) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_PATCH, node_id,
                            "fill patch descriptor is invalid", NULL);
    }

    mg_exec_fill_t *fill = &node->as.fill;
    bool changes_buffer = desc->dst != fill->dst;
    bool changes_range =
        desc->dst_offset != fill->dst_offset || desc->byte_count != fill->byte_count;
    bool changes_value = desc->value != fill->value;
    if (changes_buffer) {
        status = mg_patch_require_flag(fill->patch_flags, MG_PATCH_FILL_BUFFER, node_id, out_error);
        if (status != MG_STATUS_OK) {
            return status;
        }
    }
    if (changes_range) {
        status = mg_patch_require_flag(fill->patch_flags, MG_PATCH_FILL_RANGE, node_id, out_error);
        if (status != MG_STATUS_OK) {
            return status;
        }
    }
    if (changes_value) {
        status = mg_patch_require_flag(fill->patch_flags, MG_PATCH_FILL_VALUE, node_id, out_error);
        if (status != MG_STATUS_OK) {
            return status;
        }
    }

    mg_buffer_retain(desc->dst);
    mg_buffer_release(fill->dst);
    fill->dst = desc->dst;
    fill->dst_offset = desc->dst_offset;
    fill->byte_count = desc->byte_count;
    fill->value = desc->value;
    return MG_STATUS_OK;
}

mg_status_t mgGraphExecPatchEventValue(mg_graph_exec_t *exec, mg_node_id_t node_id, uint64_t value,
                                       mg_error_t **out_error) {
    mg_clear_error(out_error);
    mg_status_t status = mg_patch_ready(exec, out_error);
    if (status != MG_STATUS_OK) {
        return status;
    }

    mg_exec_node_t *node = mg_patch_find_node(exec, node_id, out_error);
    if (!node) {
        return MG_STATUS_INVALID_ARGUMENT;
    }
    if (node->kind != MG_NODE_EVENT_WAIT && node->kind != MG_NODE_EVENT_SIGNAL) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_PATCH, node_id,
                            "node is not an event node", NULL);
    }

    mg_exec_event_t *event = &node->as.event;
    status = mg_patch_require_flag(event->patch_flags, MG_PATCH_EVENT_VALUE, node_id, out_error);
    if (status != MG_STATUS_OK) {
        return status;
    }

    event->value = value;
    return MG_STATUS_OK;
}

mg_status_t mgGraphExecSetOptimizationFlags(mg_graph_exec_t *exec, mg_optimization_flags_t flags,
                                            mg_error_t **out_error) {
    mg_clear_error(out_error);
    mg_status_t status = mg_patch_ready(exec, out_error);
    if (status != MG_STATUS_OK) {
        return status;
    }
    if (flags & ~MG_OPTIMIZATION_ICB) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_PATCH,
                            MG_NODE_ID_INVALID, "optimization flags are invalid", NULL);
    }

    exec->icb.enabled_flags = flags;
    return MG_STATUS_OK;
}

mg_status_t mgGraphExecGetDiagnostics(const mg_graph_exec_t *exec,
                                      mg_graph_exec_diagnostics_t *out_diagnostics,
                                      mg_error_t **out_error) {
    mg_clear_error(out_error);
    if (!exec || !out_diagnostics || out_diagnostics->size < sizeof(*out_diagnostics)) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_PATCH,
                            MG_NODE_ID_INVALID, "exec and diagnostics are required", NULL);
    }

    memset(out_diagnostics, 0, sizeof(*out_diagnostics));
    out_diagnostics->size = sizeof(*out_diagnostics);
    out_diagnostics->icb_available = exec->icb.available;
    out_diagnostics->icb_enabled = (exec->icb.enabled_flags & MG_OPTIMIZATION_ICB) ? 1u : 0u;
    out_diagnostics->icb_groups_planned = exec->icb.groups_planned;
    out_diagnostics->icb_groups_used = exec->icb.groups_used;
    out_diagnostics->icb_groups_fallback = exec->icb.groups_fallback;
    out_diagnostics->icb_last_fallback_reason = exec->icb.last_fallback_reason;
    return MG_STATUS_OK;
}
