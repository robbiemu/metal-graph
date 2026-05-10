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

    mg_dispatch_desc_t invalid_desc = test_dispatch_desc();
    invalid_desc.size = 0;
    if (expect_status(mgGraphAddDispatchNode(graph, &invalid_desc, &invalid, &error),
                      MG_STATUS_INVALID_ARGUMENT, "reject short dispatch descriptor")) {
        mgErrorDestroy(error);
        mgGraphDestroy(graph);
        return 19;
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
        return 20;
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
        return 21;
    }

    if (mgNodeId(first) == MG_NODE_ID_INVALID || mgNodeId(second) == MG_NODE_ID_INVALID) {
        fprintf(stderr, "node ids should be valid\n");
        mgGraphDestroy(graph);
        return 22;
    }

    if (expect_status(mgGraphAddDependency(graph, first, first, &error), MG_STATUS_INVALID_TOPOLOGY,
                      "reject self dependency")) {
        mgErrorDestroy(error);
        mgGraphDestroy(graph);
        return 23;
    }
    mgErrorDestroy(error);
    error = NULL;

    if (expect_status(mgGraphAddDependency(graph, first, second, &error), MG_STATUS_OK,
                      "add dependency") ||
        expect_status(mgGraphAddDependency(graph, first, second, &error), MG_STATUS_OK,
                      "ignore duplicate dependency") ||
        expect_status(mgGraphValidate(graph, &error), MG_STATUS_OK, "validate acyclic graph")) {
        mgGraphDestroy(graph);
        return 24;
    }

    mg_status_t cycle_status = mgGraphAddDependency(graph, second, first, &error);
    if (expect_status(cycle_status, MG_STATUS_OK, "add cycle edge")) {
        mgGraphDestroy(graph);
        return 25;
    }

    cycle_status = mgGraphValidate(graph, &error);
    if (expect_status(cycle_status, MG_STATUS_INVALID_TOPOLOGY, "validate cyclic graph")) {
        mgErrorDestroy(error);
        mgGraphDestroy(graph);
        return 26;
    }

    if (mgErrorStage(error) != MG_ERROR_STAGE_VALIDATE) {
        fprintf(stderr, "cycle error should come from validate stage\n");
        mgErrorDestroy(error);
        mgGraphDestroy(graph);
        return 27;
    }

    mgErrorDestroy(error);
    mgGraphDestroy(graph);
    return 0;
}
