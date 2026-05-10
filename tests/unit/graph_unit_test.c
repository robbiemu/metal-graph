#include "metal_graph/metal_graph.h"

#include <stdio.h>
#include <string.h>

static int expect_status(mg_status_t actual, mg_status_t expected, const char *label) {
    if (actual != expected) {
        fprintf(stderr, "%s: expected %s, got %s\n", label, mg_status_string(expected),
                mg_status_string(actual));
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
    mg_graph_t *graph = NULL;
    if (expect_status(mg_graph_create(&graph, &error), MG_STATUS_OK, "create graph")) {
        return 1;
    }

    if (expect_status(mg_graph_validate(graph, &error), MG_STATUS_OK, "validate empty graph")) {
        mg_graph_destroy(graph);
        return 2;
    }

    mg_dispatch_desc_t desc = test_dispatch_desc();
    mg_node_t *first = NULL;
    mg_node_t *second = NULL;
    if (expect_status(mg_graph_add_dispatch_node(graph, &desc, &first, &error), MG_STATUS_OK,
                      "add first node") ||
        expect_status(mg_graph_add_dispatch_node(graph, &desc, &second, &error), MG_STATUS_OK,
                      "add second node")) {
        mg_graph_destroy(graph);
        return 3;
    }

    if (mg_node_id(first) == MG_NODE_ID_INVALID || mg_node_id(second) == MG_NODE_ID_INVALID) {
        fprintf(stderr, "node ids should be valid\n");
        mg_graph_destroy(graph);
        return 4;
    }

    if (expect_status(mg_graph_add_dependency(graph, first, second, &error), MG_STATUS_OK,
                      "add dependency") ||
        expect_status(mg_graph_validate(graph, &error), MG_STATUS_OK, "validate acyclic graph")) {
        mg_graph_destroy(graph);
        return 5;
    }

    mg_status_t cycle_status = mg_graph_add_dependency(graph, second, first, &error);
    if (expect_status(cycle_status, MG_STATUS_OK, "add cycle edge")) {
        mg_graph_destroy(graph);
        return 6;
    }

    cycle_status = mg_graph_validate(graph, &error);
    if (expect_status(cycle_status, MG_STATUS_INVALID_TOPOLOGY, "validate cyclic graph")) {
        mg_error_destroy(error);
        mg_graph_destroy(graph);
        return 7;
    }

    if (mg_error_stage(error) != MG_ERROR_STAGE_VALIDATE) {
        fprintf(stderr, "cycle error should come from validate stage\n");
        mg_error_destroy(error);
        mg_graph_destroy(graph);
        return 8;
    }

    mg_error_destroy(error);
    mg_graph_destroy(graph);
    return 0;
}
