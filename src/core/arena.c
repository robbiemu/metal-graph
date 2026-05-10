#include "internal.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

bool mg_alignment_valid(size_t alignment) {
    return alignment != 0 && (alignment & (alignment - 1)) == 0;
}

bool mg_align_up_size(size_t value, size_t alignment, size_t *out_value) {
    if (!out_value || !mg_alignment_valid(alignment)) {
        return false;
    }

    size_t mask = alignment - 1;
    if (value > SIZE_MAX - mask) {
        return false;
    }

    *out_value = (value + mask) & ~mask;
    return true;
}

static mg_status_t mg_arena_desc_validate(const mg_arena_desc_t *desc, mg_error_stage_t stage,
                                          mg_error_t **out_error) {
    if (!desc) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, stage, MG_NODE_ID_INVALID,
                            "arena descriptor is required", NULL);
    }

    if (desc->size < sizeof(*desc)) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, stage, MG_NODE_ID_INVALID,
                            "arena descriptor size is invalid", NULL);
    }

    if (desc->byte_count == 0) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, stage, MG_NODE_ID_INVALID,
                            "arena size must be nonzero", NULL);
    }

    if (!mg_alignment_valid(desc->alignment)) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, stage, MG_NODE_ID_INVALID,
                            "arena alignment must be a nonzero power of two", NULL);
    }

    return MG_STATUS_OK;
}

mg_status_t mg_workspace_desc_validate(const mg_workspace_desc_t *desc, mg_error_stage_t stage,
                                       mg_error_t **out_error) {
    if (!desc) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, stage, MG_NODE_ID_INVALID,
                            "workspace descriptor is required", NULL);
    }

    if (desc->size < sizeof(*desc)) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, stage, MG_NODE_ID_INVALID,
                            "workspace descriptor size is invalid", NULL);
    }

    if (desc->byte_count == 0) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, stage, MG_NODE_ID_INVALID,
                            "workspace size must be nonzero", NULL);
    }

    if (!mg_alignment_valid(desc->alignment)) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, stage, MG_NODE_ID_INVALID,
                            "workspace alignment must be a nonzero power of two", NULL);
    }

    return MG_STATUS_OK;
}

mg_status_t mgArenaCreate(mg_device_t *device, const mg_arena_desc_t *desc, mg_arena_t **out_arena,
                          mg_error_t **out_error) {
    mg_clear_error(out_error);
    if (out_arena) {
        *out_arena = NULL;
    }

    if (!device || !out_arena) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_CREATE,
                            MG_NODE_ID_INVALID, "device and out_arena are required", NULL);
    }

    mg_status_t status = mg_arena_desc_validate(desc, MG_ERROR_STAGE_CREATE, out_error);
    if (status != MG_STATUS_OK) {
        return status;
    }

    mg_arena_t *arena = (mg_arena_t *)calloc(1, sizeof(*arena));
    if (!arena) {
        return mg_set_oom(out_error, MG_ERROR_STAGE_CREATE);
    }

    arena->size = desc->byte_count;
    arena->alignment = desc->alignment;
    arena->ref_count = 1;
    *out_arena = arena;
    return MG_STATUS_OK;
}

void mg_arena_retain(mg_arena_t *arena) {
    if (arena) {
        arena->ref_count++;
    }
}

void mg_arena_release(mg_arena_t *arena) {
    if (!arena) {
        return;
    }

    if (arena->ref_count > 1) {
        arena->ref_count--;
        return;
    }

    free(arena);
}

void mgArenaDestroy(mg_arena_t *arena) { mg_arena_release(arena); }

size_t mgArenaSize(const mg_arena_t *arena) { return arena ? arena->size : 0; }

size_t mgArenaAlignment(const mg_arena_t *arena) { return arena ? arena->alignment : 0; }

