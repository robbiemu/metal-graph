#include "../../src/core/internal.h"
#include "metal_graph/metal_graph.h"
#include "metal_graph/metal_graph_metal.h"

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

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

static int expect_uint32(uint32_t actual, uint32_t expected, const char *label) {
    if (actual != expected) {
        fprintf(stderr, "%s expected %u got %u\n", label, expected, actual);
        return 1;
    }
    return 0;
}

static mg_dispatch_desc_t add_one_desc(mg_buffer_t *buffer, mg_buffer_binding_t *binding,
                                       mg_dispatch_resource_desc_t *resource) {
    binding->index = 0;
    binding->buffer = buffer;
    binding->offset = 0;

    memset(resource, 0, sizeof(*resource));
    resource->size = sizeof(*resource);
    resource->index = 0;
    resource->access = MG_RESOURCE_ACCESS_READ_WRITE;
    resource->byte_count = sizeof(uint32_t) * 4;
    resource->alignment = sizeof(uint32_t);

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
    desc.buffers = binding;
    desc.buffer_count = 1;
    desc.resources = resource;
    desc.resource_count = 1;
    return desc;
}

static mg_dispatch_desc_t add_one_desc_with_binding_offset(mg_buffer_t *buffer,
                                                           mg_buffer_binding_t *binding,
                                                           mg_dispatch_resource_desc_t *resource,
                                                           size_t bindingOffset) {
    mg_dispatch_desc_t desc = add_one_desc(buffer, binding, resource);
    binding->offset = bindingOffset;
    return desc;
}

static mg_metal_buffer_wrap_desc_t wrap_desc(id<MTLBuffer> metalBuffer, size_t byteOffset,
                                             size_t byteLength) {
    mg_metal_buffer_wrap_desc_t desc;
    memset(&desc, 0, sizeof(desc));
    desc.size = sizeof(desc);
    desc.buffer = metalBuffer;
    desc.byte_offset = byteOffset;
    desc.byte_length = byteLength;
    desc.access = MG_METAL_BUFFER_ACCESS_READ_WRITE;
    desc.flags = MG_METAL_BUFFER_WRAP_RETAIN_BUFFER | MG_METAL_BUFFER_WRAP_HOST_VISIBLE |
                 MG_METAL_BUFFER_WRAP_MUTABLE;
    desc.label = "metal-graph-external-test";
    return desc;
}

static int check_origin(mg_buffer_t *buffer, size_t byteOffset, size_t byteLength,
                        const char *label) {
    mg_error_t *error = NULL;
    mg_buffer_origin_info_t info;
    memset(&info, 0, sizeof(info));
    info.size = sizeof(info);
    if (expect_status(mgBufferGetOriginInfo(buffer, &info, &error), MG_STATUS_OK, label, &error)) {
        return 1;
    }
    if (info.origin_kind != MG_BUFFER_ORIGIN_EXTERNAL_METAL || !info.is_zero_copy ||
        !info.is_external || !info.is_host_visible || !info.is_mutable ||
        info.byte_offset != byteOffset || info.byte_length != byteLength ||
        !info.source_framework || strcmp(info.source_framework, "Metal") != 0 ||
        info.fallback_reason != NULL) {
        fprintf(stderr, "%s returned incorrect origin diagnostics\n", label);
        return 1;
    }
    return 0;
}

static int test_shared_buffer_origin(mg_device_t *device) {
    mg_error_t *error = NULL;
    mg_buffer_t *buffer = NULL;
    int rc = 1;

    if (expect_status(mgBufferCreateShared(device, 16, &buffer, &error), MG_STATUS_OK,
                      "create shared buffer", &error)) {
        goto cleanup;
    }

    mg_buffer_origin_info_t info;
    memset(&info, 0, sizeof(info));
    info.size = sizeof(info);
    if (expect_status(mgBufferGetOriginInfo(buffer, &info, &error), MG_STATUS_OK,
                      "shared origin info", &error)) {
        goto cleanup;
    }
    if (info.origin_kind != MG_BUFFER_ORIGIN_LIBRARY_OWNED || info.is_zero_copy ||
        info.is_external || !info.is_host_visible || !info.is_mutable || info.byte_offset != 0 ||
        info.byte_length != 16) {
        fprintf(stderr, "shared buffer origin diagnostics were incorrect\n");
        goto cleanup;
    }
    rc = 0;

cleanup:
    mgBufferDestroy(buffer);
    mgErrorDestroy(error);
    return rc;
}

static int test_invalid_wrap_ranges(mg_device_t *device, id<MTLDevice> metalDevice) {
    mg_error_t *error = NULL;
    mg_buffer_t *wrapped = NULL;
    id<MTLBuffer> metalBuffer = [metalDevice newBufferWithLength:16
                                                         options:MTLResourceStorageModeShared];
    if (!metalBuffer) {
        fprintf(stderr, "failed to create Metal buffer for invalid range test\n");
        return 1;
    }

    mg_metal_buffer_wrap_desc_t desc = wrap_desc(metalBuffer, 8, 16);
    if (expect_status(mgMetalBufferWrap(device, &desc, &wrapped, &error),
                      MG_STATUS_INVALID_ARGUMENT, "reject out-of-range wrap", &error)) {
        mgBufferDestroy(wrapped);
        return 1;
    }

    desc = wrap_desc(metalBuffer, 0, 16);
    desc.flags &= ~MG_METAL_BUFFER_WRAP_MUTABLE;
    if (expect_status(mgMetalBufferWrap(device, &desc, &wrapped, &error),
                      MG_STATUS_INVALID_ARGUMENT, "reject write without mutable", &error)) {
        mgBufferDestroy(wrapped);
        return 1;
    }

    return 0;
}

