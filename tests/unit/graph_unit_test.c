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
    if (expect_status(mg_graph_create(NULL, &error), MG_STATUS_INVALID_ARGUMENT,
                      "create graph with null output")) {
        mg_error_destroy(error);
        return 1;
    }
    mg_error_destroy(error);
    error = NULL;

    mg_graph_t *graph = NULL;
    if (expect_status(mg_graph_create(&graph, &error), MG_STATUS_OK, "create graph")) {
        return 2;
    }

    if (expect_status(mg_graph_validate(graph, &error), MG_STATUS_OK, "validate empty graph")) {
        mg_graph_destroy(graph);
        return 3;
    }

    mg_node_t *invalid = NULL;
    if (expect_status(mg_graph_add_copy_node(graph, NULL, &invalid, &error),
                      MG_STATUS_INVALID_ARGUMENT, "reject null copy descriptor")) {
        mg_error_destroy(error);
        mg_graph_destroy(graph);
        return 4;
    }
    mg_error_destroy(error);
    error = NULL;

    mg_copy_desc_t invalid_copy;
    memset(&invalid_copy, 0, sizeof(invalid_copy));
    invalid_copy.size = sizeof(invalid_copy);
    invalid_copy.byte_count = 1;
    if (expect_status(mg_graph_add_copy_node(graph, &invalid_copy, &invalid, &error),
                      MG_STATUS_INVALID_ARGUMENT, "reject invalid copy descriptor")) {
        mg_error_destroy(error);
        mg_graph_destroy(graph);
        return 5;
    }
    mg_error_destroy(error);
    error = NULL;

    if (expect_status(mg_graph_add_fill_node(graph, NULL, &invalid, &error),
                      MG_STATUS_INVALID_ARGUMENT, "reject null fill descriptor")) {
        mg_error_destroy(error);
        mg_graph_destroy(graph);
        return 6;
    }
    mg_error_destroy(error);
    error = NULL;

    mg_fill_desc_t invalid_fill;
    memset(&invalid_fill, 0, sizeof(invalid_fill));
    invalid_fill.size = sizeof(invalid_fill);
    invalid_fill.byte_count = 1;
    if (expect_status(mg_graph_add_fill_node(graph, &invalid_fill, &invalid, &error),
                      MG_STATUS_INVALID_ARGUMENT, "reject invalid fill descriptor")) {
        mg_error_destroy(error);
        mg_graph_destroy(graph);
        return 7;
    }
    mg_error_destroy(error);
    error = NULL;

    if (expect_status(mg_graph_add_event_wait_node(graph, NULL, 1, &invalid, &error),
                      MG_STATUS_INVALID_ARGUMENT, "reject null event wait")) {
        mg_error_destroy(error);
        mg_graph_destroy(graph);
        return 8;
    }
    mg_error_destroy(error);
    error = NULL;

    if (expect_status(mg_graph_add_event_signal_node(graph, NULL, 1, &invalid, &error),
                      MG_STATUS_INVALID_ARGUMENT, "reject null event signal")) {
        mg_error_destroy(error);
        mg_graph_destroy(graph);
        return 9;
    }
    mg_error_destroy(error);
    error = NULL;

    if (expect_status(mg_graph_add_barrier_node(NULL, &invalid, &error), MG_STATUS_INVALID_ARGUMENT,
                      "reject null barrier graph")) {
        mg_error_destroy(error);
        mg_graph_destroy(graph);
        return 10;
    }
    mg_error_destroy(error);
    error = NULL;

    mg_dispatch_desc_t invalid_desc = test_dispatch_desc();
    invalid_desc.size = 0;
    if (expect_status(mg_graph_add_dispatch_node(graph, &invalid_desc, &invalid, &error),
                      MG_STATUS_INVALID_ARGUMENT, "reject short dispatch descriptor")) {
        mg_error_destroy(error);
        mg_graph_destroy(graph);
        return 11;
    }
    mg_error_destroy(error);
    error = NULL;

    invalid_desc = test_dispatch_desc();
    mg_buffer_binding_t invalid_binding = {0};
    invalid_desc.buffers = &invalid_binding;
    invalid_desc.buffer_count = 1;
    if (expect_status(mg_graph_add_dispatch_node(graph, &invalid_desc, &invalid, &error),
                      MG_STATUS_INVALID_ARGUMENT, "reject invalid buffer binding")) {
        mg_error_destroy(error);
        mg_graph_destroy(graph);
        return 12;
    }
    mg_error_destroy(error);
    error = NULL;

    mg_dispatch_desc_t desc = test_dispatch_desc();
    mg_node_t *first = NULL;
    mg_node_t *second = NULL;
    if (expect_status(mg_graph_add_dispatch_node(graph, &desc, &first, &error), MG_STATUS_OK,
                      "add first node") ||
        expect_status(mg_graph_add_dispatch_node(graph, &desc, &second, &error), MG_STATUS_OK,
                      "add second node")) {
        mg_graph_destroy(graph);
        return 13;
    }

    if (mg_node_id(first) == MG_NODE_ID_INVALID || mg_node_id(second) == MG_NODE_ID_INVALID) {
        fprintf(stderr, "node ids should be valid\n");
        mg_graph_destroy(graph);
        return 14;
    }

    if (expect_status(mg_graph_add_dependency(graph, first, first, &error),
                      MG_STATUS_INVALID_TOPOLOGY, "reject self dependency")) {
        mg_error_destroy(error);
        mg_graph_destroy(graph);
        return 15;
    }
    mg_error_destroy(error);
    error = NULL;

    if (expect_status(mg_graph_add_dependency(graph, first, second, &error), MG_STATUS_OK,
                      "add dependency") ||
        expect_status(mg_graph_add_dependency(graph, first, second, &error), MG_STATUS_OK,
                      "ignore duplicate dependency") ||
        expect_status(mg_graph_validate(graph, &error), MG_STATUS_OK, "validate acyclic graph")) {
        mg_graph_destroy(graph);
        return 16;
    }

    mg_status_t cycle_status = mg_graph_add_dependency(graph, second, first, &error);
    if (expect_status(cycle_status, MG_STATUS_OK, "add cycle edge")) {
        mg_graph_destroy(graph);
        return 17;
    }

    cycle_status = mg_graph_validate(graph, &error);
    if (expect_status(cycle_status, MG_STATUS_INVALID_TOPOLOGY, "validate cyclic graph")) {
        mg_error_destroy(error);
        mg_graph_destroy(graph);
        return 18;
    }

    if (mg_error_stage(error) != MG_ERROR_STAGE_VALIDATE) {
        fprintf(stderr, "cycle error should come from validate stage\n");
        mg_error_destroy(error);
        mg_graph_destroy(graph);
        return 19;
    }

    mg_error_destroy(error);
    mg_graph_destroy(graph);
    return 0;
}
