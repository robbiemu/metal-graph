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

    mg_graph_t *empty_graph = NULL;
    mg_graph_exec_t *empty_exec = NULL;
    mg_launch_t *empty_launch = NULL;
    status = mg_graph_create(&empty_graph, &error);
    if (status != MG_STATUS_OK) {
        mg_buffer_destroy(buffer);
        mg_stream_destroy(stream);
        mg_device_destroy(device);
        return fail_with_error("create empty graph", status, error);
    }
    status = mg_graph_instantiate(empty_graph, device, &empty_exec, &error);
    mg_graph_destroy(empty_graph);
    if (status != MG_STATUS_OK) {
        mg_buffer_destroy(buffer);
        mg_stream_destroy(stream);
        mg_device_destroy(device);
        return fail_with_error("instantiate empty graph", status, error);
    }
    status = mg_graph_launch(empty_exec, stream, &empty_launch, &error);
    if (status != MG_STATUS_OK) {
        mg_graph_exec_destroy(empty_exec);
        mg_buffer_destroy(buffer);
        mg_stream_destroy(stream);
        mg_device_destroy(device);
        return fail_with_error("launch empty graph", status, error);
    }
    status = mg_launch_synchronize(empty_launch, &error);
    if (status != MG_STATUS_OK) {
        mg_launch_destroy(empty_launch);
        mg_graph_exec_destroy(empty_exec);
        mg_buffer_destroy(buffer);
        mg_stream_destroy(stream);
        mg_device_destroy(device);
        return fail_with_error("sync empty graph", status, error);
    }
    mg_launch_destroy(empty_launch);
    mg_graph_exec_destroy(empty_exec);

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

    mg_dispatch_desc_t bad_kernel_desc = desc;
    bad_kernel_desc.kernel_name = "mg_missing_kernel";
    mg_graph_t *bad_graph = NULL;
    mg_node_t *bad_node = NULL;
    mg_graph_exec_t *bad_exec = NULL;
    status = mg_graph_create(&bad_graph, &error);
    if (status != MG_STATUS_OK) {
        mg_buffer_destroy(buffer);
        mg_stream_destroy(stream);
        mg_device_destroy(device);
        return fail_with_error("create bad graph", status, error);
    }
    status = mg_graph_add_dispatch_node(bad_graph, &bad_kernel_desc, &bad_node, &error);
    if (status != MG_STATUS_OK) {
        mg_graph_destroy(bad_graph);
        mg_buffer_destroy(buffer);
        mg_stream_destroy(stream);
        mg_device_destroy(device);
        return fail_with_error("add bad dispatch", status, error);
    }
    status = mg_graph_instantiate(bad_graph, device, &bad_exec, &error);
    mg_graph_destroy(bad_graph);
    if (status != MG_STATUS_BACKEND_ERROR) {
        if (status == MG_STATUS_OK) {
            mg_graph_exec_destroy(bad_exec);
        }
        mg_buffer_destroy(buffer);
        mg_stream_destroy(stream);
        mg_device_destroy(device);
        return fail_with_error("instantiate bad graph should fail", status, error);
    }
    mg_error_destroy(error);
    error = NULL;

    mg_graph_t *cycle_graph = NULL;
    mg_node_t *cycle_first = NULL;
    mg_node_t *cycle_second = NULL;
    mg_graph_exec_t *cycle_exec = NULL;
    status = mg_graph_create(&cycle_graph, &error);
    if (status != MG_STATUS_OK) {
        mg_buffer_destroy(buffer);
        mg_stream_destroy(stream);
        mg_device_destroy(device);
        return fail_with_error("create cycle graph", status, error);
    }
    status = mg_graph_add_dispatch_node(cycle_graph, &desc, &cycle_first, &error);
    if (status == MG_STATUS_OK) {
        status = mg_graph_add_dispatch_node(cycle_graph, &desc, &cycle_second, &error);
    }
    if (status == MG_STATUS_OK) {
        status = mg_graph_add_dependency(cycle_graph, cycle_first, cycle_second, &error);
    }
    if (status == MG_STATUS_OK) {
        status = mg_graph_add_dependency(cycle_graph, cycle_second, cycle_first, &error);
    }
    if (status != MG_STATUS_OK) {
        mg_graph_destroy(cycle_graph);
        mg_buffer_destroy(buffer);
        mg_stream_destroy(stream);
        mg_device_destroy(device);
        return fail_with_error("build cycle graph", status, error);
    }
    status = mg_graph_instantiate(cycle_graph, device, &cycle_exec, &error);
    mg_graph_destroy(cycle_graph);
    if (status != MG_STATUS_INVALID_TOPOLOGY) {
        if (status == MG_STATUS_OK) {
            mg_graph_exec_destroy(cycle_exec);
        }
        mg_buffer_destroy(buffer);
        mg_stream_destroy(stream);
        mg_device_destroy(device);
        return fail_with_error("instantiate cycle graph should fail", status, error);
    }
    mg_error_destroy(error);
    error = NULL;

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
    launch = NULL;

    status = mg_graph_launch(exec, stream, &launch, &error);
    if (status != MG_STATUS_OK) {
        mg_graph_exec_destroy(exec);
        mg_buffer_destroy(buffer);
        mg_stream_destroy(stream);
        mg_device_destroy(device);
        return fail_with_error("relaunch graph", status, error);
    }

    status = mg_launch_synchronize(launch, &error);
    if (status != MG_STATUS_OK) {
        mg_launch_destroy(launch);
        mg_graph_exec_destroy(exec);
        mg_buffer_destroy(buffer);
        mg_stream_destroy(stream);
        mg_device_destroy(device);
        return fail_with_error("synchronize relaunch", status, error);
    }

    if (values[0] != 12 || values[1] != 22 || values[2] != 32 || values[3] != 42) {
        fprintf(stderr, "unexpected GPU relaunch results: %u %u %u %u\n", values[0], values[1],
                values[2], values[3]);
        failed = 1;
    }

    mg_launch_destroy(launch);
    mg_graph_exec_destroy(exec);
    mg_buffer_destroy(buffer);
    mg_stream_destroy(stream);
    mg_device_destroy(device);
    return failed;
}