static int test_external_buffer_device_mismatch_rejects(mg_device_t *device,
                                                        id<MTLDevice> metalDevice) {
    mg_error_t *error = NULL;
    mg_buffer_t *wrapped = NULL;
    id<MTLDevice> otherDevice = nil;

    NSArray<id<MTLDevice>> *devices = MTLCopyAllDevices();
    for (id<MTLDevice> candidate in devices) {
        if (candidate != metalDevice) {
            otherDevice = candidate;
            break;
        }
    }
    if (!otherDevice) {
        fprintf(stderr, "skipping device mismatch rejection: only one Metal device is available\n");
        return 0;
    }

    id<MTLBuffer> otherBuffer = [otherDevice newBufferWithLength:16
                                                         options:MTLResourceStorageModeShared];
    if (!otherBuffer) {
        fprintf(stderr, "failed to create Metal buffer for device mismatch test\n");
        return 1;
    }

    mg_metal_buffer_wrap_desc_t desc = wrap_desc(otherBuffer, 0, 16);
    if (expect_status(mgMetalBufferWrap(device, &desc, &wrapped, &error),
                      MG_STATUS_INVALID_ARGUMENT, "reject device mismatch wrap", &error)) {
        mgBufferDestroy(wrapped);
        return 1;
    }
    return 0;
}

