#include "../../src/core/internal.h"
#include "metal_graph/metal_graph.h"

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalPerformanceShadersGraph/MetalPerformanceShadersGraph.h>

#include <math.h>
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

static mg_dispatch_desc_t add_one_desc(mg_buffer_t *buffer, mg_buffer_binding_t *binding,
                                       mg_dispatch_resource_desc_t *resource) {
    binding->index = 0;
    binding->buffer = buffer;
    binding->offset = 0;
    memset(resource, 0, sizeof(*resource));
    resource->size = sizeof(*resource);
    resource->index = 0;
    resource->access = MG_RESOURCE_ACCESS_READ_WRITE;
    resource->byte_count = sizeof(float) * 4;
    resource->alignment = sizeof(float);

    mg_dispatch_desc_t desc;
    memset(&desc, 0, sizeof(desc));
    desc.size = sizeof(desc);
    desc.metallib_path = TEST_METALLIB_PATH;
    desc.kernel_name = "mg_phase5_add_one_float";
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

static bool floats_match(const float *values, const float *expected) {
    for (size_t i = 0; i < 4; ++i) {
        if (fabsf(values[i] - expected[i]) > 0.0001f) {
            fprintf(stderr, "value %zu expected %.3f got %.3f\n", i, expected[i], values[i]);
            return false;
        }
    }
    return true;
}

static NSString *create_test_package(id<MTLDevice> metalDevice) {
    @autoreleasepool {
        MPSGraph *graph = [MPSGraph new];
        MPSShape *shape = @[ @4 ];
        MPSGraphTensor *input = [graph placeholderWithShape:shape
                                                   dataType:MPSDataTypeFloat32
                                                       name:@"input"];
        MPSGraphTensor *doubled = [graph additionWithPrimaryTensor:input
                                                   secondaryTensor:input
                                                              name:@"doubled"];
        MPSGraphDevice *graphDevice = [MPSGraphDevice deviceWithMTLDevice:metalDevice];
        MPSGraphShapedType *inputType =
            [[MPSGraphShapedType alloc] initWithShape:shape dataType:MPSDataTypeFloat32];
        NSDictionary<MPSGraphTensor *, MPSGraphShapedType *> *feeds = @{input : inputType};
        MPSGraphExecutable *executable = [graph compileWithDevice:graphDevice
                                                            feeds:feeds
                                                    targetTensors:@[ doubled ]
                                                 targetOperations:nil
                                            compilationDescriptor:nil];
        if (!executable) {
            return nil;
        }

        NSString *path = [NSTemporaryDirectory()
            stringByAppendingPathComponent:
                [NSString stringWithFormat:@"metal-graph-phase5-%@.mpsgraphpackage",
                                           [[NSUUID UUID] UUIDString]]];
        NSURL *url = [NSURL fileURLWithPath:path];
        [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
        @try {
            [executable serializeToMPSGraphPackageAtURL:url descriptor:nil];
        } @catch (NSException *exception) {
            fprintf(stderr, "failed to serialize MPSGraph package: %s\n",
                    [[exception reason] UTF8String]);
            return nil;
        }

        if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
            fprintf(stderr, "MPSGraph package was not written\n");
            return nil;
        }
        return path;
    }
}

int main(void) {
    @autoreleasepool {
        int rc = 1;
        mg_error_t *error = NULL;
        mg_device_t *device = NULL;
        mg_stream_t *stream = NULL;
        mg_buffer_t *input = NULL;
        mg_buffer_t *output = NULL;
        mg_graph_t *graph = NULL;
        mg_graph_exec_t *exec = NULL;
        mg_launch_t *launch = NULL;
        id<MTLDevice> metalDevice = nil;
        NSString *packagePath = nil;
        float *inputValues = NULL;
        float *outputValues = NULL;
        size_t shape[1] = {4};
        mg_mpsgraph_tensor_desc_t feed;
        mg_mpsgraph_tensor_desc_t target;
        mg_mpsgraph_desc_t mps_desc;
        mg_node_t *raw_before = NULL;
        mg_node_t *mps_node = NULL;
        mg_node_t *raw_after = NULL;
        mg_dispatch_desc_t before_desc;
        mg_dispatch_desc_t after_desc;
        mg_buffer_binding_t before_binding;
        mg_buffer_binding_t after_binding;
        mg_dispatch_resource_desc_t before_resource;
        mg_dispatch_resource_desc_t after_resource;
        mg_graph_exec_diagnostics_t diagnostics;
        float expected[4] = {5.0f, 7.0f, 9.0f, 11.0f};
        float expected_relaunch[4] = {9.0f, 11.0f, 13.0f, 15.0f};

        mg_status_t status = mgDeviceCreateSystemDefault(&device, &error);
        if (status == MG_STATUS_UNSUPPORTED) {
            fprintf(stderr, "skipping: no system default Metal device\n");
            mgErrorDestroy(error);
            return 0;
        }
        if (expect_status(status, MG_STATUS_OK, "create device", &error) ||
            expect_status(mgStreamCreate(device, &stream, &error), MG_STATUS_OK, "create stream",
                          &error) ||
            expect_status(mgBufferCreateShared(device, sizeof(float) * 4, &input, &error),
                          MG_STATUS_OK, "create input buffer", &error) ||
            expect_status(mgBufferCreateShared(device, sizeof(float) * 4, &output, &error),
                          MG_STATUS_OK, "create output buffer", &error)) {
            goto cleanup;
        }

        metalDevice = (__bridge id<MTLDevice>)device->impl;
        packagePath = create_test_package(metalDevice);
        if (!packagePath) {
            fprintf(stderr, "skipping: failed to create MPSGraph test package\n");
            rc = 0;
            goto cleanup;
        }

        inputValues = (float *)mgBufferContents(input);
        outputValues = (float *)mgBufferContents(output);
        inputValues[0] = 1.0f;
        inputValues[1] = 2.0f;
        inputValues[2] = 3.0f;
        inputValues[3] = 4.0f;
        memset(outputValues, 0, sizeof(float) * 4);

        memset(&feed, 0, sizeof(feed));
        feed.size = sizeof(feed);
        feed.buffer = input;
        feed.data_type = MG_TENSOR_DATA_TYPE_FLOAT32;
        feed.layout = MG_TENSOR_LAYOUT_CONTIGUOUS;
        feed.rank = 1;
        feed.shape = shape;

        target = feed;
        target.buffer = output;

        memset(&mps_desc, 0, sizeof(mps_desc));
        mps_desc.size = sizeof(mps_desc);
        mps_desc.package_path = [packagePath fileSystemRepresentation];
        mps_desc.feeds = &feed;
        mps_desc.feed_count = 1;
        mps_desc.targets = &target;
        mps_desc.target_count = 1;

        before_desc = add_one_desc(input, &before_binding, &before_resource);
        after_desc = add_one_desc(output, &after_binding, &after_resource);
        if (expect_status(mgGraphCreate(&graph, &error), MG_STATUS_OK, "create graph", &error) ||
            expect_status(mgGraphAddDispatchNode(graph, &before_desc, &raw_before, &error),
                          MG_STATUS_OK, "add raw before", &error) ||
            expect_status(mgGraphAddMPSGraphNode(graph, &mps_desc, &mps_node, &error), MG_STATUS_OK,
                          "add MPSGraph node", &error) ||
            expect_status(mgGraphAddDispatchNode(graph, &after_desc, &raw_after, &error),
                          MG_STATUS_OK, "add raw after", &error) ||
            expect_status(mgGraphAddDependency(graph, raw_before, mps_node, &error), MG_STATUS_OK,
                          "raw before MPS dependency", &error) ||
            expect_status(mgGraphAddDependency(graph, mps_node, raw_after, &error), MG_STATUS_OK,
                          "MPS before raw dependency", &error) ||
            expect_status(mgGraphInstantiate(graph, device, &exec, &error), MG_STATUS_OK,
                          "instantiate graph", &error)) {
            goto cleanup;
        }
        mgGraphDestroy(graph);
        graph = NULL;
        [[NSFileManager defaultManager] removeItemAtPath:packagePath error:nil];

        memset(&diagnostics, 0, sizeof(diagnostics));
        diagnostics.size = sizeof(diagnostics);
        if (expect_status(mgGraphExecGetDiagnostics(exec, &diagnostics, &error), MG_STATUS_OK,
                          "get diagnostics", &error) ||
            diagnostics.icb_last_fallback_reason != MG_ICB_FALLBACK_INELIGIBLE_NODE) {
            fprintf(stderr, "MPSGraph graph should force ICB fallback\n");
            goto cleanup;
        }

        if (expect_status(mgGraphLaunch(exec, stream, &launch, &error), MG_STATUS_OK,
                          "launch graph", &error) ||
            expect_status(mgLaunchSynchronize(launch, &error), MG_STATUS_OK, "sync launch",
                          &error)) {
            goto cleanup;
        }

        if (!floats_match(outputValues, expected)) {
            goto cleanup;
        }

        mgLaunchDestroy(launch);
        launch = NULL;
        inputValues[0] = 3.0f;
        inputValues[1] = 4.0f;
        inputValues[2] = 5.0f;
        inputValues[3] = 6.0f;
        memset(outputValues, 0, sizeof(float) * 4);

        if (expect_status(mgGraphLaunch(exec, stream, &launch, &error), MG_STATUS_OK,
                          "relaunch graph", &error) ||
            expect_status(mgLaunchSynchronize(launch, &error), MG_STATUS_OK, "sync relaunch",
                          &error)) {
            goto cleanup;
        }
        if (!floats_match(outputValues, expected_relaunch)) {
            goto cleanup;
        }

        rc = 0;

    cleanup:
        mgLaunchDestroy(launch);
        mgGraphExecDestroy(exec);
        mgGraphDestroy(graph);
        if (packagePath) {
            [[NSFileManager defaultManager] removeItemAtPath:packagePath error:nil];
        }
        mgBufferDestroy(output);
        mgBufferDestroy(input);
        mgStreamDestroy(stream);
        mgDeviceDestroy(device);
        mgErrorDestroy(error);
        return rc;
    }
}
