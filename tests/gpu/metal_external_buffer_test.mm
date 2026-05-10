#include "../../src/core/internal.h"
#include "metal_graph/metal_graph.h"
#include "metal_graph/metal_graph_metal.h"

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

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
    memset(values, 0, sizeof(initial));

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
        if (test_shared_buffer_origin(device) ||
            test_invalid_wrap_ranges(device, metalDevice) ||
            test_external_dispatch_copy_and_fill(device, stream, metalDevice) ||
            test_exec_and_launch_retain_external_storage(device, stream, metalDevice)) {
            goto cleanup;
        }

        rc = 0;

    cleanup:
        mgStreamDestroy(stream);
        mgDeviceDestroy(device);
        mgErrorDestroy(error);
        return rc;
    }
}