static int test_external_dispatch_copy_and_fill(mg_device_t *device, mg_stream_t *stream,
                                                id<MTLDevice> metalDevice) {
    int rc = 1;
    mg_error_t *error = NULL;
    mg_buffer_t *wrapped = NULL;
    mg_buffer_t *copyDst = NULL;
    mg_graph_t *graph = NULL;
    mg_graph_exec_t *exec = NULL;
    mg_launch_t *launch = NULL;
    id<MTLBuffer> metalBuffer = nil;
    uint32_t *values = NULL;
    uint32_t initial[8] = {99, 100, 1, 2, 3, 4, 200, 201};
    mg_metal_buffer_wrap_desc_t desc;
    mg_buffer_binding_t binding;
    mg_dispatch_resource_desc_t resource;
    mg_dispatch_desc_t dispatch;
    mg_node_t *dispatchNode = NULL;
    mg_copy_desc_t copy;
    mg_node_t *copyNode = NULL;
    uint32_t *copied = NULL;
    mg_fill_desc_t fill;
    mg_node_t *fillNode = NULL;

    metalBuffer = [metalDevice newBufferWithLength:sizeof(uint32_t) * 8
                                           options:MTLResourceStorageModeShared];
    if (!metalBuffer) {
        fprintf(stderr, "failed to create external Metal buffer\n");
        goto cleanup;
    }
    values = (uint32_t *)[metalBuffer contents];
    memcpy(values, initial, sizeof(initial));

    desc = wrap_desc(metalBuffer, sizeof(uint32_t), sizeof(uint32_t) * 6);
    if (expect_status(mgMetalBufferWrap(device, &desc, &wrapped, &error), MG_STATUS_OK,
                      "wrap nonzero external range", &error) ||
        check_origin(wrapped, sizeof(uint32_t), sizeof(uint32_t) * 6, "external origin info") ||
        expect_status(mgBufferCreateShared(device, sizeof(uint32_t) * 4, &copyDst, &error),
                      MG_STATUS_OK, "create copy destination", &error) ||
        expect_status(mgGraphCreate(&graph, &error), MG_STATUS_OK, "create graph", &error)) {
        goto cleanup;
    }

    dispatch = add_one_desc_with_binding_offset(wrapped, &binding, &resource, sizeof(uint32_t));
    if (expect_status(mgGraphAddDispatchNode(graph, &dispatch, &dispatchNode, &error),
                      MG_STATUS_OK, "add external dispatch", &error)) {
        goto cleanup;
    }

    memset(&copy, 0, sizeof(copy));
    copy.size = sizeof(copy);
    copy.src = wrapped;
    copy.src_offset = sizeof(uint32_t);
    copy.dst = copyDst;
    copy.byte_count = sizeof(uint32_t) * 4;
    if (expect_status(mgGraphAddCopyNode(graph, &copy, &copyNode, &error), MG_STATUS_OK,
                      "add external copy", &error) ||
        expect_status(mgGraphAddDependency(graph, dispatchNode, copyNode, &error), MG_STATUS_OK,
                      "add dispatch-copy dependency", &error) ||
        expect_status(mgGraphInstantiate(graph, device, &exec, &error), MG_STATUS_OK,
                      "instantiate external graph", &error) ||
        expect_status(mgGraphLaunch(exec, stream, &launch, &error), MG_STATUS_OK,
                      "launch external graph", &error) ||
        expect_status(mgLaunchSynchronize(launch, &error), MG_STATUS_OK, "sync external graph",
                      &error)) {
        goto cleanup;
    }
    mgLaunchDestroy(launch);
    launch = NULL;

    if (expect_uint32(values[0], 99, "external prefix") ||
        expect_uint32(values[1], 100, "external wrap prefix") ||
        expect_uint32(values[2], 2, "external value 2") ||
        expect_uint32(values[3], 3, "external value 3") ||
        expect_uint32(values[4], 4, "external value 4") ||
        expect_uint32(values[5], 5, "external value 5") ||
        expect_uint32(values[6], 200, "external wrap suffix") ||
        expect_uint32(values[7], 201, "external suffix")) {
        goto cleanup;
    }
    copied = (uint32_t *)mgBufferContents(copyDst);
    if (expect_uint32(copied[0], 2, "copy source offset value 0") ||
        expect_uint32(copied[1], 3, "copy source offset value 1") ||
        expect_uint32(copied[2], 4, "copy source offset value 2") ||
        expect_uint32(copied[3], 5, "copy source offset value 3")) {
        goto cleanup;
    }

    mgGraphExecDestroy(exec);
    exec = NULL;
    mgGraphDestroy(graph);
    graph = NULL;
    memcpy(values, initial, sizeof(initial));

    if (expect_status(mgGraphCreate(&graph, &error), MG_STATUS_OK, "create fill graph", &error)) {
        goto cleanup;
    }
    memset(&fill, 0, sizeof(fill));
    fill.size = sizeof(fill);
    fill.dst = wrapped;
    fill.dst_offset = sizeof(uint32_t);
    fill.byte_count = sizeof(uint32_t) * 4;
    fill.value = 0xAB;
    if (expect_status(mgGraphAddFillNode(graph, &fill, &fillNode, &error), MG_STATUS_OK,
                      "add external fill", &error) ||
        expect_status(mgGraphInstantiate(graph, device, &exec, &error), MG_STATUS_OK,
                      "instantiate fill graph", &error) ||
        expect_status(mgGraphLaunch(exec, stream, &launch, &error), MG_STATUS_OK,
                      "launch fill graph", &error) ||
        expect_status(mgLaunchSynchronize(launch, &error), MG_STATUS_OK, "sync fill graph",
                      &error)) {
        goto cleanup;
    }
    for (size_t i = 2; i < 6; ++i) {
        if (expect_uint32(values[i], 0xABABABABu, "filled external value")) {
            goto cleanup;
        }
    }

    mgLaunchDestroy(launch);
    launch = NULL;
    mgGraphExecDestroy(exec);
    exec = NULL;
    mgGraphDestroy(graph);
    graph = NULL;

    if (expect_status(mgGraphCreate(&graph, &error), MG_STATUS_OK, "create copy destination graph",
                      &error)) {
        goto cleanup;
    }
    memset(&copy, 0, sizeof(copy));
    copy.size = sizeof(copy);
    copy.src = copyDst;
    copy.src_offset = sizeof(uint32_t);
    copy.dst = wrapped;
    copy.dst_offset = sizeof(uint32_t) * 2;
    copy.byte_count = sizeof(uint32_t) * 2;
    if (expect_status(mgGraphAddCopyNode(graph, &copy, &copyNode, &error), MG_STATUS_OK,
                      "add copy into external destination", &error) ||
        expect_status(mgGraphInstantiate(graph, device, &exec, &error), MG_STATUS_OK,
                      "instantiate copy destination graph", &error) ||
        expect_status(mgGraphLaunch(exec, stream, &launch, &error), MG_STATUS_OK,
                      "launch copy destination graph", &error) ||
        expect_status(mgLaunchSynchronize(launch, &error), MG_STATUS_OK,
                      "sync copy destination graph", &error)) {
        goto cleanup;
    }
    if (expect_uint32(values[0], 99, "copy destination external prefix") ||
        expect_uint32(values[1], 100, "copy destination wrap prefix") ||
        expect_uint32(values[3], 3, "copy destination composed offset value 0") ||
        expect_uint32(values[4], 4, "copy destination composed offset value 1") ||
        expect_uint32(values[6], 200, "copy destination wrap suffix") ||
        expect_uint32(values[7], 201, "copy destination external suffix")) {
        goto cleanup;
    }

    rc = 0;

cleanup:
    mgLaunchDestroy(launch);
    mgGraphExecDestroy(exec);
    mgGraphDestroy(graph);
    mgBufferDestroy(copyDst);
    mgBufferDestroy(wrapped);
    mgErrorDestroy(error);
    return rc;
}

