#include "../../src/core/internal.h"
#include "metal_graph/metal_graph.h"
#include "metal_graph/metal_graph_metal.h"

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalPerformanceShadersGraph/MetalPerformanceShadersGraph.h>

#include <math.h>
#include <stdio.h>
#include <string.h>
#include <pthread.h>
#include <time.h>
#include <unistd.h>

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

typedef struct mps_owner_counts { int retains, releases; } mps_owner_counts_t;
static void mps_owner_retain(void *p) { __atomic_fetch_add(&((mps_owner_counts_t *)p)->retains, 1, __ATOMIC_RELAXED); }
static void mps_owner_release(void *p) { __atomic_fetch_add(&((mps_owner_counts_t *)p)->releases, 1, __ATOMIC_RELEASE); }
typedef struct launch_call {
    mg_graph_exec_t *exec; mg_stream_t *stream; mg_launch_t *launch; mg_error_t *error;
    mg_status_t status; int done;
} launch_call_t;
static void *launch_on_thread(void *p) {
    launch_call_t *call = (launch_call_t *)p;
    call->status = mgGraphLaunch(call->exec, call->stream, &call->launch, &call->error);
    __atomic_store_n(&call->done, 1, __ATOMIC_RELEASE);
    return NULL;
}
static bool wait_atomic_int(int *p, int target) {
    struct timespec start, now; clock_gettime(CLOCK_MONOTONIC, &start);
    while (__atomic_load_n(p, __ATOMIC_ACQUIRE) != target) {
        usleep(1000); clock_gettime(CLOCK_MONOTONIC, &now);
        if (now.tv_sec - start.tv_sec >= 5) return false;
    }
    return true;
}
static bool wait_exec_terminal(mg_graph_exec_t *exec) {
    struct timespec start, now; clock_gettime(CLOCK_MONOTONIC, &start);
    while (__atomic_load_n(&exec->in_flight_count, __ATOMIC_ACQUIRE) != 0) {
        usleep(1000); clock_gettime(CLOCK_MONOTONIC, &now);
        if (now.tv_sec - start.tv_sec >= 5) return false;
    }
    return true;
}
static bool signal_event(id<MTLCommandQueue> producer, id<MTLSharedEvent> event) {
    id<MTLCommandBuffer> cb = [producer commandBuffer]; if (!cb) return false;
    [cb encodeSignalEvent:event value:1]; [cb commit];
    struct timespec start, now; clock_gettime(CLOCK_MONOTONIC, &start);
    while (event.signaledValue < 1) {
        usleep(1000); clock_gettime(CLOCK_MONOTONIC, &now);
        if (now.tv_sec - start.tv_sec >= 5) return false;
    }
    return true;
}