static mg_status_t mg_workspace_plan_append(mg_workspace_plan_t *plan, mg_node_id_t node_id,
                                            size_t size, size_t alignment, mg_error_t **out_error) {
    size_t offset = 0;
    if (!mg_align_up_size(plan->total_size, alignment, &offset)) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_PLAN_MEMORY,
                            node_id, "workspace alignment overflow during planning", NULL);
    }

    if (offset > SIZE_MAX - size) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_PLAN_MEMORY,
                            node_id, "workspace size overflow during planning", NULL);
    }

    if (plan->record_count >= SIZE_MAX / sizeof(*plan->records)) {
        return mg_set_error(out_error, MG_STATUS_OUT_OF_MEMORY, MG_ERROR_STAGE_PLAN_MEMORY, node_id,
                            "workspace record count overflow", NULL);
    }

    mg_workspace_record_t *records = (mg_workspace_record_t *)realloc(
        plan->records, (plan->record_count + 1) * sizeof(*records));
    if (!records) {
        return mg_set_oom(out_error, MG_ERROR_STAGE_PLAN_MEMORY);
    }

    plan->records = records;
    plan->records[plan->record_count++] = (mg_workspace_record_t){
        node_id,
        size,
        alignment,
        offset,
    };
    plan->total_size = offset + size;
    if (alignment > plan->alignment) {
        plan->alignment = alignment;
    }

    return MG_STATUS_OK;
}

mg_status_t mg_graph_plan_workspace(const mg_graph_t *graph, const size_t *order,
                                    mg_workspace_plan_t *out_plan, mg_error_t **out_error) {
    if (!graph || (graph->node_count > 0 && !order) || !out_plan) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_PLAN_MEMORY,
                            MG_NODE_ID_INVALID, "graph, order, and out_plan are required", NULL);
    }

    memset(out_plan, 0, sizeof(*out_plan));
    for (size_t ordinal = 0; ordinal < graph->node_count; ++ordinal) {
        const mg_node_t *node = graph->nodes[order[ordinal]];
        size_t size = 0;
        size_t alignment = 0;

        if ((int)node->kind == MG_NODE_INTERNAL_WORKSPACE) {
            size = node->as.workspace.size;
            alignment = node->as.workspace.alignment;
        } else if ((int)node->kind == MG_NODE_INTERNAL_WORKSPACE_FILL) {
            size = node->as.workspace_fill.size;
            alignment = node->as.workspace_fill.alignment;
        } else {
            continue;
        }

        mg_workspace_desc_t desc = {
            sizeof(desc),
            size,
            alignment,
        };
        mg_status_t status =
            mg_workspace_desc_validate(&desc, MG_ERROR_STAGE_PLAN_MEMORY, out_error);
        if (status != MG_STATUS_OK) {
            mg_workspace_plan_clear(out_plan);
            return status;
        }

        status = mg_workspace_plan_append(out_plan, node->id, size, alignment, out_error);
        if (status != MG_STATUS_OK) {
            mg_workspace_plan_clear(out_plan);
            return status;
        }
    }

    if (graph->arena) {
        if (out_plan->total_size > graph->arena->size) {
            mg_workspace_plan_clear(out_plan);
            return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_PLAN_MEMORY,
                                MG_NODE_ID_INVALID,
                                "workspace requirements exceed attached arena size", NULL);
        }

        if (out_plan->alignment > graph->arena->alignment) {
            mg_workspace_plan_clear(out_plan);
            return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_PLAN_MEMORY,
                                MG_NODE_ID_INVALID,
                                "workspace requirements exceed attached arena alignment", NULL);
        }

        out_plan->arena = graph->arena;
        mg_arena_retain(out_plan->arena);
    }

    return MG_STATUS_OK;
}

void mg_workspace_plan_clear(mg_workspace_plan_t *plan) {
    if (!plan) {
        return;
    }

    free(plan->records);
    mg_arena_release(plan->arena);
    memset(plan, 0, sizeof(*plan));
}

mg_status_t mg_workspace_plan_offset_for_node(const mg_workspace_plan_t *plan, mg_node_id_t node_id,
                                              size_t *out_offset, mg_error_t **out_error) {
    if (!plan || !out_offset) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_PLAN_MEMORY,
                            node_id, "workspace plan and out_offset are required", NULL);
    }

    for (size_t i = 0; i < plan->record_count; ++i) {
        if (plan->records[i].node_id == node_id) {
            *out_offset = plan->records[i].offset;
            return MG_STATUS_OK;
        }
    }

    return mg_set_error(out_error, MG_STATUS_INTERNAL_ERROR, MG_ERROR_STAGE_PLAN_MEMORY, node_id,
                        "workspace node is missing from plan", NULL);
}