static int test_exec_and_launch_retain_external_storage(mg_device_t *device, mg_stream_t *stream,
                                                        id<MTLDevice> metalDevice) {
    int rc = 1;
    mg_error_t *error = NULL;
    mg_buffer_t *wrapped = NULL;
    mg_graph_t *graph = NULL;
    mg_graph_exec_t *exec = NULL;
    mg_launch_t *launch = NULL;
    id<MTLBuffer> metalBuffer = nil;
    uint32_t *values = NULL;
    mg_metal_buffer_wrap_desc_t desc;
    mg_buffer_binding_t binding;
    mg_dispatch_resource_desc_t resource;
    mg_dispatch_desc_t dispatch;
    mg_node_t *dispatchNode = NULL;

    metalBuffer = [metalDevice newBufferWithLength:sizeof(uint32_t) * 4
                                           options:MTLResourceStorageModeShared];
    if (!metalBuffer) {
        fprintf(stderr, "failed to create retention test Metal buffer\n");
        goto cleanup;
    }
    values = (uint32_t *)[metalBuffer contents];
    values[0] = 10;
    values[1] = 20;
    values[2] = 30;
    values[3] = 40;

    desc = wrap_desc(metalBuffer, 0, sizeof(uint32_t) * 4);
    if (expect_status(mgMetalBufferWrap(device, &desc, &wrapped, &error), MG_STATUS_OK,
                      "wrap retention buffer", &error) ||
        expect_status(mgGraphCreate(&graph, &error), MG_STATUS_OK, "create retention graph",
                      &error)) {
        goto cleanup;
    }

    dispatch = add_one_desc(wrapped, &binding, &resource);
    if (expect_status(mgGraphAddDispatchNode(graph, &dispatch, &dispatchNode, &error),
                      MG_STATUS_OK,
                      "add retention dispatch", &error) ||
        expect_status(mgGraphInstantiate(graph, device, &exec, &error), MG_STATUS_OK,
                      "instantiate retention graph", &error)) {
        goto cleanup;
    }

    mgGraphDestroy(graph);
    graph = NULL;
    mgBufferDestroy(wrapped);
    wrapped = NULL;
    metalBuffer = nil;

    if (expect_status(mgGraphLaunch(exec, stream, &launch, &error), MG_STATUS_OK,
                      "launch after public wrapper release", &error) ||
        expect_status(mgLaunchSynchronize(launch, &error), MG_STATUS_OK,
                      "sync after public wrapper release", &error)) {
        goto cleanup;
    }
    mgLaunchDestroy(launch);
    launch = NULL;
    if (expect_uint32(values[0], 11, "retained relaunch value 0") ||
        expect_uint32(values[1], 21, "retained relaunch value 1") ||
        expect_uint32(values[2], 31, "retained relaunch value 2") ||
        expect_uint32(values[3], 41, "retained relaunch value 3")) {
        goto cleanup;
    }

    if (expect_status(mgGraphLaunch(exec, stream, &launch, &error), MG_STATUS_OK,
                      "second launch after wrapper release", &error) ||
        expect_status(mgLaunchSynchronize(launch, &error), MG_STATUS_OK,
                      "sync second launch after wrapper release", &error)) {
        goto cleanup;
    }
    if (expect_uint32(values[0], 12, "retained second value 0") ||
        expect_uint32(values[1], 22, "retained second value 1") ||
        expect_uint32(values[2], 32, "retained second value 2") ||
        expect_uint32(values[3], 42, "retained second value 3")) {
        goto cleanup;
    }

    rc = 0;

cleanup:
    mgLaunchDestroy(launch);
    mgGraphExecDestroy(exec);
    mgGraphDestroy(graph);
    mgBufferDestroy(wrapped);
    mgErrorDestroy(error);
    return rc;
}

typedef struct patch_owner_counts {
    int retains, releases;
} patch_owner_counts_t;
static void patch_owner_retain(void *context) {
    __atomic_fetch_add(&((patch_owner_counts_t *)context)->retains, 1, __ATOMIC_RELAXED);
}
static void patch_owner_release(void *context) {
    __atomic_fetch_add(&((patch_owner_counts_t *)context)->releases, 1, __ATOMIC_RELEASE);
}

