#include "../../src/core/internal.h"
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

static int check_bytes(const uint8_t *values, const uint8_t *expected, size_t count,
                       const char *label) {
    for (size_t i = 0; i < count; ++i) {
        if (values[i] != expected[i]) {
            fprintf(stderr, "%s: byte %zu expected %u got %u\n", label, i, expected[i], values[i]);
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
    mg_buffer_t *workspace_buffer = NULL;
    mg_event_t *event = NULL;
    mg_arena_t *arena = NULL;
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
                      "create fill buffer", &error) ||
        expect_status(mgBufferCreateShared(device, 8, &workspace_buffer, &error), MG_STATUS_OK,
                      "create workspace output buffer", &error)) {
        goto cleanup;
    }

    uint32_t *dst_values = (uint32_t *)mgBufferContents(dst_buffer);
    uint32_t *src_values = (uint32_t *)mgBufferContents(src_buffer);
    uint8_t *fill_values = (uint8_t *)mgBufferContents(fill_buffer);
    uint8_t *workspace_values = (uint8_t *)mgBufferContents(workspace_buffer);
    if (!dst_values || !src_values || !fill_values || !workspace_values) {
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

    mg_arena_desc_t invalid_arena_desc;
    memset(&invalid_arena_desc, 0, sizeof(invalid_arena_desc));
    invalid_arena_desc.size = sizeof(invalid_arena_desc);
    invalid_arena_desc.byte_count = 64;
    invalid_arena_desc.alignment = 3;
    if (expect_status(mgArenaCreate(device, &invalid_arena_desc, &arena, &error),
                      MG_STATUS_INVALID_ARGUMENT, "reject invalid arena alignment", &error)) {
        goto cleanup;
    }

    mg_graph_t *small_arena_graph = NULL;
    mg_graph_exec_t *small_arena_exec = NULL;
    mg_arena_t *small_arena = NULL;
    mg_node_t *workspace_test_node = NULL;
    mg_arena_desc_t small_arena_desc;
    memset(&small_arena_desc, 0, sizeof(small_arena_desc));
    small_arena_desc.size = sizeof(small_arena_desc);
    small_arena_desc.byte_count = 32;
    small_arena_desc.alignment = 16;
    mg_workspace_desc_t too_large_workspace;
    memset(&too_large_workspace, 0, sizeof(too_large_workspace));
    too_large_workspace.size = sizeof(too_large_workspace);
    too_large_workspace.byte_count = 64;
    too_large_workspace.alignment = 16;
    if (expect_status(mgArenaCreate(device, &small_arena_desc, &small_arena, &error), MG_STATUS_OK,
                      "create small arena", &error) ||
        expect_status(mgGraphCreate(&small_arena_graph, &error), MG_STATUS_OK,
                      "create small arena graph", &error) ||
        expect_status(mgGraphSetArena(small_arena_graph, small_arena, &error), MG_STATUS_OK,
                      "set small arena", &error) ||
        expect_status(mg_internal_graph_add_workspace_node(small_arena_graph, &too_large_workspace,
                                                           &workspace_test_node, &error),
                      MG_STATUS_OK, "add oversized workspace", &error)) {
        mgArenaDestroy(small_arena);
        mgGraphDestroy(small_arena_graph);
        goto cleanup;
    }
    status = mgGraphInstantiate(small_arena_graph, device, &small_arena_exec, &error);
    mgArenaDestroy(small_arena);
    mgGraphDestroy(small_arena_graph);
    if (status != MG_STATUS_INVALID_ARGUMENT || mgErrorStage(error) != MG_ERROR_STAGE_PLAN_MEMORY) {
        if (status == MG_STATUS_OK) {
            mgGraphExecDestroy(small_arena_exec);
        }
        print_error("instantiate oversized workspace should fail planning", status, error);
        error = NULL;
        goto cleanup;
    }
    mgErrorDestroy(error);
    error = NULL;

    mg_graph_t *overflow_graph = NULL;
    mg_graph_exec_t *overflow_exec = NULL;
    mg_workspace_desc_t huge_workspace;
    memset(&huge_workspace, 0, sizeof(huge_workspace));
    huge_workspace.size = sizeof(huge_workspace);
    huge_workspace.byte_count = SIZE_MAX;
    huge_workspace.alignment = 1;
    mg_workspace_desc_t one_byte_workspace;
    memset(&one_byte_workspace, 0, sizeof(one_byte_workspace));
    one_byte_workspace.size = sizeof(one_byte_workspace);
    one_byte_workspace.byte_count = 1;
    one_byte_workspace.alignment = 1;
    if (expect_status(mgGraphCreate(&overflow_graph, &error), MG_STATUS_OK, "create overflow graph",
                      &error) ||
        expect_status(mg_internal_graph_add_workspace_node(overflow_graph, &huge_workspace,
                                                           &workspace_test_node, &error),
                      MG_STATUS_OK, "add huge workspace", &error) ||
        expect_status(mg_internal_graph_add_workspace_node(overflow_graph, &one_byte_workspace,
                                                           &workspace_test_node, &error),
                      MG_STATUS_OK, "add overflow workspace", &error)) {
        mgGraphDestroy(overflow_graph);
        goto cleanup;
    }
    status = mgGraphInstantiate(overflow_graph, device, &overflow_exec, &error);
    mgGraphDestroy(overflow_graph);
    if (status != MG_STATUS_INVALID_ARGUMENT || mgErrorStage(error) != MG_ERROR_STAGE_PLAN_MEMORY) {
        if (status == MG_STATUS_OK) {
            mgGraphExecDestroy(overflow_exec);
        }
        print_error("instantiate workspace overflow should fail planning", status, error);
        error = NULL;
        goto cleanup;
    }
    mgErrorDestroy(error);
    error = NULL;

    src_values[0] = 100;
    src_values[1] = 200;
    src_values[2] = 300;
    src_values[3] = 400;
    memset(dst_values, 0, sizeof(uint32_t) * 4);
    memset(fill_values, 0, 8);
    memset(workspace_values, 0, 8);

    mg_arena_desc_t arena_desc;
    memset(&arena_desc, 0, sizeof(arena_desc));
    arena_desc.size = sizeof(arena_desc);
    arena_desc.byte_count = 128;
    arena_desc.alignment = 16;
    if (expect_status(mgArenaCreate(device, &arena_desc, &arena, &error), MG_STATUS_OK,
                      "create arena", &error)) {
        goto cleanup;
    }

    mg_node_t *wait_node = NULL;
    mg_node_t *copy_node = NULL;
    mg_node_t *fill_node = NULL;
    mg_node_t *workspace_node = NULL;
    mg_node_t *workspace_fill_node = NULL;
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
    mg_workspace_desc_t workspace_desc;
    memset(&workspace_desc, 0, sizeof(workspace_desc));
    workspace_desc.size = sizeof(workspace_desc);
    workspace_desc.byte_count = 16;
    workspace_desc.alignment = 16;
    mg_workspace_desc_t workspace_fill_desc;
    memset(&workspace_fill_desc, 0, sizeof(workspace_fill_desc));
    workspace_fill_desc.size = sizeof(workspace_fill_desc);
    workspace_fill_desc.byte_count = 8;
    workspace_fill_desc.alignment = 16;

    if (expect_status(mgGraphCreate(&graph, &error), MG_STATUS_OK, "create phase1 graph", &error) ||
        expect_status(mgGraphSetArena(graph, arena, &error), MG_STATUS_OK, "set arena", &error) ||
        expect_status(mgGraphAddEventWaitNode(graph, event, 0, &wait_node, &error), MG_STATUS_OK,
                      "add event wait", &error) ||
        expect_status(mgGraphAddCopyNode(graph, &copy_desc, &copy_node, &error), MG_STATUS_OK,
                      "add copy", &error) ||
        expect_status(mgGraphAddFillNode(graph, &fill_desc, &fill_node, &error), MG_STATUS_OK,
                      "add fill", &error) ||
        expect_status(
            mg_internal_graph_add_workspace_node(graph, &workspace_desc, &workspace_node, &error),
            MG_STATUS_OK, "add workspace node", &error) ||
        expect_status(mg_internal_graph_add_workspace_fill_node(graph, &workspace_fill_desc, 0xCD,
                                                                workspace_buffer, 0,
                                                                &workspace_fill_node, &error),
                      MG_STATUS_OK, "add internal workspace fill", &error) ||
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
        expect_status(mgGraphAddDependency(graph, wait_node, workspace_node, &error), MG_STATUS_OK,
                      "add wait-workspace dependency", &error) ||
        expect_status(mgGraphAddDependency(graph, workspace_node, workspace_fill_node, &error),
                      MG_STATUS_OK, "add workspace-fill dependency", &error) ||
        expect_status(mgGraphAddDependency(graph, copy_node, barrier_node, &error), MG_STATUS_OK,
                      "add copy-barrier dependency", &error) ||
        expect_status(mgGraphAddDependency(graph, fill_node, barrier_node, &error), MG_STATUS_OK,
                      "add fill-barrier dependency", &error) ||
        expect_status(mgGraphAddDependency(graph, workspace_fill_node, barrier_node, &error),
                      MG_STATUS_OK, "add workspace-barrier dependency", &error) ||
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
    mgArenaDestroy(arena);
    arena = NULL;
    mgEventDestroy(event);
    event = NULL;
    mgBufferDestroy(workspace_buffer);
    workspace_buffer = NULL;
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
        check_fill(fill_values, 0xAB, "phase1 first fill") ||
        check_fill(workspace_values, 0xCD, "phase2 first workspace fill")) {
        goto cleanup;
    }

    src_values[0] = 7;
    src_values[1] = 8;
    src_values[2] = 9;
    src_values[3] = 10;
    memset(dst_values, 0, sizeof(uint32_t) * 4);
    memset(fill_values, 0, 8);
    memset(workspace_values, 0, 8);
    if (expect_status(mgGraphLaunch(exec, stream, &launch, &error), MG_STATUS_OK,
                      "relaunch phase1 graph", &error) ||
        expect_status(mgLaunchSynchronize(launch, &error), MG_STATUS_OK, "sync phase1 relaunch",
                      &error)) {
        goto cleanup;
    }
    if (check_values(dst_values, 8, 9, 10, 11, "phase1 relaunch") ||
        check_fill(fill_values, 0xAB, "phase1 relaunch fill") ||
        check_fill(workspace_values, 0xCD, "phase2 relaunch workspace fill")) {
        goto cleanup;
    }
    mgGraphExecDestroy(exec);
    exec = NULL;

    if (expect_status(mgBufferCreateShared(device, sizeof(uint32_t) * 8, &dst_buffer, &error),
                      MG_STATUS_OK, "create phase3 dispatch buffer", &error) ||
        expect_status(mgBufferCreateShared(device, 8, &src_buffer, &error), MG_STATUS_OK,
                      "create phase3 copy source", &error) ||
        expect_status(mgBufferCreateShared(device, 8, &fill_buffer, &error), MG_STATUS_OK,
                      "create phase3 fill/copy output", &error) ||
        expect_status(mgEventCreate(device, &event, &error), MG_STATUS_OK, "create phase3 event",
                      &error)) {
        goto cleanup;
    }

    uint32_t *phase3_values = (uint32_t *)mgBufferContents(dst_buffer);
    uint8_t *phase3_src = (uint8_t *)mgBufferContents(src_buffer);
    uint8_t *phase3_bytes = (uint8_t *)mgBufferContents(fill_buffer);
    if (!phase3_values || !phase3_src || !phase3_bytes) {
        fprintf(stderr, "phase3 shared buffer contents are unavailable\n");
        goto cleanup;
    }
    for (uint32_t i = 0; i < 8; ++i) {
        phase3_values[i] = 0;
        phase3_src[i] = (uint8_t)(i + 1);
        phase3_bytes[i] = 0;
    }

    mg_graph_t *phase3_graph = NULL;
    mg_node_t *phase3_dispatch = NULL;
    mg_node_t *phase3_copy = NULL;
    mg_node_t *phase3_fill = NULL;
    mg_node_t *phase3_signal = NULL;
    mg_buffer_binding_t phase3_binding = {
        0,
        dst_buffer,
        0,
    };
    uint32_t delta = 1;
    mg_scalar_binding_t scalar = {
        1,
        &delta,
        sizeof(delta),
    };
    mg_dispatch_desc_t phase3_dispatch_desc;
    memset(&phase3_dispatch_desc, 0, sizeof(phase3_dispatch_desc));
    phase3_dispatch_desc.size = sizeof(phase3_dispatch_desc);
    phase3_dispatch_desc.metallib_path = TEST_METALLIB_PATH;
    phase3_dispatch_desc.kernel_name = "mg_phase3_add_scalar";
    phase3_dispatch_desc.grid_size[0] = 2;
    phase3_dispatch_desc.grid_size[1] = 1;
    phase3_dispatch_desc.grid_size[2] = 1;
    phase3_dispatch_desc.threads_per_threadgroup[0] = 1;
    phase3_dispatch_desc.threads_per_threadgroup[1] = 1;
    phase3_dispatch_desc.threads_per_threadgroup[2] = 1;
    phase3_dispatch_desc.max_grid_size[0] = 4;
    phase3_dispatch_desc.max_grid_size[1] = 1;
    phase3_dispatch_desc.max_grid_size[2] = 1;
    phase3_dispatch_desc.buffers = &phase3_binding;
    phase3_dispatch_desc.buffer_count = 1;
    phase3_dispatch_desc.scalars = &scalar;
    phase3_dispatch_desc.scalar_count = 1;

    mg_copy_desc_t phase3_copy_desc;
    memset(&phase3_copy_desc, 0, sizeof(phase3_copy_desc));
    phase3_copy_desc.size = sizeof(phase3_copy_desc);
    phase3_copy_desc.src = src_buffer;
    phase3_copy_desc.dst = fill_buffer;
    phase3_copy_desc.byte_count = 4;
    mg_fill_desc_t phase3_fill_desc;
    memset(&phase3_fill_desc, 0, sizeof(phase3_fill_desc));
    phase3_fill_desc.size = sizeof(phase3_fill_desc);
    phase3_fill_desc.dst = fill_buffer;
    phase3_fill_desc.dst_offset = 4;
    phase3_fill_desc.byte_count = 4;
    phase3_fill_desc.value = 0x11;

    if (expect_status(mgGraphCreate(&phase3_graph, &error), MG_STATUS_OK, "create phase3 graph",
                      &error) ||
        expect_status(
            mgGraphAddDispatchNode(phase3_graph, &phase3_dispatch_desc, &phase3_dispatch, &error),
            MG_STATUS_OK, "add phase3 dispatch", &error) ||
        expect_status(mgGraphSetNodePatchFlags(phase3_graph, phase3_dispatch,
                                               MG_PATCH_DISPATCH_GRID | MG_PATCH_DISPATCH_BUFFER |
                                                   MG_PATCH_DISPATCH_SCALAR,
                                               &error),
                      MG_STATUS_OK, "declare phase3 dispatch patch flags", &error) ||
        expect_status(mgGraphAddCopyNode(phase3_graph, &phase3_copy_desc, &phase3_copy, &error),
                      MG_STATUS_OK, "add phase3 copy", &error) ||
        expect_status(mgGraphSetNodePatchFlags(phase3_graph, phase3_copy,
                                               MG_PATCH_COPY_BUFFER | MG_PATCH_COPY_RANGE, &error),
                      MG_STATUS_OK, "declare phase3 copy patch flags", &error) ||
        expect_status(mgGraphAddFillNode(phase3_graph, &phase3_fill_desc, &phase3_fill, &error),
                      MG_STATUS_OK, "add phase3 fill", &error) ||
        expect_status(mgGraphSetNodePatchFlags(phase3_graph, phase3_fill,
                                               MG_PATCH_FILL_RANGE | MG_PATCH_FILL_VALUE, &error),
                      MG_STATUS_OK, "declare phase3 fill patch flags", &error) ||
        expect_status(mgGraphAddEventSignalNode(phase3_graph, event, 1, &phase3_signal, &error),
                      MG_STATUS_OK, "add phase3 signal", &error) ||
        expect_status(
            mgGraphSetNodePatchFlags(phase3_graph, phase3_signal, MG_PATCH_EVENT_VALUE, &error),
            MG_STATUS_OK, "declare phase3 event patch flag", &error) ||
        expect_status(mgGraphInstantiate(phase3_graph, device, &exec, &error), MG_STATUS_OK,
                      "instantiate phase3 graph", &error)) {
        mgGraphDestroy(phase3_graph);
        goto cleanup;
    }
    mg_node_id_t phase3_dispatch_id = mgNodeId(phase3_dispatch);
    mg_node_id_t phase3_copy_id = mgNodeId(phase3_copy);
    mg_node_id_t phase3_fill_id = mgNodeId(phase3_fill);
    mg_node_id_t phase3_signal_id = mgNodeId(phase3_signal);
    if (expect_status(mgGraphSetNodePatchFlags(phase3_graph, phase3_dispatch, 0, &error),
                      MG_STATUS_OK, "clear source graph dispatch patch flags after instantiate",
                      &error) ||
        expect_status(mgGraphSetNodePatchFlags(phase3_graph, phase3_copy, 0, &error), MG_STATUS_OK,
                      "clear source graph copy patch flags after instantiate", &error) ||
        expect_status(mgGraphSetNodePatchFlags(phase3_graph, phase3_fill, 0, &error), MG_STATUS_OK,
                      "clear source graph fill patch flags after instantiate", &error) ||
        expect_status(mgGraphSetNodePatchFlags(phase3_graph, phase3_signal, 0, &error),
                      MG_STATUS_OK, "clear source graph event patch flags after instantiate",
                      &error)) {
        mgGraphDestroy(phase3_graph);
        goto cleanup;
    }
    mgGraphDestroy(phase3_graph);

    if (expect_status(mgGraphLaunch(exec, stream, &launch, &error), MG_STATUS_OK,
                      "launch phase3 initial graph", &error) ||
        expect_status(mgGraphExecPatchDispatchGrid(exec, phase3_dispatch_id,
                                                   phase3_dispatch_desc.max_grid_size, &error),
                      MG_STATUS_INVALID_ARGUMENT, "reject in-flight phase3 patch", &error) ||
        expect_status(mgLaunchSynchronize(launch, &error), MG_STATUS_OK, "sync phase3 initial",
                      &error)) {
        goto cleanup;
    }
    mgLaunchDestroy(launch);
    launch = NULL;
    uint8_t expected_initial_bytes[8] = {1, 2, 3, 4, 0x11, 0x11, 0x11, 0x11};
    if (phase3_values[0] != 1 || phase3_values[1] != 1 || phase3_values[2] != 0 ||
        phase3_values[3] != 0 ||
        check_bytes(phase3_bytes, expected_initial_bytes, 8, "phase3 initial copy/fill")) {
        fprintf(stderr, "phase3 initial dispatch output is wrong\n");
        goto cleanup;
    }

    uint64_t wrong_delta = 9;
    if (expect_status(mgGraphExecPatchDispatchScalar(exec, phase3_dispatch_id, 1, &wrong_delta,
                                                     sizeof(wrong_delta), &error),
                      MG_STATUS_INVALID_ARGUMENT, "reject phase3 wrong scalar size", &error)) {
        goto cleanup;
    }
    memset(phase3_values, 0, sizeof(uint32_t) * 8);
    memset(phase3_bytes, 0, 8);
    if (expect_status(mgGraphLaunch(exec, stream, &launch, &error), MG_STATUS_OK,
                      "launch phase3 after failed patch", &error) ||
        expect_status(mgLaunchSynchronize(launch, &error), MG_STATUS_OK,
                      "sync phase3 after failed patch", &error)) {
        goto cleanup;
    }
    mgLaunchDestroy(launch);
    launch = NULL;
    if (phase3_values[0] != 1 || phase3_values[1] != 1 || phase3_values[2] != 0 ||
        phase3_values[3] != 0) {
        fprintf(stderr, "phase3 failed patch should preserve scalar/grid state\n");
        goto cleanup;
    }

    uint32_t patched_delta = 2;
    uint32_t patched_grid[3] = {4, 1, 1};
    mg_copy_desc_t patched_copy = phase3_copy_desc;
    patched_copy.src_offset = 4;
    patched_copy.dst_offset = 0;
    patched_copy.byte_count = 4;
    mg_fill_desc_t patched_fill = phase3_fill_desc;
    patched_fill.dst_offset = 4;
    patched_fill.byte_count = 4;
    patched_fill.value = 0x22;
    memset(phase3_values, 0, sizeof(uint32_t) * 8);
    memset(phase3_bytes, 0, 8);
    if (expect_status(mgGraphExecPatchDispatchScalar(exec, phase3_dispatch_id, 1, &patched_delta,
                                                     sizeof(patched_delta), &error),
                      MG_STATUS_OK, "patch phase3 scalar", &error) ||
        expect_status(mgGraphExecPatchDispatchGrid(exec, phase3_dispatch_id, patched_grid, &error),
                      MG_STATUS_OK, "patch phase3 grid", &error) ||
        expect_status(mgGraphExecPatchDispatchBuffer(exec, phase3_dispatch_id, 0, dst_buffer,
                                                     sizeof(uint32_t) * 4, &error),
                      MG_STATUS_OK, "patch phase3 dispatch buffer offset", &error) ||
        expect_status(mgGraphExecPatchCopyNode(exec, phase3_copy_id, &patched_copy, &error),
                      MG_STATUS_OK, "patch phase3 copy", &error) ||
        expect_status(mgGraphExecPatchFillNode(exec, phase3_fill_id, &patched_fill, &error),
                      MG_STATUS_OK, "patch phase3 fill", &error) ||
        expect_status(mgGraphExecPatchEventValue(exec, phase3_signal_id, 2, &error), MG_STATUS_OK,
                      "patch phase3 event value", &error) ||
        expect_status(mgGraphLaunch(exec, stream, &launch, &error), MG_STATUS_OK,
                      "launch phase3 patched graph", &error) ||
        expect_status(mgLaunchSynchronize(launch, &error), MG_STATUS_OK, "sync phase3 patched",
                      &error)) {
        goto cleanup;
    }
    uint8_t expected_patched_bytes[8] = {5, 6, 7, 8, 0x22, 0x22, 0x22, 0x22};
    if (phase3_values[0] != 0 || phase3_values[1] != 0 || phase3_values[4] != 2 ||
        phase3_values[5] != 2 || phase3_values[6] != 2 || phase3_values[7] != 2 ||
        check_bytes(phase3_bytes, expected_patched_bytes, 8, "phase3 patched copy/fill")) {
        fprintf(stderr, "phase3 patched dispatch output is wrong\n");
        goto cleanup;
    }
    mgLaunchDestroy(launch);
    launch = NULL;

    if (expect_status(mgGraphExecPatchDispatchScalar(exec, phase3_dispatch_id, 1, &wrong_delta,
                                                     sizeof(wrong_delta), &error),
                      MG_STATUS_INVALID_ARGUMENT,
                      "reject phase3 wrong scalar size after successful patch", &error)) {
        goto cleanup;
    }
    memset(phase3_values, 0, sizeof(uint32_t) * 8);
    memset(phase3_bytes, 0, 8);
    if (expect_status(mgGraphLaunch(exec, stream, &launch, &error), MG_STATUS_OK,
                      "launch phase3 after failed post-success patch", &error) ||
        expect_status(mgLaunchSynchronize(launch, &error), MG_STATUS_OK,
                      "sync phase3 after failed post-success patch", &error)) {
        goto cleanup;
    }
    if (phase3_values[0] != 0 || phase3_values[1] != 0 || phase3_values[4] != 2 ||
        phase3_values[5] != 2 || phase3_values[6] != 2 || phase3_values[7] != 2 ||
        check_bytes(phase3_bytes, expected_patched_bytes, 8,
                    "phase3 failed post-success patch copy/fill")) {
        fprintf(stderr, "phase3 failed patch should preserve previously patched state\n");
        goto cleanup;
    }

    rc = 0;

cleanup:
    mgLaunchDestroy(launch);
    mgGraphExecDestroy(exec);
    mgGraphDestroy(graph);
    mgArenaDestroy(arena);
    mgEventDestroy(event);
    mgBufferDestroy(workspace_buffer);
    mgBufferDestroy(fill_buffer);
    mgBufferDestroy(src_buffer);
    mgBufferDestroy(dst_buffer);
    mgStreamDestroy(stream);
    mgDeviceDestroy(device);
    mgErrorDestroy(error);
    return rc;
}
