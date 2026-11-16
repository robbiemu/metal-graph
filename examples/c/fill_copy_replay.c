#include "metal_graph/metal_graph.h"

#include <inttypes.h>
#include <stdio.h>
#include <string.h>

/* Keep error handling out of the graph-building steps, but retain structured diagnostics. */
#define CHECK(call)                                                                                \
    do {                                                                                           \
        status = (call);                                                                           \
        if (status != MG_STATUS_OK)                                                                \
            goto cleanup;                                                                          \
    } while (0)

int main(void) {
    const size_t byte_count = 32;
    const unsigned char value = 0x2A;
    int result = 1;
    mg_status_t status = MG_STATUS_OK;
    mg_error_t *error = NULL;
    mg_device_t *device = NULL;
    mg_stream_t *stream = NULL;
    mg_buffer_t *source = NULL, *destination = NULL;
    mg_graph_t *graph = NULL;
    mg_graph_exec_t *exec = NULL;
    mg_launch_t *launch = NULL;
    mg_node_t *fill = NULL, *copy = NULL;

    CHECK(mgDeviceCreateSystemDefault(&device, &error));
    CHECK(mgStreamCreate(device, &stream, &error));
    CHECK(mgBufferCreateShared(device, byte_count, &source, &error));
    CHECK(mgBufferCreateShared(device, byte_count, &destination, &error));
    CHECK(mgGraphCreate(&graph, &error));

    mg_fill_desc_t fill_desc = {0};
    fill_desc.size = sizeof(fill_desc);
    fill_desc.dst = source;
    fill_desc.byte_count = byte_count;
    fill_desc.value = value;
    CHECK(mgGraphAddFillNode(graph, &fill_desc, &fill, &error));

    mg_copy_desc_t copy_desc = {0};
    copy_desc.size = sizeof(copy_desc);
    copy_desc.src = source;
    copy_desc.dst = destination;
    copy_desc.byte_count = byte_count;
    CHECK(mgGraphAddCopyNode(graph, &copy_desc, &copy, &error));
    CHECK(mgGraphAddDependency(graph, fill, copy, &error));

    /* Prepare once. The exec owns a snapshot and can outlive the source graph. */
    CHECK(mgGraphInstantiate(graph, device, &exec, &error));
    mgGraphDestroy(graph);
    graph = NULL;

    for (unsigned int replay = 1; replay <= 2; ++replay) {
        unsigned char *bytes = mgBufferContents(destination);
        /* No launch is in flight here, so the CPU may clear the shared destination. */
        memset(bytes, 0, byte_count);
        CHECK(mgGraphLaunch(exec, stream, &launch, &error));
        /* Acceptance is not completion. Check deferred errors before reading or replaying. */
        CHECK(mgLaunchSynchronize(launch, &error));
        for (size_t i = 0; i < byte_count; ++i) {
            if (bytes[i] != value) {
                fprintf(stderr, "Replay %u: byte %zu is 0x%02X, expected 0x%02X.\n", replay, i,
                        (unsigned int)bytes[i], (unsigned int)value);
                goto cleanup;
            }
        }
        printf("Replay %u: all %zu bytes are 0x%02X.\n", replay, byte_count, (unsigned int)value);
        mgLaunchDestroy(launch);
        launch = NULL;
    }
    result = 0;

cleanup:
    if (status != MG_STATUS_OK) {
        fprintf(stderr, "%s: %s\n", mgStatusString(status), mgErrorMessage(error));
        fprintf(stderr, "stage=%d node=%" PRIu64 "\n", (int)mgErrorStage(error),
                mgErrorNodeId(error));
        const char *backend = mgErrorBackendMessage(error);
        if (backend && backend[0])
            fprintf(stderr, "backend: %s\n", backend);
    }
    mgErrorDestroy(error);
    mgLaunchDestroy(launch);
    mgGraphExecDestroy(exec);
    mgGraphDestroy(graph);
    mgBufferDestroy(destination);
    mgBufferDestroy(source);
    mgStreamDestroy(stream);
    mgDeviceDestroy(device);
    return result;
}
