#include "metal_graph/metal_graph.h"

#include <stdint.h>
#include <stdio.h>
#include <string.h>

static void print_error(const char *label, mg_status_t status, mg_error_t *error) {
    fprintf(stderr, "%s failed: %s", label, mgStatusString(status));
    if (error) {
        fprintf(stderr, " stage=%d message=%s backend=%s", (int)mgErrorStage(error),
                mgErrorMessage(error), mgErrorBackendMessage(error));
    }
    fprintf(stderr, "\n");
    mgErrorDestroy(error);
}

static int expect_status(mg_status_t actual, mg_status_t expected, const char *label,
                         mg_error_t **error) {
    if (actual != expected) {
        print_error(label, actual, error ? *error : NULL);
        if (error) {
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

static mg_dispatch_desc_t add_one_desc(mg_buffer_t *buffer) {
    static mg_buffer_binding_t binding;
    binding.index = 0;
    binding.buffer = buffer;
    binding.offset = 0;

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
    return desc;
}

static int check_values(const uint32_t *values, uint32_t a, uint32_t b, uint32_t c, uint32_t d,
                        const char *label) {
    if (values[0] != a || values[1] != b || values[2] != c || values[3] != d) {
        fprintf(stderr, "%s: unexpected values: %u %u %u %u\n", label, values[0], values[1],
                values[2], values[3]);
        return 1;
    }
    return 0;
}

static int check_fill(const uint8_t *values, uint8_t expected, const char *label) {
    for (size_t i = 0; i < 8; ++i) {
        if (values[i] != expected) {
            fprintf(stderr, "%s: byte %zu expected %u got %u\n", label, i, expected, values[i]);
            return 1;
        }
    }
    return 0;
}

int main(void) {
    int rc = 1;
    mg_error_t *error = NULL;
    mg_device_t *device = NULL;
    mg_stream_t *stream = NULL;
    mg_buffer_t *dst_buffer = NULL;
    mg_buffer_t *src_buffer = NULL;
    mg_buffer_t *fill_buffer = NULL;
    mg_event_t *event = NULL;
    mg_graph_t *graph = NULL;
    mg_graph_exec_t *exec = NULL;
    mg_launch_t *launch = NULL;

    mg_status_t status = mgDeviceCreateSystemDefault(&device, &error);
    if (status == MG_STATUS_UNSUPPORTED) {
        fprintf(stderr, "skipping: no system default Metal device\n");
        mgErrorDestroy(error);
        return 0;
    }
    if (expect_status(status, MG_STATUS_OK, "create device", &error)) {
        return 1;
    }

    if (expect_status(mgStreamCreate(device, &stream, &error), MG_STATUS_OK, "create stream",
                      &error) ||
        expect_status(mgBufferCreateShared(device, sizeof(uint32_t) * 4, &dst_buffer, &error),
                      MG_STATUS_OK, "create destination buffer", &error) ||
        expect_status(mgBufferCreateShared(device, sizeof(uint32_t) * 4, &src_buffer, &error),
                      MG_STATUS_OK, "create source buffer", &error) ||
        expect_status(mgBufferCreateShared(device, 8, &fill_buffer, &error), MG_STATUS_OK,
                      "create fill buffer", &error)) {
        goto cleanup;
    }

    uint32_t *dst_values = (uint32_t *)mgBufferContents(dst_buffer);
    uint32_t *src_values = (uint32_t *)mgBufferContents(src_buffer);
    uint8_t *fill_values = (uint8_t *)mgBufferContents(fill_buffer);
    if (!dst_values || !src_values || !fill_values) {
        fprintf(stderr, "shared buffer contents are unavailable\n");
        goto cleanup;
    }

    if (expect_status(mgEventCreate(device, &event, &error), MG_STATUS_OK, "create event",
                      &error)) {
        goto cleanup;
    }

    mg_graph_t *empty_graph = NULL;
    mg_graph_exec_t *empty_exec = NULL;
    mg_launch_t *empty_launch = NULL;
    if (expect_status(mgGraphCreate(&empty_graph, &error), MG_STATUS_OK, "create empty graph",
                      &error) ||
        expect_status(mgGraphInstantiate(empty_graph, device, &empty_exec, &error), MG_STATUS_OK,
                      "instantiate empty graph", &error) ||
        expect_status(mgGraphLaunch(empty_exec, stream, &empty_launch, &error), MG_STATUS_OK,
                      "launch empty graph", &error) ||
        expect_status(mgLaunchSynchronize(empty_launch, &error), MG_STATUS_OK, "sync empty graph",
                      &error)) {
        mgLaunchDestroy(empty_launch);
        mgGraphExecDestroy(empty_exec);
        mgGraphDestroy(empty_graph);
        goto cleanup;
    }
    mgLaunchDestroy(empty_launch);
    mgGraphExecDestroy(empty_exec);
    mgGraphDestroy(empty_graph);

    mg_dispatch_desc_t dispatch_desc = add_one_desc(dst_buffer);
    mg_dispatch_desc_t bad_kernel_desc = dispatch_desc;
    bad_kernel_desc.kernel_name = "mg_missing_kernel";
    mg_graph_t *bad_graph = NULL;
    mg_node_t *bad_node = NULL;
    mg_graph_exec_t *bad_exec = NULL;
    if (expect_status(mgGraphCreate(&bad_graph, &error), MG_STATUS_OK, "create bad graph",
                      &error) ||
        expect_status(mgGraphAddDispatchNode(bad_graph, &bad_kernel_desc, &bad_node, &error),
                      MG_STATUS_OK, "add bad dispatch", &error)) {
        mgGraphDestroy(bad_graph);
        goto cleanup;
    }
    status = mgGraphInstantiate(bad_graph, device, &bad_exec, &error);
    mgGraphDestroy(bad_graph);
    if (status != MG_STATUS_BACKEND_ERROR) {
        if (status == MG_STATUS_OK) {
            mgGraphExecDestroy(bad_exec);
        }
        print_error("instantiate bad graph should fail", status, error);
        error = NULL;
        goto cleanup;
    }
    mgErrorDestroy(error);
    error = NULL;

    mg_graph_t *cycle_graph = NULL;
    mg_node_t *cycle_first = NULL;
    mg_node_t *cycle_second = NULL;
    mg_graph_exec_t *cycle_exec = NULL;
    if (expect_status(mgGraphCreate(&cycle_graph, &error), MG_STATUS_OK, "create cycle graph",
                      &error) ||
        expect_status(mgGraphAddDispatchNode(cycle_graph, &dispatch_desc, &cycle_first, &error),
                      MG_STATUS_OK, "add cycle first", &error) ||
        expect_status(mgGraphAddDispatchNode(cycle_graph, &dispatch_desc, &cycle_second, &error),
                      MG_STATUS_OK, "add cycle second", &error) ||
        expect_status(mgGraphAddDependency(cycle_graph, cycle_first, cycle_second, &error),
                      MG_STATUS_OK, "add cycle edge a", &error) ||
        expect_status(mgGraphAddDependency(cycle_graph, cycle_second, cycle_first, &error),
                      MG_STATUS_OK, "add cycle edge b", &error)) {
        mgGraphDestroy(cycle_graph);
        goto cleanup;
    }
    status = mgGraphInstantiate(cycle_graph, device, &cycle_exec, &error);
    mgGraphDestroy(cycle_graph);
    if (status != MG_STATUS_INVALID_TOPOLOGY) {
        if (status == MG_STATUS_OK) {
            mgGraphExecDestroy(cycle_exec);
        }
        print_error("instantiate cycle graph should fail", status, error);
        error = NULL;
        goto cleanup;
    }
    mgErrorDestroy(error);
    error = NULL;

    mg_copy_desc_t invalid_copy;
    memset(&invalid_copy, 0, sizeof(invalid_copy));
    invalid_copy.size = sizeof(invalid_copy);
    invalid_copy.src = src_buffer;
    invalid_copy.dst = dst_buffer;
    invalid_copy.byte_count = 0;
    if (expect_status(mgGraphCreate(&graph, &error), MG_STATUS_OK, "create validation graph",
                      &error) ||
        expect_status(mgGraphAddCopyNode(graph, &invalid_copy, &bad_node, &error),
                      MG_STATUS_INVALID_ARGUMENT, "reject zero copy", &error)) {
        goto cleanup;
    }
    mg_fill_desc_t invalid_fill;
    memset(&invalid_fill, 0, sizeof(invalid_fill));
    invalid_fill.size = sizeof(invalid_fill);
    invalid_fill.dst = fill_buffer;
    invalid_fill.byte_count = 0;
    if (expect_status(mgGraphAddFillNode(graph, &invalid_fill, &bad_node, &error),
                      MG_STATUS_INVALID_ARGUMENT, "reject zero fill", &error) ||
        expect_status(mgGraphAddEventWaitNode(graph, NULL, 0, &bad_node, &error),
                      MG_STATUS_INVALID_ARGUMENT, "reject null event wait", &error)) {
        goto cleanup;
    }
    mgGraphDestroy(graph);
    graph = NULL;

    src_values[0] = 100;
    src_values[1] = 200;
    src_values[2] = 300;
    src_values[3] = 400;
    memset(dst_values, 0, sizeof(uint32_t) * 4);
    memset(fill_values, 0, 8);

    mg_node_t *wait_node = NULL;
    mg_node_t *copy_node = NULL;
    mg_node_t *fill_node = NULL;
    mg_node_t *barrier_node = NULL;
    mg_node_t *dispatch_node = NULL;
    mg_node_t *signal_node = NULL;
    mg_copy_desc_t copy_desc;
    memset(&copy_desc, 0, sizeof(copy_desc));
    copy_desc.size = sizeof(copy_desc);
    copy_desc.src = src_buffer;
    copy_desc.dst = dst_buffer;
    copy_desc.byte_count = sizeof(uint32_t) * 4;
    mg_fill_desc_t fill_desc;
    memset(&fill_desc, 0, sizeof(fill_desc));
    fill_desc.size = sizeof(fill_desc);
    fill_desc.dst = fill_buffer;
    fill_desc.byte_count = 8;
    fill_desc.value = 0xAB;

    if (expect_status(mgGraphCreate(&graph, &error), MG_STATUS_OK, "create phase1 graph", &error) ||
        expect_status(mgGraphAddEventWaitNode(graph, event, 0, &wait_node, &error), MG_STATUS_OK,
                      "add event wait", &error) ||
        expect_status(mgGraphAddCopyNode(graph, &copy_desc, &copy_node, &error), MG_STATUS_OK,
                      "add copy", &error) ||
        expect_status(mgGraphAddFillNode(graph, &fill_desc, &fill_node, &error), MG_STATUS_OK,
                      "add fill", &error) ||
        expect_status(mgGraphAddBarrierNode(graph, &barrier_node, &error), MG_STATUS_OK,
                      "add barrier", &error) ||
        expect_status(mgGraphAddDispatchNode(graph, &dispatch_desc, &dispatch_node, &error),
                      MG_STATUS_OK, "add dispatch", &error) ||
        expect_status(mgGraphAddEventSignalNode(graph, event, 1, &signal_node, &error),
                      MG_STATUS_OK, "add event signal", &error) ||
        expect_status(mgGraphAddDependency(graph, wait_node, copy_node, &error), MG_STATUS_OK,
                      "add wait-copy dependency", &error) ||
        expect_status(mgGraphAddDependency(graph, wait_node, fill_node, &error), MG_STATUS_OK,
                      "add wait-fill dependency", &error) ||
        expect_status(mgGraphAddDependency(graph, copy_node, barrier_node, &error), MG_STATUS_OK,
                      "add copy-barrier dependency", &error) ||
        expect_status(mgGraphAddDependency(graph, fill_node, barrier_node, &error), MG_STATUS_OK,
                      "add fill-barrier dependency", &error) ||
        expect_status(mgGraphAddDependency(graph, barrier_node, dispatch_node, &error),
                      MG_STATUS_OK, "add barrier-dispatch dependency", &error) ||
        expect_status(mgGraphAddDependency(graph, dispatch_node, signal_node, &error), MG_STATUS_OK,
                      "add dispatch-signal dependency", &error) ||
        expect_status(mgGraphInstantiate(graph, device, &exec, &error), MG_STATUS_OK,
                      "instantiate phase1 graph", &error)) {
        goto cleanup;
    }
    mgGraphDestroy(graph);
    graph = NULL;
    mgEventDestroy(event);
    event = NULL;
    mgBufferDestroy(fill_buffer);
    fill_buffer = NULL;
    mgBufferDestroy(src_buffer);
    src_buffer = NULL;
    mgBufferDestroy(dst_buffer);
    dst_buffer = NULL;

    if (expect_status(mgGraphLaunch(exec, stream, &launch, &error), MG_STATUS_OK,
                      "launch phase1 graph", &error) ||
        expect_status(mgLaunchSynchronize(launch, &error), MG_STATUS_OK, "sync phase1 graph",
                      &error)) {
        goto cleanup;
    }
    mgLaunchDestroy(launch);
    launch = NULL;
    if (check_values(dst_values, 101, 201, 301, 401, "phase1 first launch") ||
        check_fill(fill_values, 0xAB, "phase1 first fill")) {
        goto cleanup;
    }

    src_values[0] = 7;
    src_values[1] = 8;
    src_values[2] = 9;
    src_values[3] = 10;
    memset(dst_values, 0, sizeof(uint32_t) * 4);
    memset(fill_values, 0, 8);
    if (expect_status(mgGraphLaunch(exec, stream, &launch, &error), MG_STATUS_OK,
                      "relaunch phase1 graph", &error) ||
        expect_status(mgLaunchSynchronize(launch, &error), MG_STATUS_OK, "sync phase1 relaunch",
                      &error)) {
        goto cleanup;
    }
    if (check_values(dst_values, 8, 9, 10, 11, "phase1 relaunch") ||
        check_fill(fill_values, 0xAB, "phase1 relaunch fill")) {
        goto cleanup;
    }

    rc = 0;

cleanup:
    mgLaunchDestroy(launch);
    mgGraphExecDestroy(exec);
    mgGraphDestroy(graph);
    mgEventDestroy(event);
    mgBufferDestroy(fill_buffer);
    mgBufferDestroy(src_buffer);
    mgBufferDestroy(dst_buffer);
    mgStreamDestroy(stream);
    mgDeviceDestroy(device);
    mgErrorDestroy(error);
    return rc;
}
