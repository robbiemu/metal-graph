#include "metal_graph/metal_graph.h"

#include <stdint.h>
#include <stdio.h>
#include <string.h>

static int fail_with_error(const char *label, mg_status_t status, mg_error_t *error) {
    fprintf(stderr, "%s failed: %s", label, mg_status_string(status));
    if (error) {
        fprintf(stderr, " stage=%d message=%s backend=%s", (int)mg_error_stage(error),
                mg_error_message(error), mg_error_backend_message(error));
    }
    fprintf(stderr, "\n");
    mg_error_destroy(error);
    return 1;
}

int main(void) {
    mg_error_t *error = NULL;
    mg_device_t *device = NULL;
    mg_status_t status = mg_device_create_system_default(&device, &error);
    if (status == MG_STATUS_UNSUPPORTED) {
        fprintf(stderr, "skipping: no system default Metal device\n");
        mg_error_destroy(error);
        return 0;
    }
    if (status != MG_STATUS_OK) {
        return fail_with_error("create device", status, error);
    }

    mg_stream_t *stream = NULL;
    status = mg_stream_create(device, &stream, &error);
    if (status != MG_STATUS_OK) {
        mg_device_destroy(device);
        return fail_with_error("create stream", status, error);
    }

    mg_buffer_t *buffer = NULL;
    status = mg_buffer_create_shared(device, sizeof(uint32_t) * 4, &buffer, &error);
    if (status != MG_STATUS_OK) {
        mg_stream_destroy(stream);
        mg_device_destroy(device);
        return fail_with_error("create buffer", status, error);
    }

    uint32_t *values = (uint32_t *)mg_buffer_contents(buffer);
    if (!values) {
        mg_buffer_destroy(buffer);
        mg_stream_destroy(stream);
        mg_device_destroy(device);
        fprintf(stderr, "shared buffer contents are unavailable\n");
        return 1;
    }

    values[0] = 10;
    values[1] = 20;
    values[2] = 30;
    values[3] = 40;

    mg_buffer_binding_t binding = {
        0,
        buffer,
        0,
    };

    mg_dispatch_desc_t desc;
    memset(&desc, 0, sizeof(desc));
    desc.size = sizeof(desc);
    desc.metallib_path = TEST_METALLIB_PATH;
    desc.kernel_name = "mg_phase0_add_one";
    desc.grid_size[0] = 4;
    desc.grid_size[1] = 1;
    desc.grid_size[2] = 1;
    desc.threads_per_threadgroup[0] = 1;
    desc.threads_per_threadgroup[1] = 1;
    desc.threads_per_threadgroup[2] = 1;
    desc.buffers = &binding;
    desc.buffer_count = 1;

    mg_graph_t *graph = NULL;
    mg_node_t *node = NULL;
    mg_graph_exec_t *exec = NULL;
    mg_launch_t *launch = NULL;

    status = mg_graph_create(&graph, &error);
    if (status != MG_STATUS_OK) {
        mg_buffer_destroy(buffer);
        mg_stream_destroy(stream);
        mg_device_destroy(device);
        return fail_with_error("create graph", status, error);
    }

    status = mg_graph_add_dispatch_node(graph, &desc, &node, &error);
    if (status != MG_STATUS_OK) {
        mg_graph_destroy(graph);
        mg_buffer_destroy(buffer);
        mg_stream_destroy(stream);
        mg_device_destroy(device);
        return fail_with_error("add dispatch", status, error);
    }

    status = mg_graph_instantiate(graph, device, &exec, &error);
    mg_graph_destroy(graph);
    if (status != MG_STATUS_OK) {
        mg_buffer_destroy(buffer);
        mg_stream_destroy(stream);
        mg_device_destroy(device);
        return fail_with_error("instantiate graph", status, error);
    }

    mg_buffer_destroy(buffer);

    status = mg_graph_launch(exec, stream, &launch, &error);
    if (status != MG_STATUS_OK) {
        mg_graph_exec_destroy(exec);
        mg_stream_destroy(stream);
        mg_device_destroy(device);
        return fail_with_error("launch graph", status, error);
    }

    status = mg_launch_synchronize(launch, &error);
    if (status != MG_STATUS_OK) {
        mg_launch_destroy(launch);
        mg_graph_exec_destroy(exec);
        mg_stream_destroy(stream);
        mg_device_destroy(device);
        return fail_with_error("synchronize launch", status, error);
    }

    int failed = 0;
    if (values[0] != 11 || values[1] != 21 || values[2] != 31 || values[3] != 41) {
        fprintf(stderr, "unexpected GPU results: %u %u %u %u\n", values[0], values[1], values[2],
                values[3]);
        failed = 1;
    }

    mg_launch_destroy(launch);
    mg_graph_exec_destroy(exec);
    mg_stream_destroy(stream);
    mg_device_destroy(device);
    return failed;
}