static int test_patch_hazards_gpu(mg_device_t *device, mg_stream_t *stream, id<MTLDevice> metal) {
    int rc = 1;
    mg_error_t *error = NULL;
    mg_buffer_t *a = NULL, *alias = NULL, *old = NULL;
    mg_graph_t *graph = NULL;
    mg_graph_exec_t *exec = NULL;
    mg_launch_t *launch = NULL;
    mg_node_t *fillNode = NULL, *dispatchNode = NULL, *barrier = NULL;
    mg_node_id_t dispatchId = MG_NODE_ID_INVALID, fillId = MG_NODE_ID_INVALID;
    patch_owner_counts_t owner = {0};
    mg_metal_buffer_wrap_desc_t wd;
    id<MTLBuffer> native = [metal newBufferWithLength:128 options:MTLResourceStorageModeShared];
    id<MTLBuffer> oldNative = [metal newBufferWithLength:64 options:MTLResourceStorageModeShared];
    if (!native || !oldNative)
        goto cleanup;
    memset([native contents], 0, 128);
    memset([oldNative contents], 0, 64);
    wd = wrap_desc(native, 16, 64);
    if (expect_status(mgMetalBufferWrap(device, &wd, &a, &error), MG_STATUS_OK, "wrap A", &error))
        goto cleanup;
    wd = wrap_desc(native, 32, 64);
    wd.flags |= MG_METAL_BUFFER_WRAP_RETAIN_OWNER;
    wd.owner_context = &owner;
    wd.owner_retain = patch_owner_retain;
    wd.owner_release = patch_owner_release;
    if (expect_status(mgMetalBufferWrap(device, &wd, &alias, &error), MG_STATUS_OK, "wrap alias",
                      &error))
        goto cleanup;
    wd = wrap_desc(oldNative, 0, 64);
    if (expect_status(mgMetalBufferWrap(device, &wd, &old, &error), MG_STATUS_OK, "wrap old",
                      &error))
        goto cleanup;
    {
        mg_fill_desc_t fill = {
            .size = sizeof(fill), .dst = a, .dst_offset = 16, .byte_count = 16, .value = 0x55};
        mg_buffer_binding_t binding;
        mg_dispatch_resource_desc_t resource;
        mg_dispatch_desc_t dispatch = add_one_desc(old, &binding, &resource);
        if (expect_status(mgGraphCreate(&graph, &error), MG_STATUS_OK, "patch graph", &error) ||
            expect_status(mgGraphAddFillNode(graph, &fill, &fillNode, &error), MG_STATUS_OK,
                          "patch fill", &error) ||
            expect_status(mgGraphAddDispatchNode(graph, &dispatch, &dispatchNode, &error),
                          MG_STATUS_OK, "patch dispatch", &error) ||
            expect_status(
                mgGraphSetNodePatchFlags(graph, dispatchNode, MG_PATCH_DISPATCH_BUFFER, &error),
                MG_STATUS_OK, "patch flag", &error))
            goto cleanup;
        dispatchId = mgNodeId(dispatchNode);
        if (expect_status(mgGraphInstantiate(graph, device, &exec, &error), MG_STATUS_OK,
                          "instantiate unordered", &error))
            goto cleanup;
        mgGraphDestroy(graph);
        graph = NULL;
        if (expect_status(mgGraphExecPatchDispatchBuffer(exec, dispatchId, 0, alias, 0, &error),
                          MG_STATUS_INVALID_TOPOLOGY, "reject alias overlap", &error) ||
            alias->ref_count != 1)
            goto cleanup;
        mgBufferDestroy(alias);
        alias = NULL;
        if (__atomic_load_n(&owner.retains, __ATOMIC_ACQUIRE) != 1 ||
            __atomic_load_n(&owner.releases, __ATOMIC_ACQUIRE) != 1)
            goto cleanup;
        wd = wrap_desc(native, 32, 64);
        wd.flags |= MG_METAL_BUFFER_WRAP_RETAIN_OWNER;
        wd.owner_context = &owner;
        wd.owner_retain = patch_owner_retain;
        wd.owner_release = patch_owner_release;
        if (expect_status(mgMetalBufferWrap(device, &wd, &alias, &error), MG_STATUS_OK,
                          "rewrap alias", &error) ||
            expect_status(mgGraphLaunch(exec, stream, &launch, &error), MG_STATUS_OK,
                          "launch after rejection", &error) ||
            expect_status(mgLaunchSynchronize(launch, &error), MG_STATUS_OK, "sync after rejection",
                          &error))
            goto cleanup;
        mgLaunchDestroy(launch);
        launch = NULL;
        uint32_t *oldValues = (uint32_t *)[oldNative contents];
        if (oldValues[0] != 1 || oldValues[1] != 1 || oldValues[2] != 1 || oldValues[3] != 1 ||
            ((uint8_t *)[native contents])[32] != 0x55 ||
            __atomic_load_n(&owner.retains, __ATOMIC_ACQUIRE) != 2 ||
            __atomic_load_n(&owner.releases, __ATOMIC_ACQUIRE) != 1)
            goto cleanup;
        mgGraphExecDestroy(exec);
        exec = NULL;
        /* A single patchable dispatch remains ineligible for ICB before and after patching. */
        if (expect_status(mgGraphCreate(&graph, &error), MG_STATUS_OK, "ICB patch graph", &error) ||
            expect_status(mgGraphAddDispatchNode(graph, &dispatch, &dispatchNode, &error),
                          MG_STATUS_OK, "ICB patch node", &error) ||
            expect_status(
                mgGraphSetNodePatchFlags(graph, dispatchNode, MG_PATCH_DISPATCH_BUFFER, &error),
                MG_STATUS_OK, "ICB patch flag", &error))
            goto cleanup;
        dispatchId = mgNodeId(dispatchNode);
        if (expect_status(mgGraphInstantiate(graph, device, &exec, &error), MG_STATUS_OK,
                          "instantiate ICB patch graph", &error))
            goto cleanup;
        mgGraphDestroy(graph);
        graph = NULL;
        mg_graph_exec_diagnostics_t diag = {.size = sizeof(diag)};
        if (expect_status(mgGraphExecGetDiagnostics(exec, &diag, &error), MG_STATUS_OK,
                          "ICB patch diagnostics", &error) ||
            diag.icb_groups_fallback != 1 ||
            (diag.icb_available &&
             diag.icb_last_fallback_reason != MG_ICB_FALLBACK_PATCHABLE_FIELD) ||
            expect_status(mgGraphExecPatchDispatchBuffer(exec, dispatchId, 0, alias, 16, &error),
                          MG_STATUS_OK, "ICB safe patch", &error) ||
            expect_status(mgGraphExecGetDiagnostics(exec, &diag, &error), MG_STATUS_OK,
                          "ICB patched diagnostics", &error) ||
            diag.icb_groups_fallback != 1 ||
            (diag.icb_available &&
             diag.icb_last_fallback_reason != MG_ICB_FALLBACK_PATCHABLE_FIELD))
            goto cleanup;
        mgGraphExecDestroy(exec);
        exec = NULL;
        memset([native contents], 0, 128);
        /* Creation order differs from topological order: dispatch -> barrier -> fill. */
        if (expect_status(mgGraphCreate(&graph, &error), MG_STATUS_OK, "ordered graph", &error) ||
            expect_status(mgGraphAddFillNode(graph, &fill, &fillNode, &error), MG_STATUS_OK,
                          "ordered fill", &error) ||
            expect_status(mgGraphAddDispatchNode(graph, &dispatch, &dispatchNode, &error),
                          MG_STATUS_OK, "ordered dispatch", &error) ||
            expect_status(mgGraphAddBarrierNode(graph, &barrier, &error), MG_STATUS_OK,
                          "ordered barrier", &error) ||
            expect_status(mgGraphAddDependency(graph, dispatchNode, barrier, &error), MG_STATUS_OK,
                          "first dependency", &error) ||
            expect_status(mgGraphAddDependency(graph, barrier, fillNode, &error), MG_STATUS_OK,
                          "second dependency", &error) ||
            expect_status(
                mgGraphSetNodePatchFlags(graph, dispatchNode, MG_PATCH_DISPATCH_BUFFER, &error),
                MG_STATUS_OK, "ordered flag", &error) ||
            expect_status(mgGraphSetNodePatchFlags(graph, fillNode, MG_PATCH_FILL_RANGE, &error),
                          MG_STATUS_OK, "ordered fill flag", &error))
            goto cleanup;
        dispatchId = mgNodeId(dispatchNode);
        fillId = mgNodeId(fillNode);
        if (expect_status(mgGraphInstantiate(graph, device, &exec, &error), MG_STATUS_OK,
                          "instantiate ordered", &error))
            goto cleanup;
        mgGraphDestroy(graph);
        graph = NULL;
        if (expect_status(mgGraphExecPatchDispatchBuffer(exec, dispatchId, 0, alias, 0, &error),
                          MG_STATUS_OK, "transitive ordered overlap after graph destruction",
                          &error))
            goto cleanup;
        fill.dst_offset = 20;
        fill.byte_count = 12;
        if (expect_status(mgGraphExecPatchFillNode(exec, fillId, &fill, &error), MG_STATUS_OK,
                          "transitive ancestor overlap after graph destruction", &error))
            goto cleanup;
        mgBufferDestroy(alias);
        alias = NULL;
        if (__atomic_load_n(&owner.releases, __ATOMIC_ACQUIRE) != 1 ||
            expect_status(mgGraphLaunch(exec, stream, &launch, &error), MG_STATUS_OK,
                          "ordered launch", &error) ||
            expect_status(mgLaunchSynchronize(launch, &error), MG_STATUS_OK, "ordered sync",
                          &error))
            goto cleanup;
        if (*(uint32_t *)((uint8_t *)[native contents] + 32) != 1 ||
            ((uint8_t *)[native contents])[36] != 0x55 ||
            ((uint8_t *)[native contents])[47] != 0x55 || ((uint8_t *)[native contents])[48] != 0)
            goto cleanup;
    }
    rc = 0;
cleanup:
    mgLaunchDestroy(launch);
    mgGraphExecDestroy(exec);
    mgGraphDestroy(graph);
    mgBufferDestroy(a);
    mgBufferDestroy(alias);
    mgBufferDestroy(old);
    mgErrorDestroy(error);
    {
        struct timespec start, now;
        clock_gettime(CLOCK_MONOTONIC, &start);
        while (__atomic_load_n(&owner.retains, __ATOMIC_ACQUIRE) !=
               __atomic_load_n(&owner.releases, __ATOMIC_ACQUIRE)) {
            usleep(1000);
            clock_gettime(CLOCK_MONOTONIC, &now);
            if (now.tv_sec - start.tv_sec >= 5) {
                fprintf(stderr, "patch owner release timeout\n");
                return 1;
            }
        }
    }
    if (rc)
        fprintf(stderr, "GPU patch hazard test failed\n");
    return rc;
}

