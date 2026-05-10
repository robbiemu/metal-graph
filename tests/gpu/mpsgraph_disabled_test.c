#include "metal_graph/metal_graph.h"

#include <stdio.h>
#include <string.h>

static void print_error(const char *label, mg_status_t status, mg_error_t *error) {
    fprintf(stderr, "%s failed: %s", label, mgStatusString(status));
    if (error) {
        fprintf(stderr, " stage=%d message=%s backend=%s", (int)mgErrorStage(error),
                mgErrorMessage(error), mgErrorBackendMessage(error));
    }
    fprintf(stderr, "\n");
}

static int expect_status(mg_status_t actual, mg_status_t expected, const char *label,
                         mg_error_t **error) {
    if (actual != expected) {
        print_error(label, actual, error ? *error : NULL);
        if (error) {
            mgErrorDestroy(*error);
            *error = NULL;
        }
        return 1;
    }
    if (error && *error) {
        mgErrorDestroy(*error);
        *error = NULL;
    }
    return 0;
}

int main(void) {
    int rc = 1;
    mg_error_t *error = NULL;
    mg_device_t *device = NULL;
    mg_buffer_t *buffer = NULL;
    mg_graph_t *graph = NULL;
    mg_graph_exec_t *exec = NULL;
    mg_node_t *node = NULL;
    size_t shape[1] = {4};

    mg_status_t status = mgDeviceCreateSystemDefault(&device, &error);
    if (status == MG_STATUS_UNSUPPORTED) {
        fprintf(stderr, "skipping: no system default Metal device\n");
        mgErrorDestroy(error);
        return 0;
    }
    if (expect_status(status, MG_STATUS_OK, "create device", &error) ||
        expect_status(mgBufferCreateShared(device, sizeof(float) * 4, &buffer, &error),
                      MG_STATUS_OK, "create buffer", &error) ||
        expect_status(mgGraphCreate(&graph, &error), MG_STATUS_OK, "create graph", &error)) {
        goto cleanup;
    }

    mg_mpsgraph_tensor_desc_t tensor;
    memset(&tensor, 0, sizeof(tensor));
    tensor.size = sizeof(tensor);
    tensor.buffer = buffer;
    tensor.data_type = MG_TENSOR_DATA_TYPE_FLOAT32;
    tensor.layout = MG_TENSOR_LAYOUT_CONTIGUOUS;
    tensor.rank = 1;
    tensor.shape = shape;

    mg_mpsgraph_desc_t desc;
    memset(&desc, 0, sizeof(desc));
    desc.size = sizeof(desc);
    desc.package_path = "/tmp/metal-graph-disabled-test.mpsgraphpackage";
    desc.feeds = &tensor;
    desc.feed_count = 1;
    desc.targets = &tensor;
    desc.target_count = 1;

    if (expect_status(mgGraphAddMPSGraphNode(graph, &desc, &node, &error), MG_STATUS_OK,
                      "add MPSGraph node", &error)) {
        goto cleanup;
    }

    status = mgGraphInstantiate(graph, device, &exec, &error);
    if (status != MG_STATUS_UNSUPPORTED) {
        if (status == MG_STATUS_OK) {
            mgGraphExecDestroy(exec);
            exec = NULL;
        }
        print_error("instantiate MPSGraph-disabled graph should fail", status, error);
        goto cleanup;
    }
    if (!error) {
        fprintf(stderr, "instantiate MPSGraph-disabled graph did not return an error object\n");
        goto cleanup;
    }
    if (mgErrorStage(error) != MG_ERROR_STAGE_INSTANTIATE) {
        print_error("instantiate MPSGraph-disabled graph returned wrong stage", status, error);
        goto cleanup;
    }
    const char *message = mgErrorMessage(error);
    if (!message || strstr(message, "MPSGraph") == NULL) {
        print_error("instantiate MPSGraph-disabled graph returned unhelpful message", status,
                    error);
        goto cleanup;
    }
    mgErrorDestroy(error);
    error = NULL;

    rc = 0;

cleanup:
    mgGraphExecDestroy(exec);
    mgGraphDestroy(graph);
    mgBufferDestroy(buffer);
    mgDeviceDestroy(device);
    mgErrorDestroy(error);
    return rc;
}
