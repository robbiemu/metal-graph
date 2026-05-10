#include "../../src/core/internal.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int expect_status(mg_status_t actual, mg_status_t expected, const char *label) {
    if (actual != expected) {
        fprintf(stderr, "%s: expected %s, got %s\n", label, mgStatusString(expected),
                mgStatusString(actual));
        return 1;
    }
    return 0;
}

static mg_dispatch_desc_t test_dispatch_desc(void) {
    mg_dispatch_desc_t desc;
    memset(&desc, 0, sizeof(desc));
    desc.size = sizeof(desc);
    desc.metallib_path = "missing-test-only.metallib";
    desc.kernel_name = "test_kernel";
    desc.grid_size[0] = 1;
    desc.grid_size[1] = 1;
    desc.grid_size[2] = 1;
    desc.threads_per_threadgroup[0] = 1;
    desc.threads_per_threadgroup[1] = 1;
    desc.threads_per_threadgroup[2] = 1;
    return desc;
}

int main(void) {
    mg_error_t *error = NULL;
    if (expect_status(mgGraphCreate(NULL, &error), MG_STATUS_INVALID_ARGUMENT,
                      "create graph with null output")) {
        mgErrorDestroy(error);
        return 1;
    }
    mgErrorDestroy(error);
    error = NULL;

    mg_graph_t *graph = NULL;
    if (expect_status(mgGraphCreate(&graph, &error), MG_STATUS_OK, "create graph")) {
        return 2;
    }

    if (expect_status(mgGraphValidate(graph, &error), MG_STATUS_OK, "validate empty graph")) {
        mgGraphDestroy(graph);
        return 3;
    }

    mg_node_t *invalid = NULL;
    if (expect_status(mgGraphAddCopyNode(graph, NULL, &invalid, &error), MG_STATUS_INVALID_ARGUMENT,
                      "reject null copy descriptor")) {
        mgErrorDestroy(error);
        mgGraphDestroy(graph);
        return 4;
    }
    mgErrorDestroy(error);
    error = NULL;

    mg_copy_desc_t invalid_copy;
    memset(&invalid_copy, 0, sizeof(invalid_copy));
    invalid_copy.size = sizeof(invalid_copy);
    invalid_copy.byte_count = 1;
    if (expect_status(mgGraphAddCopyNode(graph, &invalid_copy, &invalid, &error),
                      MG_STATUS_INVALID_ARGUMENT, "reject invalid copy descriptor")) {
        mgErrorDestroy(error);
        mgGraphDestroy(graph);
        return 5;
    }
    mgErrorDestroy(error);
    error = NULL;

    if (expect_status(mgGraphAddFillNode(graph, NULL, &invalid, &error), MG_STATUS_INVALID_ARGUMENT,
                      "reject null fill descriptor")) {
        mgErrorDestroy(error);
        mgGraphDestroy(graph);
        return 6;
    }
    mgErrorDestroy(error);
    error = NULL;

    mg_fill_desc_t invalid_fill;
    memset(&invalid_fill, 0, sizeof(invalid_fill));
    invalid_fill.size = sizeof(invalid_fill);
    invalid_fill.byte_count = 1;
    if (expect_status(mgGraphAddFillNode(graph, &invalid_fill, &invalid, &error),
                      MG_STATUS_INVALID_ARGUMENT, "reject invalid fill descriptor")) {
        mgErrorDestroy(error);
        mgGraphDestroy(graph);
        return 7;
    }
    mgErrorDestroy(error);
    error = NULL;

    if (expect_status(mgGraphAddEventWaitNode(graph, NULL, 1, &invalid, &error),
                      MG_STATUS_INVALID_ARGUMENT, "reject null event wait")) {
        mgErrorDestroy(error);
        mgGraphDestroy(graph);
        return 8;
    }
    mgErrorDestroy(error);
    error = NULL;

    if (expect_status(mgGraphAddEventSignalNode(graph, NULL, 1, &invalid, &error),
                      MG_STATUS_INVALID_ARGUMENT, "reject null event signal")) {
        mgErrorDestroy(error);
        mgGraphDestroy(graph);
        return 9;
    }
    mgErrorDestroy(error);
    error = NULL;

    if (expect_status(mgGraphAddMPSGraphNode(graph, NULL, &invalid, &error),
                      MG_STATUS_INVALID_ARGUMENT, "reject null MPSGraph descriptor")) {
        mgErrorDestroy(error);
        mgGraphDestroy(graph);
        return 10;
    }
    mgErrorDestroy(error);
    error = NULL;

    if (expect_status(mgGraphAddBarrierNode(NULL, &invalid, &error), MG_STATUS_INVALID_ARGUMENT,
                      "reject null barrier graph")) {
        mgErrorDestroy(error);
        mgGraphDestroy(graph);
        return 10;
    }
    mgErrorDestroy(error);
    error = NULL;

    mg_arena_desc_t invalid_arena;
    memset(&invalid_arena, 0, sizeof(invalid_arena));
    invalid_arena.size = sizeof(invalid_arena);
    invalid_arena.byte_count = 64;
    invalid_arena.alignment = 16;
    if (expect_status(mgArenaCreate(NULL, &invalid_arena, NULL, &error), MG_STATUS_INVALID_ARGUMENT,
                      "reject invalid arena create")) {
        mgErrorDestroy(error);
        mgGraphDestroy(graph);
        return 11;
    }
    mgErrorDestroy(error);
    error = NULL;

    if (expect_status(mgGraphSetArena(graph, NULL, &error), MG_STATUS_INVALID_ARGUMENT,
                      "reject null graph arena")) {
        mgErrorDestroy(error);
        mgGraphDestroy(graph);
        return 12;
    }
    mgErrorDestroy(error);
    error = NULL;

    mg_buffer_t mps_buffer = {
        NULL,
        NULL,
        sizeof(float) * 4,
        1,
    };
    size_t mps_shape[1] = {4};
    mg_mpsgraph_tensor_desc_t mps_tensor;
    memset(&mps_tensor, 0, sizeof(mps_tensor));
    mps_tensor.size = sizeof(mps_tensor);
    mps_tensor.buffer = &mps_buffer;
    mps_tensor.data_type = MG_TENSOR_DATA_TYPE_FLOAT32;
    mps_tensor.layout = MG_TENSOR_LAYOUT_CONTIGUOUS;
    mps_tensor.rank = 1;
    mps_tensor.shape = mps_shape;
    mg_mpsgraph_desc_t mps_desc;
    memset(&mps_desc, 0, sizeof(mps_desc));
    mps_desc.size = sizeof(mps_desc);
    mps_desc.package_path = "missing-test-only.mpsgraphpackage";
    mps_desc.feeds = &mps_tensor;
    mps_desc.feed_count = 1;
    mps_desc.targets = &mps_tensor;
    mps_desc.target_count = 1;

    mg_mpsgraph_desc_t missing_feed_desc = mps_desc;
    missing_feed_desc.feeds = NULL;
    if (expect_status(mgGraphAddMPSGraphNode(graph, &missing_feed_desc, &invalid, &error),
                      MG_STATUS_INVALID_ARGUMENT, "reject missing MPSGraph feeds")) {
        mgErrorDestroy(error);
        mgGraphDestroy(graph);
        return 14;
    }
    mgErrorDestroy(error);
    error = NULL;

    mg_mpsgraph_tensor_desc_t invalid_mps_tensor = mps_tensor;
    invalid_mps_tensor.rank = 0;
    mps_desc.feeds = &invalid_mps_tensor;
    if (expect_status(mgGraphAddMPSGraphNode(graph, &mps_desc, &invalid, &error),
                      MG_STATUS_INVALID_ARGUMENT, "reject invalid MPSGraph shape")) {
        mgErrorDestroy(error);
        mgGraphDestroy(graph);
        return 14;
    }
    mgErrorDestroy(error);
    error = NULL;

    invalid_mps_tensor = mps_tensor;
    invalid_mps_tensor.data_type = (mg_tensor_data_type_t)999;
    mps_desc.feeds = &invalid_mps_tensor;
    if (expect_status(mgGraphAddMPSGraphNode(graph, &mps_desc, &invalid, &error),
                      MG_STATUS_INVALID_ARGUMENT, "reject invalid MPSGraph dtype")) {
        mgErrorDestroy(error);
        mgGraphDestroy(graph);
        return 14;
    }
    mgErrorDestroy(error);
    error = NULL;

    invalid_mps_tensor = mps_tensor;
    invalid_mps_tensor.layout = (mg_tensor_layout_t)999;
    mps_desc.feeds = &invalid_mps_tensor;
    if (expect_status(mgGraphAddMPSGraphNode(graph, &mps_desc, &invalid, &error),
                      MG_STATUS_INVALID_ARGUMENT, "reject invalid MPSGraph layout")) {
        mgErrorDestroy(error);
        mgGraphDestroy(graph);
        return 14;
    }
    mgErrorDestroy(error);
    error = NULL;

    invalid_mps_tensor = mps_tensor;
    invalid_mps_tensor.byte_count = sizeof(float) * 2;
    mps_desc.feeds = &invalid_mps_tensor;
    if (expect_status(mgGraphAddMPSGraphNode(graph, &mps_desc, &invalid, &error),
                      MG_STATUS_INVALID_ARGUMENT, "reject too-small MPSGraph tensor range")) {
        mgErrorDestroy(error);
        mgGraphDestroy(graph);
        return 14;
    }
    mgErrorDestroy(error);
    error = NULL;

    mps_desc.feeds = &mps_tensor;
    mg_node_t *mps_node = NULL;
    if (expect_status(mgGraphAddMPSGraphNode(graph, &mps_desc, &mps_node, &error), MG_STATUS_OK,
                      "add MPSGraph node")) {
        mgGraphDestroy(graph);
        return 14;
    }
    if (expect_status(mgGraphSetNodePatchFlags(graph, mps_node, MG_PATCH_DISPATCH_GRID, &error),
                      MG_STATUS_INVALID_ARGUMENT, "reject MPSGraph patch flags")) {
        mgErrorDestroy(error);
        mgGraphDestroy(graph);
        return 14;
    }
    mgErrorDestroy(error);
    error = NULL;

    mg_graph_t *mps_cycle_graph = NULL;
    mg_node_t *mps_cycle_node = NULL;
    mg_node_t *mps_cycle_barrier = NULL;
    if (expect_status(mgGraphCreate(&mps_cycle_graph, &error), MG_STATUS_OK,
                      "create MPSGraph cycle graph") ||
        expect_status(mgGraphAddMPSGraphNode(mps_cycle_graph, &mps_desc, &mps_cycle_node, &error),
                      MG_STATUS_OK, "add MPSGraph cycle node") ||
        expect_status(mgGraphAddBarrierNode(mps_cycle_graph, &mps_cycle_barrier, &error),
                      MG_STATUS_OK, "add MPSGraph cycle barrier") ||
        expect_status(
            mgGraphAddDependency(mps_cycle_graph, mps_cycle_node, mps_cycle_barrier, &error),
            MG_STATUS_OK, "add MPSGraph dependency") ||
        expect_status(
            mgGraphAddDependency(mps_cycle_graph, mps_cycle_barrier, mps_cycle_node, &error),
            MG_STATUS_OK, "add MPSGraph cycle dependency") ||
        expect_status(mgGraphValidate(mps_cycle_graph, &error), MG_STATUS_INVALID_TOPOLOGY,
                      "MPSGraph node participates in cycle validation")) {
        mgErrorDestroy(error);
        mgGraphDestroy(mps_cycle_graph);
        mgGraphDestroy(graph);
        return 14;
    }
    mgErrorDestroy(error);
    error = NULL;
    mgGraphDestroy(mps_cycle_graph);

    mg_workspace_desc_t invalid_workspace;
    memset(&invalid_workspace, 0, sizeof(invalid_workspace));
    invalid_workspace.size = sizeof(invalid_workspace);
    invalid_workspace.byte_count = 64;
    invalid_workspace.alignment = 3;
    if (expect_status(
            mg_internal_graph_add_workspace_node(graph, &invalid_workspace, &invalid, &error),
            MG_STATUS_INVALID_ARGUMENT, "reject invalid workspace alignment")) {
        mgErrorDestroy(error);
        mgGraphDestroy(graph);
        return 13;
    }
    mgErrorDestroy(error);
    error = NULL;

    mg_workspace_desc_t workspace;
    memset(&workspace, 0, sizeof(workspace));
    workspace.size = sizeof(workspace);
    workspace.byte_count = 64;
    workspace.alignment = 16;
    if (expect_status(mg_internal_graph_add_workspace_node(graph, &workspace, &invalid, &error),
                      MG_STATUS_OK, "add workspace node")) {
        mgGraphDestroy(graph);
        return 14;
    }

    mg_graph_t *plan_graph = NULL;
    mg_node_t *plan_first = NULL;
    mg_node_t *plan_second = NULL;
    mg_workspace_plan_t plan;
    memset(&plan, 0, sizeof(plan));
    mg_workspace_desc_t first_workspace;
    memset(&first_workspace, 0, sizeof(first_workspace));
    first_workspace.size = sizeof(first_workspace);
    first_workspace.byte_count = 3;
    first_workspace.alignment = 4;
    mg_workspace_desc_t second_workspace;
    memset(&second_workspace, 0, sizeof(second_workspace));
    second_workspace.size = sizeof(second_workspace);
    second_workspace.byte_count = 5;
    second_workspace.alignment = 8;
    if (expect_status(mgGraphCreate(&plan_graph, &error), MG_STATUS_OK, "create plan graph") ||
        expect_status(
            mg_internal_graph_add_workspace_node(plan_graph, &first_workspace, &plan_first, &error),
            MG_STATUS_OK, "add first planned workspace") ||
        expect_status(mg_internal_graph_add_workspace_node(plan_graph, &second_workspace,
                                                           &plan_second, &error),
                      MG_STATUS_OK, "add second planned workspace") ||
        expect_status(mgGraphAddDependency(plan_graph, plan_first, plan_second, &error),
                      MG_STATUS_OK, "add workspace planning dependency")) {
        mgGraphDestroy(plan_graph);
        mgGraphDestroy(graph);
        return 15;
    }

    size_t *plan_order = (size_t *)malloc(plan_graph->node_count * sizeof(*plan_order));
    if (!plan_order) {
        mgGraphDestroy(plan_graph);
        mgGraphDestroy(graph);
        return 16;
    }

    if (expect_status(mg_graph_topological_order(plan_graph, plan_order, &error), MG_STATUS_OK,
                      "topological workspace plan") ||
        expect_status(mg_graph_plan_workspace(plan_graph, plan_order, &plan, &error), MG_STATUS_OK,
                      "plan workspace")) {
        free(plan_order);
        mg_workspace_plan_clear(&plan);
        mgGraphDestroy(plan_graph);
        mgGraphDestroy(graph);
        return 17;
    }

    free(plan_order);
    if (plan.record_count != 2 || plan.records[0].offset != 0 || plan.records[1].offset != 8 ||
        plan.records[0].size != 3 || plan.records[1].size != 5 || plan.total_size != 13 ||
        plan.alignment != 8) {
        fprintf(stderr, "workspace plan should be monotonic, aligned, and non-overlapping\n");
        mg_workspace_plan_clear(&plan);
        mgGraphDestroy(plan_graph);
        mgGraphDestroy(graph);
        return 18;
    }
    mg_workspace_plan_clear(&plan);
    mgGraphDestroy(plan_graph);

    uint32_t scalar_value = 7;
    uint32_t scalar_storage = scalar_value;
    mg_buffer_t dispatch_buffer = {
        NULL,
        NULL,
        16,
        1,
    };
    mg_buffer_t tiny_buffer = {
        NULL,
        NULL,
        4,
        1,
    };
    mg_buffer_t copy_dst = {
        NULL,
        NULL,
        16,
        1,
    };
    mg_dispatch_desc_t resource_desc = test_dispatch_desc();
    mg_buffer_binding_t resource_binding = {
        0,
        &dispatch_buffer,
        0,
    };
    resource_desc.buffers = &resource_binding;
    resource_desc.buffer_count = 1;
    mg_dispatch_resource_desc_t resource = {
        sizeof(mg_dispatch_resource_desc_t), 0, MG_RESOURCE_ACCESS_READ_WRITE, 0, 8, 4,
    };
    resource_desc.resources = &resource;
    resource_desc.resource_count = 1;
    mg_node_t *resource_node = NULL;
    if (expect_status(mgGraphAddDispatchNode(graph, &resource_desc, &resource_node, &error),
                      MG_STATUS_OK, "add dispatch with resource requirement") ||
        expect_status(
            mgGraphSetNodePatchFlags(graph, resource_node, MG_PATCH_DISPATCH_BUFFER, &error),
            MG_STATUS_OK, "allow patchable dispatch with resource requirement")) {
        mgGraphDestroy(graph);
        return 19;
    }

    mg_buffer_binding_t duplicate_bindings[2] = {
        resource_binding,
        resource_binding,
    };
    resource_desc.buffers = duplicate_bindings;
    resource_desc.buffer_count = 2;
    resource_desc.resources = NULL;
    resource_desc.resource_count = 0;
    if (expect_status(mgGraphAddDispatchNode(graph, &resource_desc, &invalid, &error),
                      MG_STATUS_INVALID_ARGUMENT, "reject duplicate dispatch buffer bindings")) {
        mgErrorDestroy(error);
        mgGraphDestroy(graph);
        return 20;
    }
    mgErrorDestroy(error);
    error = NULL;

    resource_desc.buffers = &resource_binding;
    resource_desc.buffer_count = 1;
    mg_dispatch_resource_desc_t duplicate_resources[2] = {resource, resource};
    resource_desc.resources = duplicate_resources;
    resource_desc.resource_count = 2;
    if (expect_status(mgGraphAddDispatchNode(graph, &resource_desc, &invalid, &error),
                      MG_STATUS_INVALID_ARGUMENT, "reject duplicate dispatch resources")) {
        mgErrorDestroy(error);
        mgGraphDestroy(graph);
        return 20;
    }
    mgErrorDestroy(error);
    error = NULL;

    resource_desc.resources = &resource;
    resource_desc.resource_count = 1;
    mg_dispatch_resource_desc_t missing_resource = resource;
    missing_resource.index = 7;
    resource_desc.resources = &missing_resource;
    if (expect_status(mgGraphAddDispatchNode(graph, &resource_desc, &invalid, &error),
                      MG_STATUS_INVALID_ARGUMENT, "reject resource for missing binding")) {
        mgErrorDestroy(error);
        mgGraphDestroy(graph);
        return 21;
    }
    mgErrorDestroy(error);
    error = NULL;

    mg_dispatch_resource_desc_t too_large_resource = resource;
    too_large_resource.byte_count = 32;
    resource_desc.resources = &too_large_resource;
    if (expect_status(mgGraphAddDispatchNode(graph, &resource_desc, &invalid, &error),
                      MG_STATUS_INVALID_ARGUMENT, "reject resource outside initial buffer")) {
        mgErrorDestroy(error);
        mgGraphDestroy(graph);
        return 22;
    }
    mgErrorDestroy(error);
    error = NULL;

    mg_dispatch_resource_desc_t overflow_resource = resource;
    overflow_resource.byte_offset = SIZE_MAX;
    overflow_resource.byte_count = 1;
    resource_desc.resources = &overflow_resource;
    if (expect_status(mgGraphAddDispatchNode(graph, &resource_desc, &invalid, &error),
                      MG_STATUS_INVALID_ARGUMENT, "reject dispatch resource range overflow")) {
        mgErrorDestroy(error);
        mgGraphDestroy(graph);
        return 22;
    }
    mgErrorDestroy(error);
    error = NULL;

    resource_desc.resources = NULL;
    resource_desc.resource_count = 0;
    mg_node_t *no_resource_node = NULL;
    if (expect_status(mgGraphAddDispatchNode(graph, &resource_desc, &no_resource_node, &error),
                      MG_STATUS_OK, "add dispatch without resource requirement") ||
        expect_status(
            mgGraphSetNodePatchFlags(graph, no_resource_node, MG_PATCH_DISPATCH_BUFFER, &error),
            MG_STATUS_INVALID_ARGUMENT,
            "reject patchable dispatch buffer without resource requirement")) {
        mgErrorDestroy(error);
        mgGraphDestroy(graph);
        return 23;
    }
    mgErrorDestroy(error);
    error = NULL;

    mg_exec_node_t patch_nodes[5];
    memset(patch_nodes, 0, sizeof(patch_nodes));
    patch_nodes[0].kind = MG_NODE_DISPATCH;
    patch_nodes[0].as.dispatch.id = 100;
    patch_nodes[0].as.dispatch.patch_flags = MG_PATCH_DISPATCH_GRID | MG_PATCH_DISPATCH_SCALAR;
    patch_nodes[0].as.dispatch.grid_size[0] = 1;
    patch_nodes[0].as.dispatch.grid_size[1] = 1;
    patch_nodes[0].as.dispatch.grid_size[2] = 1;
    patch_nodes[0].as.dispatch.max_grid_size[0] = 4;
    patch_nodes[0].as.dispatch.max_grid_size[1] = 1;
    patch_nodes[0].as.dispatch.max_grid_size[2] = 1;
    mg_scalar_binding_t scalar_binding = {
        1,
        &scalar_storage,
        sizeof(scalar_storage),
    };
    patch_nodes[0].as.dispatch.scalars = &scalar_binding;
    patch_nodes[0].as.dispatch.scalar_count = 1;
    mg_buffer_binding_t buffer_binding = {
        0,
        &dispatch_buffer,
        0,
    };
    patch_nodes[0].as.dispatch.buffers = &buffer_binding;
    patch_nodes[0].as.dispatch.buffer_count = 1;
    mg_dispatch_resource_desc_t exec_resource = {
        sizeof(mg_dispatch_resource_desc_t), 0, MG_RESOURCE_ACCESS_READ_WRITE, 0, 8, 4,
    };
    patch_nodes[0].as.dispatch.resources = &exec_resource;
    patch_nodes[0].as.dispatch.resource_count = 1;
    patch_nodes[1].kind = MG_NODE_COPY;
    patch_nodes[1].as.copy.id = 101;
    patch_nodes[1].as.copy.patch_flags = MG_PATCH_COPY_RANGE;
    patch_nodes[1].as.copy.src = &dispatch_buffer;
    patch_nodes[1].as.copy.dst = &copy_dst;
    patch_nodes[1].as.copy.byte_count = 4;
    patch_nodes[2].kind = MG_NODE_FILL;
    patch_nodes[2].as.fill.id = 102;
    patch_nodes[2].as.fill.patch_flags = MG_PATCH_FILL_VALUE;
    patch_nodes[2].as.fill.dst = &copy_dst;
    patch_nodes[2].as.fill.byte_count = 4;
    patch_nodes[2].as.fill.value = 0x11;
    patch_nodes[3].kind = MG_NODE_EVENT_SIGNAL;
    patch_nodes[3].as.event.id = 103;
    patch_nodes[3].as.event.patch_flags = 0;
    patch_nodes[3].as.event.value = 1;
    patch_nodes[4].kind = MG_NODE_EVENT_WAIT;
    patch_nodes[4].as.event.id = 104;
    patch_nodes[4].as.event.patch_flags = MG_PATCH_EVENT_VALUE;
    patch_nodes[4].as.event.value = 2;
    mg_graph_exec_t patch_exec;
    memset(&patch_exec, 0, sizeof(patch_exec));
    patch_exec.nodes = patch_nodes;
    patch_exec.node_count = 5;

    uint32_t new_grid[3] = {2, 1, 1};
    uint32_t too_large_grid[3] = {5, 1, 1};
    uint64_t wrong_scalar = 9;
    if (expect_status(mgGraphExecPatchDispatchGrid(NULL, 100, new_grid, &error),
                      MG_STATUS_INVALID_ARGUMENT, "reject null patch exec") ||
        expect_status(mgGraphExecPatchDispatchGrid(&patch_exec, 999, new_grid, &error),
                      MG_STATUS_INVALID_ARGUMENT, "reject unknown patch node") ||
        expect_status(mgGraphExecPatchDispatchGrid(&patch_exec, 101, new_grid, &error),
                      MG_STATUS_INVALID_ARGUMENT, "reject wrong patch node kind") ||
        expect_status(
            mgGraphExecPatchDispatchBuffer(&patch_exec, 100, 0, &dispatch_buffer, 0, &error),
            MG_STATUS_INVALID_ARGUMENT, "reject non-patchable dispatch buffer") ||
        expect_status(mgGraphExecPatchDispatchScalar(&patch_exec, 100, 1, &wrong_scalar,
                                                     sizeof(wrong_scalar), &error),
                      MG_STATUS_INVALID_ARGUMENT, "reject wrong scalar size") ||
        expect_status(mgGraphExecPatchDispatchGrid(&patch_exec, 100, too_large_grid, &error),
                      MG_STATUS_INVALID_ARGUMENT, "reject grid beyond declared bounds")) {
        mgErrorDestroy(error);
        mgGraphDestroy(graph);
        return 19;
    }
    mgErrorDestroy(error);
    error = NULL;
    if (patch_nodes[0].as.dispatch.grid_size[0] != 1 || scalar_storage != scalar_value) {
        fprintf(stderr, "failed patch should preserve previous dispatch defaults\n");
        mgGraphDestroy(graph);
        return 20;
    }

    if (expect_status(mgGraphExecPatchDispatchGrid(&patch_exec, 100, new_grid, &error),
                      MG_STATUS_OK, "patch dispatch grid")) {
        mgGraphDestroy(graph);
        return 21;
    }
    if (expect_status(mgGraphExecPatchDispatchGrid(&patch_exec, 100, too_large_grid, &error),
                      MG_STATUS_INVALID_ARGUMENT, "reject invalid grid after successful patch")) {
        mgErrorDestroy(error);
        mgGraphDestroy(graph);
        return 22;
    }
    mgErrorDestroy(error);
    error = NULL;
    if (patch_nodes[0].as.dispatch.grid_size[0] != 2) {
        fprintf(stderr, "failed patch should preserve previously patched dispatch grid\n");
        mgGraphDestroy(graph);
        return 23;
    }

    patch_nodes[0].as.dispatch.patch_flags |= MG_PATCH_DISPATCH_BUFFER;
    if (expect_status(mgGraphExecPatchDispatchBuffer(&patch_exec, 100, 0, &tiny_buffer, 8, &error),
                      MG_STATUS_INVALID_ARGUMENT, "reject incompatible dispatch buffer")) {
        mgErrorDestroy(error);
        mgGraphDestroy(graph);
        return 22;
    }
    mgErrorDestroy(error);
    error = NULL;
    if (expect_status(
            mgGraphExecPatchDispatchBuffer(&patch_exec, 100, 0, &dispatch_buffer, 4, &error),
            MG_STATUS_OK, "accept range-compatible dispatch buffer patch")) {
        mgGraphDestroy(graph);
        return 22;
    }

    mg_copy_desc_t bad_copy_patch;
    memset(&bad_copy_patch, 0, sizeof(bad_copy_patch));
    bad_copy_patch.size = sizeof(bad_copy_patch);
    bad_copy_patch.src = &dispatch_buffer;
    bad_copy_patch.dst = &copy_dst;
    bad_copy_patch.byte_count = 32;
    if (expect_status(mgGraphExecPatchCopyNode(&patch_exec, 101, &bad_copy_patch, &error),
                      MG_STATUS_INVALID_ARGUMENT, "reject invalid copy range")) {
        mgErrorDestroy(error);
        mgGraphDestroy(graph);
        return 23;
    }
    mgErrorDestroy(error);
    error = NULL;

    mg_fill_desc_t fill_patch;
    memset(&fill_patch, 0, sizeof(fill_patch));
    fill_patch.size = sizeof(fill_patch);
    fill_patch.dst = &copy_dst;
    fill_patch.byte_count = 4;
    fill_patch.value = 0x22;
    if (expect_status(mgGraphExecPatchFillNode(&patch_exec, 102, &fill_patch, &error), MG_STATUS_OK,
                      "patch fill value")) {
        mgGraphDestroy(graph);
        return 24;
    }

    if (expect_status(mgGraphExecPatchEventValue(&patch_exec, 103, 2, &error),
                      MG_STATUS_INVALID_ARGUMENT, "reject non-patchable event value")) {
        mgErrorDestroy(error);
        mgGraphDestroy(graph);
        return 25;
    }
    mgErrorDestroy(error);
    error = NULL;
    patch_nodes[3].as.event.patch_flags = MG_PATCH_EVENT_VALUE;
    if (expect_status(mgGraphExecPatchEventValue(&patch_exec, 103, 2, &error), MG_STATUS_OK,
                      "patch event value")) {
        mgGraphDestroy(graph);
        return 26;
    }
    if (expect_status(mgGraphExecPatchEventValue(&patch_exec, 104, 3, &error), MG_STATUS_OK,
                      "patch event wait value")) {
        mgGraphDestroy(graph);
        return 27;
    }

    patch_exec.in_flight_count = 1;
    if (expect_status(mgGraphExecPatchDispatchGrid(&patch_exec, 100, new_grid, &error),
                      MG_STATUS_INVALID_ARGUMENT, "reject in-flight patch")) {
        mgErrorDestroy(error);
        mgGraphDestroy(graph);
        return 27;
    }
    mgErrorDestroy(error);
    error = NULL;
    patch_exec.in_flight_count = 0;

    mg_dispatch_desc_t invalid_desc = test_dispatch_desc();
    invalid_desc.size = 0;
    if (expect_status(mgGraphAddDispatchNode(graph, &invalid_desc, &invalid, &error),
                      MG_STATUS_INVALID_ARGUMENT, "reject short dispatch descriptor")) {
        mgErrorDestroy(error);
        mgGraphDestroy(graph);
        return 28;
    }
    mgErrorDestroy(error);
    error = NULL;

    invalid_desc = test_dispatch_desc();
    mg_buffer_binding_t invalid_binding = {0};
    invalid_desc.buffers = &invalid_binding;
    invalid_desc.buffer_count = 1;
    if (expect_status(mgGraphAddDispatchNode(graph, &invalid_desc, &invalid, &error),
                      MG_STATUS_INVALID_ARGUMENT, "reject invalid buffer binding")) {
        mgErrorDestroy(error);
        mgGraphDestroy(graph);
        return 29;
    }
    mgErrorDestroy(error);
    error = NULL;

    mg_dispatch_desc_t desc = test_dispatch_desc();
    mg_node_t *first = NULL;
    mg_node_t *second = NULL;
    if (expect_status(mgGraphAddDispatchNode(graph, &desc, &first, &error), MG_STATUS_OK,
                      "add first node") ||
        expect_status(mgGraphAddDispatchNode(graph, &desc, &second, &error), MG_STATUS_OK,
                      "add second node")) {
        mgGraphDestroy(graph);
        return 30;
    }

    if (mgNodeId(first) == MG_NODE_ID_INVALID || mgNodeId(second) == MG_NODE_ID_INVALID) {
        fprintf(stderr, "node ids should be valid\n");
        mgGraphDestroy(graph);
        return 31;
    }

    if (expect_status(mgGraphAddDependency(graph, first, first, &error), MG_STATUS_INVALID_TOPOLOGY,
                      "reject self dependency")) {
        mgErrorDestroy(error);
        mgGraphDestroy(graph);
        return 32;
    }
    mgErrorDestroy(error);
    error = NULL;

    if (expect_status(mgGraphAddDependency(graph, first, second, &error), MG_STATUS_OK,
                      "add dependency") ||
        expect_status(mgGraphAddDependency(graph, first, second, &error), MG_STATUS_OK,
                      "ignore duplicate dependency") ||
        expect_status(mgGraphValidate(graph, &error), MG_STATUS_OK, "validate acyclic graph")) {
        mgGraphDestroy(graph);
        return 33;
    }

    mg_status_t cycle_status = mgGraphAddDependency(graph, second, first, &error);
    if (expect_status(cycle_status, MG_STATUS_OK, "add cycle edge")) {
        mgGraphDestroy(graph);
        return 34;
    }

    cycle_status = mgGraphValidate(graph, &error);
    if (expect_status(cycle_status, MG_STATUS_INVALID_TOPOLOGY, "validate cyclic graph")) {
        mgErrorDestroy(error);
        mgGraphDestroy(graph);
        return 35;
    }

    if (mgErrorStage(error) != MG_ERROR_STAGE_VALIDATE) {
        fprintf(stderr, "cycle error should come from validate stage\n");
        mgErrorDestroy(error);
        mgGraphDestroy(graph);
        return 36;
    }

    mgErrorDestroy(error);
    mgGraphDestroy(graph);
    return 0;
}
