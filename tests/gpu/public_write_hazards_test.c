#include "metal_graph/metal_graph.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void expect(mg_status_t actual, mg_status_t expected, mg_error_t **error) {
    if (actual != expected || (actual != MG_STATUS_OK && !*error)) {
        fprintf(stderr, "expected %s, got %s: %s\n", mgStatusString(expected),
                mgStatusString(actual), *error ? mgErrorMessage(*error) : "no error");
        exit(1);
    }
    mgErrorDestroy(*error);
    *error = NULL;
}

int main(void) {
    mg_error_t *error = NULL;
    mg_device_t *device = NULL;
    mg_stream_t *stream = NULL;
    mg_buffer_t *buffer = NULL;
    mg_status_t status = mgDeviceCreateSystemDefault(&device, &error);
    if (status == MG_STATUS_UNSUPPORTED) { mgErrorDestroy(error); return 77; }
    expect(status, MG_STATUS_OK, &error);
    expect(mgStreamCreate(device, &stream, &error), MG_STATUS_OK, &error);
    expect(mgBufferCreateShared(device, 16, &buffer, &error), MG_STATUS_OK, &error);
    for (int ordered = 0; ordered <= 1; ++ordered) {
        mg_graph_t *graph = NULL;
        mg_graph_exec_t *exec = NULL;
        mg_node_t *first = NULL, *second = NULL;
        mg_launch_t *launch = NULL;
        mg_fill_desc_t a = {0}, b = {0};
        a.size = b.size = sizeof(a);
        a.dst = b.dst = buffer;
        a.byte_count = b.byte_count = 8;
        a.value = 0x11;
        b.value = 0x22;
        expect(mgGraphCreate(&graph, &error), MG_STATUS_OK, &error);
        expect(mgGraphAddFillNode(graph, &a, &first, &error), MG_STATUS_OK, &error);
        // Initially overlapping writers require a dependency, even on one stream.
        expect(mgGraphAddFillNode(graph, &b, &second, &error), MG_STATUS_OK, &error);
        expect(mgGraphValidate(graph, &error), MG_STATUS_INVALID_TOPOLOGY, &error);
        mgGraphDestroy(graph);
        graph = NULL;
        b.dst_offset = 8;
        expect(mgGraphCreate(&graph, &error), MG_STATUS_OK, &error);
        expect(mgGraphAddFillNode(graph, &a, &first, &error), MG_STATUS_OK, &error);
        expect(mgGraphAddFillNode(graph, &b, &second, &error), MG_STATUS_OK, &error);
        expect(mgGraphSetNodePatchFlags(graph, second, MG_PATCH_FILL_RANGE, &error),
               MG_STATUS_OK, &error);
        if (ordered) {
            expect(mgGraphAddDependency(graph, first, second, &error), MG_STATUS_OK, &error);
        }
        mg_node_id_t id = mgNodeId(second);
        expect(mgGraphInstantiate(graph, device, &exec, &error), MG_STATUS_OK, &error);
        mgGraphDestroy(graph); // Dependency information survives the source graph.
        b.dst_offset = 4;
        expect(mgGraphExecPatchFillNode(exec, id, &b, &error),
               ordered ? MG_STATUS_OK : MG_STATUS_INVALID_TOPOLOGY, &error);
        memset(mgBufferContents(buffer), 0, 16);
        expect(mgGraphLaunch(exec, stream, &launch, &error), MG_STATUS_OK, &error);
        expect(mgLaunchSynchronize(launch, &error), MG_STATUS_OK, &error);
        for (size_t i = 0; i < 16; ++i) {
            unsigned char expected = ordered ? (i < 4 ? 0x11 : i < 12 ? 0x22 : 0)
                                             : (i < 8 ? 0x11 : 0x22);
            if (((const unsigned char *)mgBufferContents(buffer))[i] != expected) return 1;
        }
        mgLaunchDestroy(launch);
        mgGraphExecDestroy(exec);
    }
    mgBufferDestroy(buffer);
    mgStreamDestroy(stream);
    mgDeviceDestroy(device);
    puts("Public graph and patch write-hazard checks passed.");
    return 0;
}