static int test_copy_fill_patch_hazards_gpu(mg_device_t *device, mg_stream_t *stream,
                                            id<MTLDevice> metal) {
    int rc = 1;
    mg_error_t *error = NULL;
    mg_buffer_t *a = NULL, *alias = NULL, *old = NULL;
    mg_graph_t *graph = NULL;
    mg_graph_exec_t *exec = NULL;
    mg_launch_t *launch = NULL;
    mg_metal_buffer_wrap_desc_t wd;
    id<MTLBuffer> native = [metal newBufferWithLength:128 options:MTLResourceStorageModeShared];
    id<MTLBuffer> oldNative = [metal newBufferWithLength:64 options:MTLResourceStorageModeShared];
    if (!native || !oldNative)
        goto cleanup;
    wd = wrap_desc(native, 16, 64);
    if (expect_status(mgMetalBufferWrap(device, &wd, &a, &error), MG_STATUS_OK, "copy/fill wrap",
                      &error))
        goto cleanup;
    wd = wrap_desc(native, 32, 64);
    if (expect_status(mgMetalBufferWrap(device, &wd, &alias, &error), MG_STATUS_OK,
                      "copy/fill alias", &error))
        goto cleanup;
    wd = wrap_desc(oldNative, 0, 64);
    if (expect_status(mgMetalBufferWrap(device, &wd, &old, &error), MG_STATUS_OK, "copy/fill old",
                      &error))
        goto cleanup;
    for (int which = 0; which < 3; ++which) {
        mg_node_t *opponent = NULL, *candidate = NULL;
        mg_fill_desc_t opponentDesc = {.size = sizeof(opponentDesc),
                                       .dst = a,
                                       .dst_offset = 16,
                                       .byte_count = 16,
                                       .value = 0x55};
        mg_fill_desc_t fill = {.size = sizeof(fill),
                               .dst = which == 1 ? alias : old,
                               .dst_offset = which == 1 ? (size_t)16 : (size_t)8,
                               .byte_count = 8,
                               .value = 0x66};
        mg_copy_desc_t copy = {.size = sizeof(copy),
                               .src = old,
                               .src_offset = 0,
                               .dst = old,
                               .dst_offset = 16,
                               .byte_count = 8};
        memset([native contents], 0, 128);
        memset([oldNative contents], 0x23, 64);
        if (which == 2)
            memset([oldNative contents], 0xa1, 8);
        if (expect_status(mgGraphCreate(&graph, &error), MG_STATUS_OK, "copy/fill graph", &error) ||
            expect_status(mgGraphAddFillNode(graph, &opponentDesc, &opponent, &error), MG_STATUS_OK,
                          "copy/fill opponent", &error))
            goto cleanup;
        if (which == 2) {
            if (expect_status(mgGraphAddCopyNode(graph, &copy, &candidate, &error), MG_STATUS_OK,
                              "copy candidate", &error) ||
                expect_status(mgGraphSetNodePatchFlags(graph, candidate,
                                                       MG_PATCH_COPY_BUFFER | MG_PATCH_COPY_RANGE,
                                                       &error),
                              MG_STATUS_OK, "copy flags", &error))
                goto cleanup;
        } else {
            if (expect_status(mgGraphAddFillNode(graph, &fill, &candidate, &error), MG_STATUS_OK,
                              "fill candidate", &error) ||
                expect_status(mgGraphSetNodePatchFlags(graph, candidate,
                                                       MG_PATCH_FILL_BUFFER | MG_PATCH_FILL_RANGE,
                                                       &error),
                              MG_STATUS_OK, "fill flags", &error))
                goto cleanup;
        }
        mg_node_id_t id = mgNodeId(candidate);
        if (expect_status(mgGraphInstantiate(graph, device, &exec, &error), MG_STATUS_OK,
                          "instantiate copy/fill", &error))
            goto cleanup;
        mgGraphDestroy(graph);
        graph = NULL;
        if (which == 2) {
            copy.dst = alias;
            copy.dst_offset = 8;
            if (expect_status(mgGraphExecPatchCopyNode(exec, id, &copy, &error),
                              MG_STATUS_INVALID_TOPOLOGY, "reject copy alias", &error))
                goto cleanup;
        } else {
            fill.dst = alias;
            fill.dst_offset = 8;
            if (expect_status(mgGraphExecPatchFillNode(exec, id, &fill, &error),
                              MG_STATUS_INVALID_TOPOLOGY, "reject fill alias", &error))
                goto cleanup;
        }
        if (expect_status(mgGraphLaunch(exec, stream, &launch, &error), MG_STATUS_OK,
                          "copy/fill launch after rejection", &error) ||
            expect_status(mgLaunchSynchronize(launch, &error), MG_STATUS_OK, "copy/fill sync",
                          &error))
            goto cleanup;
        if (((uint8_t *)[native contents])[32] != 0x55 ||
            (which == 0 && ((uint8_t *)[oldNative contents])[8] != 0x66) ||
            (which == 1 && ((uint8_t *)[native contents])[48] != 0x66) ||
            (which == 2 && (((uint8_t *)[oldNative contents])[16] != 0xa1 ||
                            ((uint8_t *)[oldNative contents])[23] != 0xa1 ||
                            ((uint8_t *)[oldNative contents])[24] != 0x23)))
            goto cleanup;
        mgLaunchDestroy(launch);
        launch = NULL;
        mgGraphExecDestroy(exec);
        exec = NULL;
    }
    rc = 0;
cleanup:
    mgLaunchDestroy(launch);
    mgGraphExecDestroy(exec);
    mgGraphDestroy(graph);
    mgBufferDestroy(a);
    mgBufferDestroy(alias);
    mgBufferDestroy(old);
    mgErrorDestroy(error);
    if (rc)
        fprintf(stderr, "GPU copy/fill patch hazard test failed\n");
    return rc;
}