static int test_async_fifo(mg_device_t *device, id<MTLDevice> metal, NSString *package, int continuations, int failure) {
    int rc = 1; bool workerStarted = false, submitted = false;
    mg_error_t *error = NULL; mg_stream_t *stream = NULL, *independent = NULL;
    mg_buffer_t *input = NULL, *output = NULL, *secondBuf = NULL, *otherBuf = NULL;
    mg_graph_t *firstGraph = NULL, *secondGraph = NULL, *otherGraph = NULL;
    mg_graph_exec_t *first = NULL, *second = NULL, *other = NULL;
    mg_launch_t *firstLaunch = NULL, *secondLaunch = NULL, *otherLaunch = NULL;
    mg_event_t *event = NULL; mg_node_t *wait = NULL, *before = NULL, *graphNode = NULL, *after = NULL, *fillNode = NULL;
    mg_buffer_binding_t beforeBinding = {}, afterBinding = {};
    mg_dispatch_resource_desc_t beforeResource = {}, afterResource = {};
    mg_dispatch_desc_t beforeDesc = {}, afterDesc = {};
    mg_mpsgraph_tensor_desc_t feed = {}, target = {}; mg_mpsgraph_desc_t graphDesc = {};
    mg_fill_desc_t fill = {}; size_t shape[1] = {4}; mg_node_id_t graphId = MG_NODE_ID_INVALID;
    mps_owner_counts_t owner = {}; pthread_t worker = {}; launch_call_t call = {};
    mg_metal_buffer_wrap_desc_t wd = {};
    id<MTLBuffer> nativeIn = [metal newBufferWithLength:32 options:MTLResourceStorageModeShared | MTLResourceHazardTrackingModeUntracked];
    id<MTLBuffer> nativeOut = [metal newBufferWithLength:32 options:MTLResourceStorageModeShared | MTLResourceHazardTrackingModeUntracked];
    id<MTLCommandQueue> producer = [metal newCommandQueue];
    id<MTLSharedEvent> nativeEvent = nil;
    if (!nativeIn || !nativeOut || !producer) goto cleanup;
    memset([nativeIn contents], 0xa5, 32); memset([nativeOut contents], 0xa5, 32);
    for (int i = 0; i < 4; ++i) ((float *)[nativeIn contents])[i] = (float)(i + 1);
    wd.size = sizeof(wd); wd.byte_length = 32; wd.access = MG_METAL_BUFFER_ACCESS_READ_WRITE;
    wd.flags = MG_METAL_BUFFER_WRAP_RETAIN_BUFFER | MG_METAL_BUFFER_WRAP_RETAIN_OWNER |
               MG_METAL_BUFFER_WRAP_HOST_VISIBLE | MG_METAL_BUFFER_WRAP_MUTABLE;
    wd.owner_context = &owner; wd.owner_retain = mps_owner_retain; wd.owner_release = mps_owner_release;
    wd.buffer = nativeIn;
    if (expect_status(mgMetalBufferWrap(device, &wd, &input, &error), MG_STATUS_OK, "FIFO input wrap", &error)) goto cleanup;
    wd.buffer = nativeOut;
    if (expect_status(mgMetalBufferWrap(device, &wd, &output, &error), MG_STATUS_OK, "FIFO output wrap", &error) ||
        expect_status(mgStreamCreate(device, &stream, &error), MG_STATUS_OK, "FIFO stream", &error) ||
        expect_status(mgStreamCreate(device, &independent, &error), MG_STATUS_OK, "independent stream", &error) ||
        expect_status(mgEventCreate(device, &event, &error), MG_STATUS_OK, "FIFO event", &error) ||
        expect_status(mgBufferCreateShared(device, 16, &secondBuf, &error), MG_STATUS_OK, "second buffer", &error) ||
        expect_status(mgBufferCreateShared(device, 16, &otherBuf, &error), MG_STATUS_OK, "other buffer", &error)) goto cleanup;
    nativeEvent = (__bridge id<MTLSharedEvent>)event->impl;
    memset(mgBufferContents(secondBuf), 0, 16); memset(mgBufferContents(otherBuf), 0, 16);
    feed.size = sizeof(feed); feed.buffer = input; feed.data_type = MG_TENSOR_DATA_TYPE_FLOAT32;
    feed.layout = MG_TENSOR_LAYOUT_CONTIGUOUS; feed.rank = 1; feed.shape = shape;
    target = feed; target.buffer = output;
    graphDesc.size = sizeof(graphDesc); graphDesc.package_path = package.fileSystemRepresentation;
    graphDesc.feeds = &feed; graphDesc.feed_count = 1; graphDesc.targets = &target; graphDesc.target_count = 1;
    beforeDesc = add_one_desc(input, &beforeBinding, &beforeResource);
    afterDesc = add_one_desc(output, &afterBinding, &afterResource);
    if (expect_status(mgGraphCreate(&firstGraph, &error), MG_STATUS_OK, "FIFO first graph", &error) ||
        expect_status(mgGraphAddEventWaitNode(firstGraph, event, 1, &wait, &error), MG_STATUS_OK, "FIFO wait", &error) ||
        expect_status(mgGraphAddDispatchNode(firstGraph, &beforeDesc, &before, &error), MG_STATUS_OK, "FIFO prefix", &error) ||
        expect_status(mgGraphAddMPSGraphNode(firstGraph, &graphDesc, &graphNode, &error), MG_STATUS_OK, "FIFO graph node", &error) ||
        expect_status(mgGraphAddDispatchNode(firstGraph, &afterDesc, &after, &error), MG_STATUS_OK, "FIFO suffix", &error) ||
        expect_status(mgGraphAddDependency(firstGraph, wait, before, &error), MG_STATUS_OK, "FIFO wait-prefix", &error) ||
        expect_status(mgGraphAddDependency(firstGraph, before, graphNode, &error), MG_STATUS_OK, "FIFO prefix-graph", &error) ||
        expect_status(mgGraphAddDependency(firstGraph, graphNode, after, &error), MG_STATUS_OK, "FIFO graph-suffix", &error) ||
        expect_status(mgGraphInstantiate(firstGraph, device, &first, &error), MG_STATUS_OK, "FIFO first exec", &error)) goto cleanup;
    graphId = mgNodeId(graphNode);
    mg_test_set_mps_continuations(first, (uint8_t)continuations);
    if (failure == 7) mg_test_fail_next_raw_after_commit(first);
    else if (failure) mg_test_set_mps_failure(first, (uint8_t)failure);
    fill.size = sizeof(fill); fill.dst = secondBuf; fill.byte_count = 16; fill.value = 0x7b;
    if (expect_status(mgGraphCreate(&secondGraph, &error), MG_STATUS_OK, "FIFO second graph", &error) ||
        expect_status(mgGraphAddFillNode(secondGraph, &fill, &fillNode, &error), MG_STATUS_OK, "FIFO second fill", &error) ||
        expect_status(mgGraphInstantiate(secondGraph, device, &second, &error), MG_STATUS_OK, "FIFO second exec", &error)) goto cleanup;
    fill.dst = otherBuf; fill.value = 0x7c;
    if (expect_status(mgGraphCreate(&otherGraph, &error), MG_STATUS_OK, "other graph", &error) ||
        expect_status(mgGraphAddFillNode(otherGraph, &fill, &fillNode, &error), MG_STATUS_OK, "other fill", &error) ||
        expect_status(mgGraphInstantiate(otherGraph, device, &other, &error), MG_STATUS_OK, "other exec", &error)) goto cleanup;
    mgGraphDestroy(firstGraph); firstGraph = NULL; mgGraphDestroy(secondGraph); secondGraph = NULL;
    mgGraphDestroy(otherGraph); otherGraph = NULL; mgBufferDestroy(input); input = NULL; mgBufferDestroy(output); output = NULL;
    call.exec = first; call.stream = stream;
    if (pthread_create(&worker, NULL, launch_on_thread, &call) != 0) goto cleanup;
    workerStarted = true;
    if (!wait_atomic_int(&call.done, 1)) {
        if (!signal_event(producer, nativeEvent)) _Exit(20);
        pthread_join(worker, NULL); workerStarted = false;
        fprintf(stderr, "mixed graph launch did not return while held\n"); goto cleanup;
    }
    pthread_join(worker, NULL); workerStarted = false;
    firstLaunch = call.launch; call.launch = NULL; error = call.error; call.error = NULL;
    if (expect_status(call.status, MG_STATUS_OK, "held mixed launch", &error)) goto cleanup;
    submitted = true;
    if (expect_status(mgGraphLaunch(second, stream, &secondLaunch, &error), MG_STATUS_OK, "queued second launch", &error) ||
        expect_status(mgGraphLaunch(other, independent, &otherLaunch, &error), MG_STATUS_OK, "independent launch", &error) ||
        !wait_exec_terminal(other) ||
        expect_status(mgLaunchSynchronize(otherLaunch, &error), MG_STATUS_OK, "independent sync", &error) ||
        ((uint8_t *)mgBufferContents(otherBuf))[0] != 0x7c || ((uint8_t *)mgBufferContents(secondBuf))[0] != 0 ||
        nativeEvent.signaledValue != 0 || __atomic_load_n(&owner.releases, __ATOMIC_ACQUIRE) != 0) goto cleanup;
    /* Early-destroy public first handles and the shared stream in normal mode. */
    if (!continuations && !failure) {
        mgLaunchDestroy(firstLaunch); firstLaunch = NULL;
        mgGraphExecDestroy(first); first = NULL;
        mgStreamDestroy(stream); stream = NULL;
        mgEventDestroy(event); event = NULL;
        if (__atomic_load_n(&owner.releases, __ATOMIC_ACQUIRE) != 0) goto cleanup;
    }
    if (!signal_event(producer, nativeEvent)) goto cleanup;
    if (failure == 10 || failure == 11 || failure == 12 || failure == 13) {
        for (int repeat = 0; repeat < 2; ++repeat) {
            mg_status_t result = mgLaunchSynchronize(firstLaunch, &error);
            if (result != MG_STATUS_UNSUPPORTED || !error || mgErrorNodeId(error) != graphId ||
                mgErrorStage(error) != (failure == 13 ? MG_ERROR_STAGE_COMMIT : MG_ERROR_STAGE_ENCODE)) goto cleanup;
            if (failure == 11 && strcmp(mgErrorBackendMessage(error), "synthetic backend detail") != 0) goto cleanup;
            mgErrorDestroy(error); error = NULL;
        }
        mg_launch_diagnostics_t diag = {}; diag.size = sizeof(diag);
        if (expect_status(mgLaunchGetDiagnostics(firstLaunch, &diag, &error), MG_STATUS_OK, "unknown diagnostics", &error) ||
            diag.completed || __atomic_load_n(&first->in_flight_count, __ATOMIC_ACQUIRE) != 1 ||
            __atomic_load_n(&owner.releases, __ATOMIC_ACQUIRE) != 0 ||
            ((uint8_t *)mgBufferContents(secondBuf))[0] != 0) goto cleanup;
        mg_buffer_t *contenderBuffer = NULL; mg_graph_t *contenderGraph = NULL;
        mg_graph_exec_t *contender = NULL; mg_node_t *contenderFill = NULL; mg_launch_t *rejected = NULL;
        mg_metal_buffer_wrap_desc_t contenderWrap = wd;
        contenderWrap.buffer = nativeOut;
        contenderWrap.flags &= ~MG_METAL_BUFFER_WRAP_RETAIN_OWNER;
        contenderWrap.owner_context = NULL; contenderWrap.owner_retain = NULL; contenderWrap.owner_release = NULL;
        mg_fill_desc_t contenderDesc = {}; contenderDesc.size = sizeof(contenderDesc); contenderDesc.byte_count = 16; contenderDesc.value = 0x49;
        if (expect_status(mgMetalBufferWrap(device, &contenderWrap, &contenderBuffer, &error), MG_STATUS_OK, "unknown contender buffer", &error) ||
            expect_status(mgGraphCreate(&contenderGraph, &error), MG_STATUS_OK, "unknown contender graph", &error)) goto cleanup;
        contenderDesc.dst = contenderBuffer;
        if (expect_status(mgGraphAddFillNode(contenderGraph, &contenderDesc, &contenderFill, &error), MG_STATUS_OK, "unknown contender fill", &error) ||
            expect_status(mgGraphInstantiate(contenderGraph, device, &contender, &error), MG_STATUS_OK, "unknown contender exec", &error)) goto cleanup;
        mg_status_t rejectedStatus = mgGraphLaunch(contender, independent, &rejected, &error);
        if (rejectedStatus != MG_STATUS_INVALID_ARGUMENT || rejected || !error) goto cleanup;
        mgErrorDestroy(error); error = NULL;
        mgGraphExecDestroy(contender); mgGraphDestroy(contenderGraph); mgBufferDestroy(contenderBuffer);
        mg_test_resolve_unknown_root(first); /* synthetic authoritative completion for cleanup */
        fprintf(stderr, "synthetic unknown accounting error: resources, reservation and FIFO held; resolved for cleanup\n");
    }
    if (!wait_exec_terminal(second)) goto cleanup;
    if (expect_status(mgLaunchSynchronize(secondLaunch, &error), MG_STATUS_OK, "queued second sync", &error) ||
        ((uint8_t *)mgBufferContents(secondBuf))[0] != 0x7b) goto cleanup;
    if (failure) {
        if (!wait_exec_terminal(first)) goto cleanup;
        for (int repeat = 0; repeat < 2; ++repeat) {
            mg_status_t result = mgLaunchSynchronize(firstLaunch, &error);
            if (failure == 10 || failure == 11 || failure == 12 || failure == 13) {
                if (result != MG_STATUS_UNSUPPORTED || !error || mgErrorNodeId(error) != graphId) goto cleanup;
                mgErrorDestroy(error); error = NULL; continue;
            }
            mg_error_stage_t expectedStage = (failure == 2 || failure == 6 ? MG_ERROR_STAGE_COMPLETE :
                                              failure == 3 || failure == 4 || failure == 7 || failure == 9 ? MG_ERROR_STAGE_COMMIT : MG_ERROR_STAGE_ENCODE);
            if (result != MG_STATUS_BACKEND_ERROR || !error || mgErrorStage(error) != expectedStage ||
                (failure != 7 && mgErrorNodeId(error) != graphId)) goto cleanup;
            mgErrorDestroy(error); error = NULL;
        }
    } else if (continuations) {
        if (!wait_exec_terminal(first) || expect_status(mgLaunchSynchronize(firstLaunch, &error), MG_STATUS_OK, "continued graph sync", &error) ||
            first->test_mps_observed_roots < 3) goto cleanup;
        fprintf(stderr, "controlled MPS continuations=%d tracked roots=%u\n", continuations, first->test_mps_observed_roots);
    }
    {
        if (failure == 2 || failure == 4 || failure == 6 || failure == 8 || failure == 9 || failure == 12 || failure == 13) {
            float expected[4] = {4, 6, 8, 10};
            if (!floats_match((float *)[nativeOut contents], expected)) goto cleanup;
        } else if (failure) {
            for (size_t i = 0; i < 16; ++i) if (((uint8_t *)[nativeOut contents])[i] != 0xa5) goto cleanup;
        } else {
            float expected[4] = {5, 7, 9, 11};
            if (!floats_match((float *)[nativeOut contents], expected)) goto cleanup;
        }
        for (size_t i = 16; i < 32; ++i)
            if (((uint8_t *)[nativeOut contents])[i] != 0xa5 || ((uint8_t *)[nativeIn contents])[i] != 0xa5) goto cleanup;
    }
    rc = 0;
cleanup:
    if (workerStarted) {
        if (nativeEvent && !signal_event(producer, nativeEvent)) _Exit(21);
        pthread_join(worker, NULL); firstLaunch = call.launch; call.launch = NULL; mgErrorDestroy(call.error); call.error = NULL;
    }
    if (submitted && nativeEvent && nativeEvent.signaledValue < 1 && !signal_event(producer, nativeEvent)) _Exit(22);
    if (second && !wait_exec_terminal(second)) _Exit(23);
    if (first && !wait_exec_terminal(first)) _Exit(24);
    if (other && !wait_exec_terminal(other)) _Exit(25);
    mgLaunchDestroy(firstLaunch); mgLaunchDestroy(secondLaunch); mgLaunchDestroy(otherLaunch);
    mgGraphExecDestroy(first); mgGraphExecDestroy(second); mgGraphExecDestroy(other);
    mgGraphDestroy(firstGraph); mgGraphDestroy(secondGraph); mgGraphDestroy(otherGraph);
    mgBufferDestroy(input); mgBufferDestroy(output); mgBufferDestroy(secondBuf); mgBufferDestroy(otherBuf);
    mgEventDestroy(event); mgStreamDestroy(stream); mgStreamDestroy(independent); mgErrorDestroy(error);
    if (!wait_atomic_int(&owner.releases, __atomic_load_n(&owner.retains, __ATOMIC_ACQUIRE))) return 1;
    if (rc) fprintf(stderr, "async FIFO MPS test failed continuation=%d failure=%d\n", continuations, failure);
    return rc;
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

        if (test_async_fifo(device, metalDevice, packagePath, 0, 0) ||
            test_async_fifo(device, metalDevice, packagePath, 2, 0) ||
            test_async_fifo(device, metalDevice, packagePath, 1, 1) ||
            test_async_fifo(device, metalDevice, packagePath, 0, 2) ||
            test_async_fifo(device, metalDevice, packagePath, 0, 3) ||
            test_async_fifo(device, metalDevice, packagePath, 0, 4) ||
            test_async_fifo(device, metalDevice, packagePath, 0, 5) ||
            test_async_fifo(device, metalDevice, packagePath, 2, 6) ||
            test_async_fifo(device, metalDevice, packagePath, 0, 7) ||
            test_async_fifo(device, metalDevice, packagePath, 0, 8) ||
            test_async_fifo(device, metalDevice, packagePath, 0, 9) ||
            test_async_fifo(device, metalDevice, packagePath, 0, 10) ||
            test_async_fifo(device, metalDevice, packagePath, 0, 11) ||
            test_async_fifo(device, metalDevice, packagePath, 0, 12) ||
            test_async_fifo(device, metalDevice, packagePath, 0, 13)) goto cleanup;
        fprintf(stderr, "async mixed FIFO, independent stream and injected failure tests passed\n");

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