static int test_icb_completed_destroy(mg_device_t *device, mg_stream_t *stream,
                                      id<MTLDevice> metal) {
    int rc = 1;
    mg_error_t *error = NULL;
    mg_buffer_t *wrapped = NULL;
    mg_graph_t *graph = NULL;
    mg_graph_exec_t *exec = NULL;
    mg_launch_t *launch = NULL;
    mg_node_t *node = NULL;
    mg_buffer_binding_t binding = {};
    mg_dispatch_resource_desc_t resource = {};
    mg_dispatch_desc_t dispatch = {};
    mg_metal_buffer_wrap_desc_t wd = {};
    id<MTLBuffer> native = [metal newBufferWithLength:16 options:MTLResourceStorageModeShared];
    if (!native)
        goto cleanup;
    memset([native contents], 0, 16);
    wd = wrap_desc(native, 0, 16);
    if (expect_status(mgMetalBufferWrap(device, &wd, &wrapped, &error), MG_STATUS_OK, "ICB wrap",
                      &error) ||
        expect_status(mgGraphCreate(&graph, &error), MG_STATUS_OK, "ICB graph", &error))
        goto cleanup;
    dispatch = add_one_desc(wrapped, &binding, &resource);
    if (expect_status(mgGraphAddDispatchNode(graph, &dispatch, &node, &error), MG_STATUS_OK,
                      "ICB node", &error) ||
        expect_status(mgGraphInstantiate(graph, device, &exec, &error), MG_STATUS_OK,
                      "ICB instantiate", &error) ||
        expect_status(mgGraphLaunch(exec, stream, &launch, &error), MG_STATUS_OK, "ICB launch",
                      &error))
        goto cleanup;
    {
        struct timespec start, now;
        clock_gettime(CLOCK_MONOTONIC, &start);
        while (__atomic_load_n(&exec->in_flight_count, __ATOMIC_ACQUIRE) != 0) {
            usleep(1000);
            clock_gettime(CLOCK_MONOTONIC, &now);
            if (now.tv_sec - start.tv_sec >= 5)
                _Exit(4);
        }
    }
    fprintf(stderr, "ICB completed-destroy: used=%u fallback=%u\n", exec->icb.groups_used,
            exec->icb.groups_fallback);
    if (((uint32_t *)[native contents])[0] != 1 ||
        __atomic_load_n(&exec->ref_count, __ATOMIC_ACQUIRE) != 2 ||
        __atomic_load_n(&exec->in_flight_count, __ATOMIC_ACQUIRE) > 1)
        goto cleanup;
    mgLaunchDestroy(launch);
    launch = NULL;
    {
        struct timespec start, now;
        clock_gettime(CLOCK_MONOTONIC, &start);
        while (__atomic_load_n(&exec->ref_count, __ATOMIC_ACQUIRE) != 1) {
            usleep(1000);
            clock_gettime(CLOCK_MONOTONIC, &now);
            if (now.tv_sec - start.tv_sec >= 5)
                goto cleanup;
        }
    }
    if (__atomic_load_n(&exec->in_flight_count, __ATOMIC_ACQUIRE) != 0 ||
        expect_status(mgGraphLaunch(exec, stream, &launch, &error), MG_STATUS_OK, "ICB relaunch",
                      &error) ||
        expect_status(mgLaunchSynchronize(launch, &error), MG_STATUS_OK, "ICB resync", &error) ||
        ((uint32_t *)[native contents])[0] != 2)
        goto cleanup;
    rc = 0;
cleanup:
    mgLaunchDestroy(launch);
    mgGraphExecDestroy(exec);
    mgGraphDestroy(graph);
    mgBufferDestroy(wrapped);
    mgErrorDestroy(error);
    if (rc)
        fprintf(stderr, "ICB completed destroy failed\n");
    return rc;
}

int main(void) {
    @autoreleasepool {
        int rc = 1;
        mg_error_t *error = NULL;
        mg_device_t *device = NULL;
        mg_stream_t *stream = NULL;
        id<MTLDevice> metalDevice = nil;

        mg_status_t status = mgDeviceCreateSystemDefault(&device, &error);
        if (status == MG_STATUS_UNSUPPORTED) {
            fprintf(stderr, "skipping: no system default Metal device\n");
            mgErrorDestroy(error);
            return 0;
        }
        if (expect_status(status, MG_STATUS_OK, "create device", &error) ||
            expect_status(mgStreamCreate(device, &stream, &error), MG_STATUS_OK, "create stream",
                          &error)) {
            goto cleanup;
        }

        metalDevice = (__bridge id<MTLDevice>)device->impl;
        fprintf(stderr, "Metal device: %s\n", [[metalDevice name] UTF8String]);
        if (test_shared_buffer_origin(device) || test_invalid_wrap_ranges(device, metalDevice) ||
            test_external_buffer_device_mismatch_rejects(device, metalDevice) ||
            test_external_dispatch_copy_and_fill(device, stream, metalDevice) ||
            test_exec_and_launch_retain_external_storage(device, stream, metalDevice) ||
            test_patch_hazards_gpu(device, stream, metalDevice) ||
            test_copy_fill_patch_hazards_gpu(device, stream, metalDevice) ||
            test_icb_completed_destroy(device, stream, metalDevice)) {
            goto cleanup;
        }

        fprintf(stderr, "external buffer and patch hazard GPU tests passed\n");
        rc = 0;

    cleanup:
        mgStreamDestroy(stream);
        mgDeviceDestroy(device);
        mgErrorDestroy(error);
        return rc;
    }
}
