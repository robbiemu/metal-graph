#include "../../src/core/internal.h"
#include "metal_graph/metal_graph.h"
#include "metal_graph/metal_graph_metal.h"

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
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

static int expect_bytes(const uint8_t *values, uint8_t expected, size_t count, const char *label) {
    for (size_t i = 0; i < count; ++i) {
        if (values[i] != expected) {
            fprintf(stderr, "%s: byte %zu expected %u got %u\n", label, i, expected, values[i]);
            return 1;
        }
    }
    return 0;
}

static mg_metal_buffer_wrap_desc_t wrap_desc(id<MTLBuffer> metalBuffer, size_t byteLength,
                                             mg_metal_buffer_access_t access, uint32_t flags) {
    mg_metal_buffer_wrap_desc_t desc;
    memset(&desc, 0, sizeof(desc));
    desc.size = sizeof(desc);
    desc.buffer = metalBuffer;
    desc.byte_length = byteLength;
    desc.access = access;
    desc.flags = flags | MG_METAL_BUFFER_WRAP_RETAIN_BUFFER | MG_METAL_BUFFER_WRAP_HOST_VISIBLE;
    desc.label = "metal-graph-sync-conformance";
    return desc;
}

static int external_fill_and_wait(id<MTLCommandQueue> queue, id<MTLBuffer> buffer, uint8_t value) {
    id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];
    id<MTLBlitCommandEncoder> encoder = [commandBuffer blitCommandEncoder];
    [encoder fillBuffer:buffer range:NSMakeRange(0, [buffer length]) value:value];
    [encoder endEncoding];
    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];
    if (commandBuffer.status == MTLCommandBufferStatusError) {
        fprintf(stderr, "external fill command buffer failed: %s\n",
                [[[commandBuffer error] localizedDescription] UTF8String]);
        return 1;
    }
    return 0;
}

static int test_external_write_explicit_sync_then_mg_read(mg_device_t *device, mg_stream_t *stream,
                                                          id<MTLDevice> metalDevice,
                                                          id<MTLCommandQueue> externalQueue) {
    int rc = 1;
    mg_error_t *error = NULL;
    mg_buffer_t *wrapped = NULL;
    mg_buffer_t *copyDst = NULL;
    mg_graph_t *graph = NULL;
    mg_graph_exec_t *exec = NULL;
    mg_launch_t *launch = NULL;
    mg_node_t *copyNode = NULL;
    mg_metal_buffer_wrap_desc_t wrap;
    mg_copy_desc_t copy;
    id<MTLBuffer> external = [metalDevice newBufferWithLength:16
                                                      options:MTLResourceStorageModeShared];
    if (!external) {
        fprintf(stderr, "failed to create external producer buffer\n");
        return 1;
    }

    if (external_fill_and_wait(externalQueue, external, 0x3C)) {
        goto cleanup;
    }

    wrap = wrap_desc(external, 16, MG_METAL_BUFFER_ACCESS_READ, MG_METAL_BUFFER_WRAP_NONE);
    memset(&copy, 0, sizeof(copy));
    copy.size = sizeof(copy);
    copy.byte_count = 16;

    if (expect_status(mgMetalBufferWrap(device, &wrap, &wrapped, &error), MG_STATUS_OK,
                      "wrap explicitly synchronized external producer buffer", &error) ||
        expect_status(mgBufferCreateShared(device, 16, &copyDst, &error), MG_STATUS_OK,
                      "create explicit sync destination", &error) ||
        expect_status(mgGraphCreate(&graph, &error), MG_STATUS_OK, "create explicit sync graph",
                      &error)) {
        goto cleanup;
    }

    copy.src = wrapped;
    copy.dst = copyDst;
    if (expect_status(mgGraphAddCopyNode(graph, &copy, &copyNode, &error), MG_STATUS_OK,
                      "add explicit sync copy", &error) ||
        expect_status(mgGraphInstantiate(graph, device, &exec, &error), MG_STATUS_OK,
                      "instantiate explicit sync graph", &error) ||
        expect_status(mgGraphLaunch(exec, stream, &launch, &error), MG_STATUS_OK,
                      "launch explicit sync graph", &error)) {
        goto cleanup;
    }

    mg_launch_diagnostics_t before;
    memset(&before, 0, sizeof(before));
    before.size = sizeof(before);
    if (expect_status(mgLaunchGetDiagnostics(launch, &before, &error), MG_STATUS_OK,
                      "get explicit sync diagnostics before synchronize", &error) ||
        before.completed != 0 || before.synchronize_count != 0 ||
        (before.sync_mode_flags & MG_SYNC_MODE_LAUNCH_SYNCHRONIZE)) {
        fprintf(stderr, "launch should not report hidden synchronize before explicit sync\n");
        goto cleanup;
    }

    if (expect_status(mgLaunchSynchronize(launch, &error), MG_STATUS_OK,
                      "synchronize explicit sync graph", &error)) {
        goto cleanup;
    }
    mg_launch_diagnostics_t after;
    memset(&after, 0, sizeof(after));
    after.size = sizeof(after);
    if (expect_status(mgLaunchGetDiagnostics(launch, &after, &error), MG_STATUS_OK,
                      "get explicit sync diagnostics after synchronize", &error) ||
        after.completed != 1 || after.synchronize_count != 1 ||
        !(after.sync_mode_flags & MG_SYNC_MODE_LAUNCH_SYNCHRONIZE)) {
        fprintf(stderr, "launch synchronize diagnostics are wrong\n");
        goto cleanup;
    }

    if (expect_bytes((const uint8_t *)mgBufferContents(copyDst), 0x3C, 16,
                     "MetalGraph read after external explicit sync")) {
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

static int test_mg_write_explicit_sync_then_external_read(mg_device_t *device, mg_stream_t *stream,
                                                          id<MTLDevice> metalDevice,
                                                          mg_event_t *event) {
    int rc = 1;
    mg_error_t *error = NULL;
    mg_buffer_t *wrapped = NULL;
    mg_graph_t *graph = NULL;
    mg_graph_exec_t *exec = NULL;
    mg_launch_t *launch = NULL;
    mg_node_t *fillNode = NULL;
    mg_node_t *signalNode = NULL;
    mg_metal_buffer_wrap_desc_t wrap;
    mg_fill_desc_t fill;
    id<MTLBuffer> external = [metalDevice newBufferWithLength:16
                                                      options:MTLResourceStorageModeShared];
    if (!external) {
        fprintf(stderr, "failed to create external consumer buffer\n");
        return 1;
    }
    memset([external contents], 0, 16);

    wrap = wrap_desc(external, 16, MG_METAL_BUFFER_ACCESS_WRITE, MG_METAL_BUFFER_WRAP_MUTABLE);
    memset(&fill, 0, sizeof(fill));
    fill.size = sizeof(fill);
    fill.byte_count = 16;
    fill.value = 0xA5;

    if (expect_status(mgMetalBufferWrap(device, &wrap, &wrapped, &error), MG_STATUS_OK,
                      "wrap external consumer buffer", &error) ||
        expect_status(mgGraphCreate(&graph, &error), MG_STATUS_OK, "create consumer graph",
                      &error)) {
        goto cleanup;
    }
    fill.dst = wrapped;
    if (expect_status(mgGraphAddFillNode(graph, &fill, &fillNode, &error), MG_STATUS_OK,
                      "add consumer fill", &error) ||
        expect_status(mgGraphAddEventSignalNode(graph, event, 7, &signalNode, &error), MG_STATUS_OK,
                      "add consumer signal", &error) ||
        expect_status(mgGraphAddDependency(graph, fillNode, signalNode, &error), MG_STATUS_OK,
                      "order fill before signal", &error) ||
        expect_status(mgGraphInstantiate(graph, device, &exec, &error), MG_STATUS_OK,
                      "instantiate consumer graph", &error) ||
        expect_status(mgGraphLaunch(exec, stream, &launch, &error), MG_STATUS_OK,
                      "launch consumer graph", &error)) {
        goto cleanup;
    }

    mg_launch_diagnostics_t before;
    memset(&before, 0, sizeof(before));
    before.size = sizeof(before);
    if (expect_status(mgLaunchGetDiagnostics(launch, &before, &error), MG_STATUS_OK,
                      "get consumer diagnostics before synchronize", &error) ||
        before.completed != 0 || before.synchronize_count != 0 || before.event_signal_count != 1 ||
        !(before.sync_mode_flags & MG_SYNC_MODE_EVENT_SIGNAL) ||
        (before.sync_mode_flags & MG_SYNC_MODE_LAUNCH_SYNCHRONIZE)) {
        fprintf(stderr,
                "consumer launch diagnostics should show event signal but no hidden sync\n");
        goto cleanup;
    }

    if (expect_status(mgLaunchSynchronize(launch, &error), MG_STATUS_OK,
                      "synchronize consumer graph", &error) ||
        expect_bytes((const uint8_t *)[external contents], 0xA5, 16,
                     "external read after MetalGraph explicit sync")) {
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

static int test_external_event_orders_mg_read(mg_device_t *device, mg_stream_t *stream,
                                              id<MTLDevice> metalDevice,
                                              id<MTLCommandQueue> externalQueue,
                                              mg_event_t *event) {
    int rc = 1;
    mg_error_t *error = NULL;
    mg_buffer_t *wrapped = NULL;
    mg_buffer_t *copyDst = NULL;
    mg_graph_t *graph = NULL;
    mg_graph_exec_t *exec = NULL;
    mg_launch_t *launch = NULL;
    mg_node_t *waitNode = NULL;
    mg_node_t *copyNode = NULL;
    mg_metal_buffer_wrap_desc_t wrap;
    mg_copy_desc_t copy;
    id<MTLSharedEvent> sharedEvent = nil;
    id<MTLCommandBuffer> signal = nil;
    id<MTLBuffer> external = [metalDevice newBufferWithLength:16
                                                      options:MTLResourceStorageModeShared];
    if (!external) {
        fprintf(stderr, "failed to create event-ordered external buffer\n");
        return 1;
    }

    if (external_fill_and_wait(externalQueue, external, 0x5E)) {
        goto cleanup;
    }
    sharedEvent = (__bridge id<MTLSharedEvent>)event->impl;
    signal = [externalQueue commandBuffer];
    [signal encodeSignalEvent:sharedEvent value:11];
    [signal commit];
    [signal waitUntilCompleted];
    if (signal.status == MTLCommandBufferStatusError) {
        fprintf(stderr, "external event signal failed\n");
        goto cleanup;
    }

    wrap = wrap_desc(external, 16, MG_METAL_BUFFER_ACCESS_READ, MG_METAL_BUFFER_WRAP_NONE);
    memset(&copy, 0, sizeof(copy));
    copy.size = sizeof(copy);
    copy.byte_count = 16;

    if (expect_status(mgMetalBufferWrap(device, &wrap, &wrapped, &error), MG_STATUS_OK,
                      "wrap event-ordered buffer", &error) ||
        expect_status(mgBufferCreateShared(device, 16, &copyDst, &error), MG_STATUS_OK,
                      "create event-ordered destination", &error) ||
        expect_status(mgGraphCreate(&graph, &error), MG_STATUS_OK, "create event-ordered graph",
                      &error)) {
        goto cleanup;
    }
    copy.src = wrapped;
    copy.dst = copyDst;
    if (expect_status(mgGraphAddEventWaitNode(graph, event, 11, &waitNode, &error), MG_STATUS_OK,
                      "add event wait", &error) ||
        expect_status(mgGraphAddCopyNode(graph, &copy, &copyNode, &error), MG_STATUS_OK,
                      "add event-ordered copy", &error) ||
        expect_status(mgGraphAddDependency(graph, waitNode, copyNode, &error), MG_STATUS_OK,
                      "order wait before copy", &error) ||
        expect_status(mgGraphInstantiate(graph, device, &exec, &error), MG_STATUS_OK,
                      "instantiate event-ordered graph", &error) ||
        expect_status(mgGraphLaunch(exec, stream, &launch, &error), MG_STATUS_OK,
                      "launch event-ordered graph", &error)) {
        goto cleanup;
    }

    mg_launch_diagnostics_t diagnostics;
    memset(&diagnostics, 0, sizeof(diagnostics));
    diagnostics.size = sizeof(diagnostics);
    if (expect_status(mgLaunchGetDiagnostics(launch, &diagnostics, &error), MG_STATUS_OK,
                      "get event-ordered diagnostics", &error) ||
        diagnostics.event_wait_count != 1 ||
        !(diagnostics.sync_mode_flags & MG_SYNC_MODE_EVENT_WAIT)) {
        fprintf(stderr, "event wait diagnostics are wrong\n");
        goto cleanup;
    }
    if (expect_status(mgLaunchSynchronize(launch, &error), MG_STATUS_OK,
                      "synchronize event-ordered graph", &error) ||
        expect_bytes((const uint8_t *)mgBufferContents(copyDst), 0x5E, 16,
                     "MetalGraph read after explicit event ordering")) {
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

static int test_no_work_completion(mg_device_t *device, mg_stream_t *stream, bool barrier_only) {
    int rc = 1;
    mg_error_t *error = NULL;
    mg_graph_t *graph = NULL;
    mg_graph_exec_t *exec = NULL;
    mg_launch_t *first = NULL, *second = NULL;
    mg_node_t *barrier = NULL;
    mg_launch_diagnostics_t diag = {};

    if (expect_status(mgGraphCreate(&graph, &error), MG_STATUS_OK, "create no-work graph", &error))
        goto cleanup;
    if (barrier_only && expect_status(mgGraphAddBarrierNode(graph, &barrier, &error), MG_STATUS_OK,
                                      "add no-work barrier", &error))
        goto cleanup;
    if (expect_status(mgGraphInstantiate(graph, device, &exec, &error), MG_STATUS_OK,
                      "instantiate no-work graph", &error))
        goto cleanup;
    mgGraphDestroy(graph);
    graph = NULL;
    if (expect_status(mgGraphLaunch(exec, stream, &first, &error), MG_STATUS_OK,
                      "launch no-work graph", &error))
        goto cleanup;
    diag.size = sizeof(diag);
    if (expect_status(mgLaunchGetDiagnostics(first, &diag, &error), MG_STATUS_OK,
                      "initial no-work diagnostics", &error) ||
        __atomic_load_n(&exec->in_flight_count, __ATOMIC_ACQUIRE) > 1 || diag.completed != 0 ||
        diag.synchronize_count != 0 || diag.sync_mode_flags != 0 || diag.event_wait_count != 0 ||
        diag.event_signal_count != 0) {
        fprintf(stderr, "unexpected initial no-work state\n");
        goto cleanup;
    }
    if (expect_status(mgLaunchSynchronize(first, &error), MG_STATUS_OK,
                      "synchronize no-work launch", &error))
        goto cleanup;
    diag.size = sizeof(diag);
    if (expect_status(mgLaunchGetDiagnostics(first, &diag, &error), MG_STATUS_OK,
                      "completed no-work diagnostics", &error) ||
        __atomic_load_n(&exec->in_flight_count, __ATOMIC_ACQUIRE) != 0 || diag.completed != 1 ||
        diag.synchronize_count != 1 || diag.sync_mode_flags != MG_SYNC_MODE_LAUNCH_SYNCHRONIZE) {
        fprintf(stderr, "unexpected completed no-work state\n");
        goto cleanup;
    }
    /* A repeated sync of the first handle must not acknowledge a later launch. */
    if (expect_status(mgGraphLaunch(exec, stream, &second, &error), MG_STATUS_OK,
                      "relaunch no-work graph", &error) ||
        expect_status(mgLaunchSynchronize(first, &error), MG_STATUS_OK,
                      "repeat old no-work synchronization", &error) ||
        __atomic_load_n(&exec->in_flight_count, __ATOMIC_ACQUIRE) > 1) {
        fprintf(stderr, "repeat sync modified later launch accounting\n");
        goto cleanup;
    }
    diag.size = sizeof(diag);
    if (expect_status(mgLaunchGetDiagnostics(first, &diag, &error), MG_STATUS_OK,
                      "repeat no-work diagnostics", &error) ||
        diag.completed != 1 || diag.synchronize_count != 2 ||
        diag.sync_mode_flags != MG_SYNC_MODE_LAUNCH_SYNCHRONIZE ||
        expect_status(mgLaunchSynchronize(second, &error), MG_STATUS_OK,
                      "synchronize second no-work launch", &error) ||
        __atomic_load_n(&exec->in_flight_count, __ATOMIC_ACQUIRE) != 0 ||
        expect_status(mgLaunchSynchronize(second, &error), MG_STATUS_OK,
                      "repeat second no-work sync", &error) ||
        __atomic_load_n(&exec->in_flight_count, __ATOMIC_ACQUIRE) != 0) {
        fprintf(stderr, "unexpected repeated no-work state\n");
        goto cleanup;
    }
    diag.size = sizeof(diag);
    if (expect_status(mgLaunchGetDiagnostics(second, &diag, &error), MG_STATUS_OK,
                      "second no-work diagnostics", &error) ||
        diag.completed != 1 || diag.synchronize_count != 2 ||
        diag.sync_mode_flags != MG_SYNC_MODE_LAUNCH_SYNCHRONIZE) {
        fprintf(stderr, "unexpected second no-work diagnostics\n");
        goto cleanup;
    }
    rc = 0;
cleanup:
    mgLaunchDestroy(first);
    mgLaunchDestroy(second);
    mgGraphExecDestroy(exec);
    mgGraphDestroy(graph);
    mgErrorDestroy(error);
    return rc;
}

/* A fake responds only to status: these cases do not claim actual GPU failure. */
@interface MGStatusFixture : NSObject
@property(atomic) MTLCommandBufferStatus status;
@property(atomic, copy) void (^handler)(id<MTLCommandBuffer>);
- (void)finishWithStatus:(MTLCommandBufferStatus)status;
@end
@implementation MGStatusFixture
- (void)addCompletedHandler:(void (^)(id<MTLCommandBuffer>))handler {
    self.handler = handler;
}
- (void)commit {
    self.status = MTLCommandBufferStatusCommitted;
}
- (void)waitUntilCompleted {
}
- (NSError *)error {
    return [NSError errorWithDomain:@"synthetic-command-error" code:1 userInfo:nil];
}
- (void)finishWithStatus:(MTLCommandBufferStatus)status {
    self.status = status;
    void (^handler)(id<MTLCommandBuffer>) = self.handler;
    self.handler = nil;
    if (handler)
        handler((id<MTLCommandBuffer>)self);
}
@end

@interface MGQueueFixture : NSObject
@property(atomic, strong) MGStatusFixture *next;
@end
@implementation MGQueueFixture
- (id<MTLCommandBuffer>)commandBuffer {
    return (id<MTLCommandBuffer>)self.next;
}
@end

static int test_synthetic_completion_policy(void) {
    struct Case {
        const char *label;
        int first;
        int second;
        int count;
        bool mps;
        bool synced;
        bool ack;
    };
    const Case cases[] = {
        {"zero raw", 0, 0, 0, false, false, true},
        {"completed raw", MTLCommandBufferStatusCompleted, 0, 1, false, false, true},
        {"error excluded", MTLCommandBufferStatusError, 0, 1, false, false, false},
        {"pending excluded", MTLCommandBufferStatusCommitted, 0, 1, false, false, false},
        {"nil excluded", -1, 0, 1, false, false, false},
        {"missing array excluded", -2, 0, 1, false, false, false},
        {"unknown status excluded", 42, 0, 1, false, false, false},
        {"multiple completed", MTLCommandBufferStatusCompleted, MTLCommandBufferStatusCompleted, 2,
         false, false, true},
        {"one pending", MTLCommandBufferStatusCompleted, MTLCommandBufferStatusScheduled, 2, false,
         false, false},
        {"one error", MTLCommandBufferStatusCompleted, MTLCommandBufferStatusError, 2, false, false,
         false},
        {"later nil", MTLCommandBufferStatusCompleted, -1, 2, false, false, false},
        {"MPS excluded", MTLCommandBufferStatusCompleted, 0, 1, true, false, false},
        {"MPS zero excluded", 0, 0, 0, true, false, false},
        {"already synced", MTLCommandBufferStatusCompleted, 0, 1, false, true, false},
    };
    for (size_t c = 0; c < sizeof(cases) / sizeof(cases[0]); ++c) {
        mg_graph_exec_t *exec = (mg_graph_exec_t *)calloc(1, sizeof(*exec));
        mg_launch_t *launch = (mg_launch_t *)calloc(1, sizeof(*launch));
        if (!exec || !launch)
            abort();
        exec->ref_count = 2;
        exec->in_flight_count = 1;
        if (cases[c].mps) {
            exec->nodes = (mg_exec_node_t *)calloc(1, sizeof(*exec->nodes));
            if (!exec->nodes)
                abort();
            exec->node_count = 1;
            exec->nodes[0].kind = MG_NODE_MPSGRAPH;
        }
        launch->exec = exec;
        launch->completed = cases[c].synced;
        launch->impl_count = (size_t)cases[c].count;
        if (launch->impl_count && cases[c].first != -2) {
            launch->impls = (void **)calloc(launch->impl_count, sizeof(*launch->impls));
            if (!launch->impls)
                abort();
            int values[2] = {cases[c].first, cases[c].second};
            for (size_t i = 0; i < launch->impl_count; ++i) {
                if (values[i] == -1)
                    continue;
                MGStatusFixture *fixture = [MGStatusFixture new];
                fixture.status = (MTLCommandBufferStatus)values[i];
                launch->impls[i] = (__bridge_retained void *)fixture;
            }
        }
        mgLaunchDestroy(launch);
        if (__atomic_load_n(&exec->ref_count, __ATOMIC_ACQUIRE) != 1 ||
            __atomic_load_n(&exec->in_flight_count, __ATOMIC_ACQUIRE) != (cases[c].ack ? 0u : 1u)) {
            fprintf(stderr, "synthetic completion policy failed: %s\n", cases[c].label);
            mgGraphExecDestroy(exec);
            return 1;
        }
        mgGraphExecDestroy(exec);
    }
    mgLaunchDestroy(NULL);
    mgGraphExecDestroy(NULL);
    fprintf(stderr, "synthetic status and MPSGraph exclusion cases passed\n");
    return 0;
}

static bool wait_uint32(uint32_t *value, uint32_t expected);

/* Synthetic terminal errors exercise API accounting/error propagation; no GPU fault is claimed. */
static int test_synthetic_error_callback(mg_device_t *device) {
    int rc = 1;
    mg_error_t *error = NULL;
    mg_graph_t *graph = NULL;
    mg_graph_exec_t *exec = NULL;
    mg_launch_t *old = NULL, *later = NULL;
    mg_launch_diagnostics_t diag = {};
    MGQueueFixture *queue = [MGQueueFixture new];
    MGStatusFixture *first = [MGStatusFixture new], *second = [MGStatusFixture new];
    mg_stream_t *fakeStream = NULL;
    void *savedQueue = NULL;
    if (expect_status(mgStreamCreate(device, &fakeStream, &error), MG_STATUS_OK, "synthetic stream",
                      &error))
        goto cleanup;
    savedQueue = fakeStream->impl;
    fakeStream->impl = (__bridge void *)queue;
    if (expect_status(mgGraphCreate(&graph, &error), MG_STATUS_OK, "synthetic error graph",
                      &error) ||
        expect_status(mgGraphInstantiate(graph, device, &exec, &error), MG_STATUS_OK,
                      "synthetic error exec", &error))
        goto cleanup;
    queue.next = first;
    if (expect_status(mgGraphLaunch(exec, fakeStream, &old, &error), MG_STATUS_OK,
                      "synthetic error launch", &error))
        goto cleanup;
    for (int i = 0; !first.handler && i < 5000; ++i)
        usleep(1000);
    if (!first.handler)
        goto cleanup;
    [first finishWithStatus:MTLCommandBufferStatusError];
    diag.size = sizeof(diag);
    if (!wait_uint32(&exec->in_flight_count, 0) ||
        expect_status(mgLaunchGetDiagnostics(old, &diag, &error), MG_STATUS_OK, "error diagnostics",
                      &error) ||
        diag.completed || diag.synchronize_count || diag.sync_mode_flags)
        goto cleanup;
    queue.next = second;
    if (expect_status(mgGraphLaunch(exec, fakeStream, &later, &error), MG_STATUS_OK,
                      "synthetic later launch", &error) ||
        __atomic_load_n(&exec->in_flight_count, __ATOMIC_ACQUIRE) != 1)
        goto cleanup;
    for (int i = 0; i < 2; ++i) {
        mg_status_t status = mgLaunchSynchronize(old, &error);
        if (status != MG_STATUS_BACKEND_ERROR || !error ||
            mgErrorStage(error) != MG_ERROR_STAGE_COMPLETE ||
            __atomic_load_n(&exec->in_flight_count, __ATOMIC_ACQUIRE) != 1)
            goto cleanup;
        mgErrorDestroy(error);
        error = NULL;
    }
    mgLaunchDestroy(old);
    old = NULL;
    if (__atomic_load_n(&exec->in_flight_count, __ATOMIC_ACQUIRE) != 1)
        goto cleanup;
    for (int i = 0; !second.handler && i < 5000; ++i)
        usleep(1000);
    if (!second.handler)
        goto cleanup;
    [second finishWithStatus:MTLCommandBufferStatusCompleted];
    if (expect_status(mgLaunchSynchronize(later, &error), MG_STATUS_OK, "synthetic later sync",
                      &error) ||
        __atomic_load_n(&exec->in_flight_count, __ATOMIC_ACQUIRE) != 0)
        goto cleanup;
    rc = 0;
cleanup:
    if (first.handler)
        [first finishWithStatus:MTLCommandBufferStatusError];
    if (second.handler)
        [second finishWithStatus:MTLCommandBufferStatusCompleted];
    mgLaunchDestroy(old);
    mgLaunchDestroy(later);
    mgGraphExecDestroy(exec);
    mgGraphDestroy(graph);
    if (fakeStream) {
        fakeStream->impl = savedQueue;
        mgStreamDestroy(fakeStream);
    }
    mgErrorDestroy(error);
    if (rc)
        fprintf(stderr, "synthetic Error callback accounting failed\n");
    return rc;
}

typedef struct owner_counts {
    int retain;
    int release;
} owner_counts_t;
static void test_owner_retain(void *p) {
    __atomic_fetch_add(&((owner_counts_t *)p)->retain, 1, __ATOMIC_RELAXED);
}
static void test_owner_release(void *p) {
    __atomic_fetch_add(&((owner_counts_t *)p)->release, 1, __ATOMIC_RELEASE);
}
static bool wait_uint32(uint32_t *value, uint32_t expected) {
    struct timespec start, now;
    clock_gettime(CLOCK_MONOTONIC, &start);
    while (__atomic_load_n(value, __ATOMIC_ACQUIRE) != expected) {
        usleep(1000);
        clock_gettime(CLOCK_MONOTONIC, &now);
        if (now.tv_sec - start.tv_sec >= 5)
            return false;
    }
    return true;
}
static bool wait_owner_release(owner_counts_t *owner) {
    struct timespec start, now;
    clock_gettime(CLOCK_MONOTONIC, &start);
    while (__atomic_load_n(&owner->release, __ATOMIC_ACQUIRE) != 1) {
        usleep(1000);
        clock_gettime(CLOCK_MONOTONIC, &now);
        if (now.tv_sec - start.tv_sec >= 5)
            return false;
    }
    return true;
}

static void wait_for_raw_completion(mg_launch_t *launch) {
    struct timespec start, now;
    clock_gettime(CLOCK_MONOTONIC, &start);
    while (__atomic_load_n(&launch->exec->in_flight_count, __ATOMIC_ACQUIRE) != 0) {
        usleep(1000);
        clock_gettime(CLOCK_MONOTONIC, &now);
        if (now.tv_sec - start.tv_sec >= 5) {
            fprintf(stderr, "Metal completion timeout\n");
            _Exit(4);
        }
    }
}

/* mode 0: destroy completed launch, patch/relaunch; modes 1/2 destroy exec first,
 * then destroy launch or explicitly synchronize it. */
static int test_completed_raw_destroy(mg_device_t *device, mg_stream_t *stream, id<MTLDevice> metal,
                                      int mode) {
    int rc = 1;
    mg_error_t *error = NULL;
    mg_buffer_t *wrapped = NULL, *candidate = NULL;
    mg_graph_t *graph = NULL;
    mg_graph_exec_t *exec = NULL;
    mg_launch_t *launch = NULL, *later = NULL;
    mg_node_t *node = NULL;
    mg_node_id_t node_id = MG_NODE_ID_INVALID;
    owner_counts_t owner = {};
    mg_metal_buffer_wrap_desc_t wd = {};
    mg_fill_desc_t fill = {};
    id<MTLBuffer> native = [metal newBufferWithLength:32 options:MTLResourceStorageModeShared];
    if (!native)
        goto cleanup;
    memset([native contents], 0, 32);
    wd = wrap_desc(native, 32, MG_METAL_BUFFER_ACCESS_READ_WRITE,
                   MG_METAL_BUFFER_WRAP_MUTABLE | MG_METAL_BUFFER_WRAP_RETAIN_OWNER);
    wd.owner_context = &owner;
    wd.owner_retain = test_owner_retain;
    wd.owner_release = test_owner_release;
    if (expect_status(mgMetalBufferWrap(device, &wd, &wrapped, &error), MG_STATUS_OK, "owner wrap",
                      &error))
        goto cleanup;
    wd = wrap_desc(native, 32, MG_METAL_BUFFER_ACCESS_READ_WRITE, MG_METAL_BUFFER_WRAP_MUTABLE);
    if (expect_status(mgMetalBufferWrap(device, &wd, &candidate, &error), MG_STATUS_OK,
                      "candidate wrap", &error))
        goto cleanup;
    fill.size = sizeof(fill);
    fill.dst = wrapped;
    fill.byte_count = 16;
    fill.value = 0x5a;
    if (expect_status(mgGraphCreate(&graph, &error), MG_STATUS_OK, "completed graph", &error) ||
        expect_status(mgGraphAddFillNode(graph, &fill, &node, &error), MG_STATUS_OK,
                      "completed fill", &error) ||
        expect_status(mgGraphSetNodePatchFlags(graph, node,
                                               MG_PATCH_FILL_BUFFER | MG_PATCH_FILL_VALUE, &error),
                      MG_STATUS_OK, "completed flags", &error))
        goto cleanup;
    node_id = mgNodeId(node);
    if (expect_status(mgGraphInstantiate(graph, device, &exec, &error), MG_STATUS_OK,
                      "completed instantiate", &error))
        goto cleanup;
    mgGraphDestroy(graph);
    graph = NULL;
    mgBufferDestroy(wrapped);
    wrapped = NULL;
    if (expect_status(mgGraphLaunch(exec, stream, &launch, &error), MG_STATUS_OK,
                      "completed launch", &error))
        goto cleanup;
    wait_for_raw_completion(launch);
    if (((uint8_t *)[native contents])[0] != 0x5a ||
        __atomic_load_n(&exec->ref_count, __ATOMIC_ACQUIRE) != 2 ||
        __atomic_load_n(&exec->in_flight_count, __ATOMIC_ACQUIRE) > 1 ||
        __atomic_load_n(&owner.retain, __ATOMIC_ACQUIRE) != 1 ||
        __atomic_load_n(&owner.release, __ATOMIC_ACQUIRE) != 0 || launch->completed ||
        launch->synchronize_count || launch->sync_mode_flags)
        goto cleanup;
    if (mode == 4) {
        fill.dst = candidate;
        fill.value = 0x6b;
        if (expect_status(mgGraphExecPatchFillNode(exec, node_id, &fill, &error), MG_STATUS_OK,
                          "patch while old unsynchronized handle lives", &error) ||
            __atomic_load_n(&owner.release, __ATOMIC_ACQUIRE) != 0)
            goto cleanup;
        mgLaunchDestroy(launch);
        launch = NULL;
        if (!wait_owner_release(&owner))
            goto cleanup;
    } else if (mode) {
        mgGraphExecDestroy(exec);
        exec = NULL;
        if (__atomic_load_n(&owner.release, __ATOMIC_ACQUIRE) != 0)
            goto cleanup;
        if (mode == 2 && expect_status(mgLaunchSynchronize(launch, &error), MG_STATUS_OK,
                                       "synchronize after public exec destroy", &error))
            goto cleanup;
        mgLaunchDestroy(launch);
        launch = NULL;
        if (__atomic_load_n(&owner.retain, __ATOMIC_ACQUIRE) != 1 || !wait_owner_release(&owner))
            goto cleanup;
    } else {
        mgLaunchDestroy(launch);
        launch = NULL;
        if (!wait_uint32(&exec->ref_count, 1) ||
            __atomic_load_n(&exec->in_flight_count, __ATOMIC_ACQUIRE) != 0 ||
            __atomic_load_n(&owner.release, __ATOMIC_ACQUIRE) != 0)
            goto cleanup;
        fill.dst = candidate;
        fill.value = 0x6b;
        if (expect_status(mgGraphExecPatchFillNode(exec, node_id, &fill, &error), MG_STATUS_OK,
                          "patch after completed destroy", &error) ||
            __atomic_load_n(&owner.release, __ATOMIC_ACQUIRE) != 1 ||
            expect_status(mgGraphLaunch(exec, stream, &launch, &error), MG_STATUS_OK,
                          "completed relaunch", &error) ||
            expect_status(mgLaunchSynchronize(launch, &error), MG_STATUS_OK,
                          "sync completed relaunch", &error) ||
            ((uint8_t *)[native contents])[0] != 0x6b)
            goto cleanup;
    }
    rc = 0;
cleanup:
    if (launch && !launch->completed)
        wait_for_raw_completion(launch);
    if (later && !later->completed)
        wait_for_raw_completion(later);
    mgLaunchDestroy(launch);
    mgLaunchDestroy(later);
    mgGraphExecDestroy(exec);
    mgGraphDestroy(graph);
    mgBufferDestroy(wrapped);
    mgBufferDestroy(candidate);
    mgErrorDestroy(error);
    if (rc || __atomic_load_n(&owner.retain, __ATOMIC_ACQUIRE) !=
                  __atomic_load_n(&owner.release, __ATOMIC_ACQUIRE)) {
        fprintf(stderr, "completed destroy mode %d failed (%d/%d)\n", mode,
                __atomic_load_n(&owner.retain, __ATOMIC_ACQUIRE),
                __atomic_load_n(&owner.release, __ATOMIC_ACQUIRE));
        return 1;
    }
    return 0;
}

static int test_failed_instantiation_owner(mg_device_t *device, id<MTLDevice> metal) {
    int rc = 1;
    mg_error_t *error = NULL;
    mg_buffer_t *wrapped = NULL;
    mg_graph_t *graph = NULL;
    mg_graph_exec_t *exec = NULL;
    mg_node_t *node = NULL;
    owner_counts_t owner = {};
    mg_metal_buffer_wrap_desc_t wd = {};
    mg_buffer_binding_t binding = {};
    mg_dispatch_desc_t dispatch = {};
    id<MTLBuffer> native = [metal newBufferWithLength:32 options:MTLResourceStorageModeShared];
    if (!native)
        goto cleanup;
    wd = wrap_desc(native, 32, MG_METAL_BUFFER_ACCESS_READ_WRITE,
                   MG_METAL_BUFFER_WRAP_MUTABLE | MG_METAL_BUFFER_WRAP_RETAIN_OWNER);
    wd.owner_context = &owner;
    wd.owner_retain = test_owner_retain;
    wd.owner_release = test_owner_release;
    if (expect_status(mgMetalBufferWrap(device, &wd, &wrapped, &error), MG_STATUS_OK,
                      "failed-inst owner wrap", &error))
        goto cleanup;
    binding.buffer = wrapped;
    dispatch.size = sizeof(dispatch);
    dispatch.metallib_path = "missing-lifetime-test.metallib";
    dispatch.kernel_name = "missing";
    dispatch.grid_size[0] = dispatch.grid_size[1] = dispatch.grid_size[2] = 1;
    dispatch.threads_per_threadgroup[0] = dispatch.threads_per_threadgroup[1] =
        dispatch.threads_per_threadgroup[2] = 1;
    dispatch.buffers = &binding;
    dispatch.buffer_count = 1;
    if (expect_status(mgGraphCreate(&graph, &error), MG_STATUS_OK, "failed-inst graph", &error) ||
        expect_status(mgGraphAddDispatchNode(graph, &dispatch, &node, &error), MG_STATUS_OK,
                      "failed-inst dispatch", &error) ||
        expect_status(mgGraphInstantiate(graph, device, &exec, &error), MG_STATUS_BACKEND_ERROR,
                      "expected instantiate failure", &error) ||
        exec || __atomic_load_n(&owner.retain, __ATOMIC_ACQUIRE) != 1 ||
        __atomic_load_n(&owner.release, __ATOMIC_ACQUIRE) != 0)
        goto cleanup;
    mgGraphDestroy(graph);
    graph = NULL;
    if (__atomic_load_n(&owner.release, __ATOMIC_ACQUIRE) != 0)
        goto cleanup;
    mgBufferDestroy(wrapped);
    wrapped = NULL;
    if (__atomic_load_n(&owner.retain, __ATOMIC_ACQUIRE) != 1 ||
        __atomic_load_n(&owner.release, __ATOMIC_ACQUIRE) != 1)
        goto cleanup;
    rc = 0;
cleanup:
    mgGraphExecDestroy(exec);
    mgGraphDestroy(graph);
    mgBufferDestroy(wrapped);
    mgErrorDestroy(error);
    if (rc || __atomic_load_n(&owner.retain, __ATOMIC_ACQUIRE) !=
                  __atomic_load_n(&owner.release, __ATOMIC_ACQUIRE)) {
        fprintf(stderr, "failed-inst owner balance failed (%d/%d)\n",
                __atomic_load_n(&owner.retain, __ATOMIC_ACQUIRE),
                __atomic_load_n(&owner.release, __ATOMIC_ACQUIRE));
        return 1;
    }
    return rc;
}

static int test_zero_destroy_and_preflight(mg_device_t *device, mg_stream_t *stream) {
    int rc = 1;
    mg_error_t *error = NULL;
    mg_graph_t *graph = NULL;
    mg_graph_exec_t *exec = NULL;
    mg_launch_t *launch = NULL;
    mg_node_t *barrier = NULL;
    if (expect_status(mgGraphCreate(&graph, &error), MG_STATUS_OK, "zero graph", &error) ||
        expect_status(mgGraphAddBarrierNode(graph, &barrier, &error), MG_STATUS_OK, "zero barrier",
                      &error) ||
        expect_status(mgGraphInstantiate(graph, device, &exec, &error), MG_STATUS_OK, "zero exec",
                      &error))
        goto cleanup;
    mgGraphDestroy(graph);
    graph = NULL;
    for (int i = 0; i < 20; ++i)
        if (!mg_test_tracker_seal_zero_pending(exec, stream))
            goto cleanup;
    if (!wait_uint32(&exec->ref_count, 1))
        goto cleanup;
    exec->ref_count = UINT32_MAX;
    if (expect_status(mgGraphLaunch(exec, stream, &launch, &error), MG_STATUS_INVALID_ARGUMENT,
                      "refcount overflow preflight", &error) ||
        launch || __atomic_load_n(&exec->in_flight_count, __ATOMIC_ACQUIRE) != 0 ||
        __atomic_load_n(&exec->ref_count, __ATOMIC_ACQUIRE) != UINT32_MAX)
        goto cleanup;
    exec->ref_count = 1;
    exec->in_flight_count = UINT32_MAX;
    if (expect_status(mgGraphLaunch(exec, stream, &launch, &error), MG_STATUS_INVALID_ARGUMENT,
                      "in-flight overflow preflight", &error) ||
        launch || __atomic_load_n(&exec->ref_count, __ATOMIC_ACQUIRE) != 1 ||
        __atomic_load_n(&exec->in_flight_count, __ATOMIC_ACQUIRE) != UINT32_MAX)
        goto cleanup;
    exec->in_flight_count = 0;
    /* A deliberately invalid frozen node triggers launch cleanup before any commit. */
    exec->nodes[0].kind = (mg_node_kind_t)999;
    if (expect_status(mgGraphLaunch(exec, stream, &launch, &error), MG_STATUS_OK,
                      "accept launch before deferred encoding failure", &error) ||
        expect_status(mgLaunchSynchronize(launch, &error), MG_STATUS_BACKEND_ERROR,
                      "deferred allocated launch failure", &error))
        goto cleanup;
    mgLaunchDestroy(launch);
    launch = NULL;
    if (!wait_uint32(&exec->ref_count, 1) ||
        __atomic_load_n(&exec->in_flight_count, __ATOMIC_ACQUIRE) != 0)
        goto cleanup;
    exec->nodes[0].kind = MG_NODE_BARRIER;
    if (expect_status(mgGraphLaunch(exec, NULL, &launch, &error), MG_STATUS_INVALID_ARGUMENT,
                      "invalid stream preflight", &error) ||
        launch || __atomic_load_n(&exec->ref_count, __ATOMIC_ACQUIRE) != 1 ||
        __atomic_load_n(&exec->in_flight_count, __ATOMIC_ACQUIRE) != 0 ||
        expect_status(mgGraphLaunch(exec, stream, &launch, &error), MG_STATUS_OK, "zero launch",
                      &error) ||
        __atomic_load_n(&exec->ref_count, __ATOMIC_ACQUIRE) != 2)
        goto cleanup;
    mgLaunchDestroy(launch);
    launch = NULL;
    if (!wait_uint32(&exec->in_flight_count, 0) || !wait_uint32(&exec->ref_count, 1))
        goto cleanup;
    if (expect_status(mgGraphLaunch(exec, stream, &launch, &error), MG_STATUS_OK, "zero relaunch",
                      &error) ||
        expect_status(mgLaunchSynchronize(launch, &error), MG_STATUS_OK, "zero resync", &error))
        goto cleanup;
    rc = 0;
cleanup:
    /* Overflow values are synthetic and must not escape into ownership cleanup. */
    if (exec && __atomic_load_n(&exec->ref_count, __ATOMIC_ACQUIRE) == UINT32_MAX)
        exec->ref_count = 1;
    if (exec && __atomic_load_n(&exec->in_flight_count, __ATOMIC_ACQUIRE) == UINT32_MAX)
        exec->in_flight_count = 0;
    mgLaunchDestroy(launch);
    mgGraphExecDestroy(exec);
    mgGraphDestroy(graph);
    mgErrorDestroy(error);
    if (rc)
        fprintf(stderr, "zero destroy or preflight test failed\n");
    return rc;
}

typedef struct concurrent_release {
    mg_buffer_t *buffer;
    mg_event_t *event;
    int go;
} concurrent_release_t;
static void *release_public_handles(void *context) {
    concurrent_release_t *release = (concurrent_release_t *)context;
    while (!__atomic_load_n(&release->go, __ATOMIC_ACQUIRE))
        usleep(100);
    mgBufferDestroy(release->buffer);
    mgEventDestroy(release->event);
    return NULL;
}

/* Producer runs on an independent queue and only signals the event: it never writes the
 * tested data. The bounded cleanup also signals it if a check fails while work is held. */
static bool signal_independent_event(id<MTLCommandQueue> producer, id<MTLSharedEvent> event,
                                     uint64_t value) {
    if (event.signaledValue < value) {
        id<MTLCommandBuffer> cb = [producer commandBuffer];
        if (!cb)
            return false;
        [cb encodeSignalEvent:event value:value];
        [cb commit];
    }
    struct timespec start, now;
    clock_gettime(CLOCK_MONOTONIC, &start);
    while (event.signaledValue < value) {
        usleep(1000);
        clock_gettime(CLOCK_MONOTONIC, &now);
        if (now.tv_sec - start.tv_sec >= 5)
            return false;
    }
    return true;
}

/* 0: destroy in-flight launch, reuse exec. 1: also destroy public exec.
 * 2: injected error after raw commit; 3: exception before commit; 4: registration failure;
 * 5: stage setup failure; 6: metadata preflight exception; 7: admission gate exception. */
static int test_running_destroy_or_partial(mg_device_t *device, mg_stream_t *stream,
                                           id<MTLDevice> metal, int mode) {
    int rc = 1;
    bool submitted = false, workerStarted = false;
    pthread_t worker = {};
    concurrent_release_t release = {};
    mg_error_t *error = NULL;
    mg_buffer_t *wrapped = NULL, *candidate = NULL;
    mg_graph_t *graph = NULL;
    mg_graph_exec_t *exec = NULL;
    mg_launch_t *launch = NULL;
    mg_event_t *event = NULL;
    mg_node_t *waitNode = NULL, *fillNode = NULL;
    mg_node_id_t fillId = MG_NODE_ID_INVALID;
    owner_counts_t owner = {};
    mg_metal_buffer_wrap_desc_t wd = {};
    mg_fill_desc_t fill = {};
    id<MTLBuffer> native = [metal newBufferWithLength:32 options:MTLResourceStorageModeShared];
    id<MTLCommandQueue> producer = [metal newCommandQueue];
    id<MTLSharedEvent> nativeEvent = nil;
    if (!native || !producer)
        goto cleanup;
    memset([native contents], 0, 32);
    wd = wrap_desc(native, 32, MG_METAL_BUFFER_ACCESS_READ_WRITE,
                   MG_METAL_BUFFER_WRAP_MUTABLE | MG_METAL_BUFFER_WRAP_RETAIN_OWNER);
    wd.owner_context = &owner;
    wd.owner_retain = test_owner_retain;
    wd.owner_release = test_owner_release;
    if (expect_status(mgMetalBufferWrap(device, &wd, &wrapped, &error), MG_STATUS_OK,
                      "held owner wrap", &error))
        goto cleanup;
    wd = wrap_desc(native, 32, MG_METAL_BUFFER_ACCESS_READ_WRITE, MG_METAL_BUFFER_WRAP_MUTABLE);
    if (expect_status(mgMetalBufferWrap(device, &wd, &candidate, &error), MG_STATUS_OK,
                      "held candidate", &error) ||
        expect_status(mgEventCreate(device, &event, &error), MG_STATUS_OK, "held event", &error) ||
        expect_status(mgGraphCreate(&graph, &error), MG_STATUS_OK, "held graph", &error))
        goto cleanup;
    nativeEvent = (__bridge id<MTLSharedEvent>)event->impl;
    fill.size = sizeof(fill);
    fill.dst = wrapped;
    fill.byte_count = 16;
    fill.value = 0x5a;
    if (expect_status(mgGraphAddEventWaitNode(graph, event, 1, &waitNode, &error), MG_STATUS_OK,
                      "held wait", &error) ||
        expect_status(mgGraphAddFillNode(graph, &fill, &fillNode, &error), MG_STATUS_OK,
                      "held fill", &error) ||
        expect_status(mgGraphAddDependency(graph, waitNode, fillNode, &error), MG_STATUS_OK,
                      "held dependency", &error) ||
        expect_status(mgGraphSetNodePatchFlags(graph, fillNode,
                                               MG_PATCH_FILL_BUFFER | MG_PATCH_FILL_VALUE, &error),
                      MG_STATUS_OK, "held flags", &error))
        goto cleanup;
    fillId = mgNodeId(fillNode);
    if (expect_status(mgGraphInstantiate(graph, device, &exec, &error), MG_STATUS_OK,
                      "held instantiate", &error))
        goto cleanup;
    mgGraphDestroy(graph);
    graph = NULL;
    if (mode != 1) {
        mgBufferDestroy(wrapped);
        wrapped = NULL;
    }
    if (mode == 2)
        mg_test_fail_next_raw_after_commit(exec);
    if (mode == 3)
        mg_test_fail_next_raw_before_commit(exec);
    if (mode == 4)
        mg_test_fail_next_raw_registration(exec);
    if (mode == 5)
        exec->test_stage_failure = 1;
    if (mode == 6 || mode == 7) {
        exec->test_preflight_failure = mode == 6 ? 1 : 2;
        mg_status_t status = mgGraphLaunch(exec, stream, &launch, &error);
        if (status != MG_STATUS_BACKEND_ERROR || launch || !error ||
            mgErrorStage(error) != MG_ERROR_STAGE_ENCODE)
            goto cleanup;
        mgErrorDestroy(error);
        error = NULL;
        if (!wait_uint32(&exec->in_flight_count, 0) || !wait_uint32(&exec->ref_count, 1) ||
            __atomic_load_n(&owner.retain, __ATOMIC_ACQUIRE) != 1 ||
            __atomic_load_n(&owner.release, __ATOMIC_ACQUIRE) != 0 ||
            ((uint8_t *)[native contents])[0] != 0)
            goto cleanup;
        fill.dst = candidate;
        fill.value = 0x6b;
        if (expect_status(mgGraphExecPatchFillNode(exec, fillId, &fill, &error), MG_STATUS_OK,
                          "patch after preflight exception", &error) ||
            !wait_owner_release(&owner) || !signal_independent_event(producer, nativeEvent, 1) ||
            expect_status(mgGraphLaunch(exec, stream, &launch, &error), MG_STATUS_OK,
                          "launch after preflight exception", &error) ||
            expect_status(mgLaunchSynchronize(launch, &error), MG_STATUS_OK,
                          "sync after preflight exception", &error) ||
            ((uint8_t *)[native contents])[0] != 0x6b)
            goto cleanup;
        rc = 0;
        goto cleanup;
    }
    if (expect_status(mgGraphLaunch(exec, stream, &launch, &error), MG_STATUS_OK,
                      "accept held launch", &error))
        goto cleanup;
    if (mode == 3 || mode == 4 || mode == 5) {
        mg_status_t status = mgLaunchSynchronize(launch, &error);
        if (status != MG_STATUS_BACKEND_ERROR || !error ||
            mgErrorStage(error) != (mode == 3 ? MG_ERROR_STAGE_COMMIT : MG_ERROR_STAGE_ENCODE))
            goto cleanup;
        mgErrorDestroy(error);
        error = NULL;
        mgLaunchDestroy(launch);
        launch = NULL;
        if (!wait_uint32(&exec->in_flight_count, 0) || !wait_uint32(&exec->ref_count, 1) ||
            ((uint8_t *)[native contents])[0] != 0)
            goto cleanup;
        fill.dst = candidate;
        fill.value = 0x6b;
        if (expect_status(mgGraphExecPatchFillNode(exec, fillId, &fill, &error), MG_STATUS_OK,
                          "patch after unsubmitted exception", &error) ||
            !signal_independent_event(producer, nativeEvent, 1) ||
            expect_status(mgGraphLaunch(exec, stream, &launch, &error), MG_STATUS_OK,
                          "launch after unsubmitted exception", &error) ||
            expect_status(mgLaunchSynchronize(launch, &error), MG_STATUS_OK,
                          "sync after unsubmitted exception", &error) ||
            ((uint8_t *)[native contents])[0] != 0x6b)
            goto cleanup;
        rc = 0;
        goto cleanup;
    }
    submitted = true;
    if (!launch || nativeEvent.signaledValue != 0)
        goto cleanup;
    mgLaunchDestroy(launch);
    launch = NULL; /* no wait even after deferred post-commit error */
    if (__atomic_load_n(&owner.retain, __ATOMIC_ACQUIRE) != 1 ||
        __atomic_load_n(&owner.release, __ATOMIC_ACQUIRE) != 0 ||
        __atomic_load_n(&exec->in_flight_count, __ATOMIC_ACQUIRE) != 1 ||
        ((uint8_t *)[native contents])[0] != 0)
        goto cleanup;
    if (mode == 1) {
        mgGraphExecDestroy(exec);
        exec = NULL;
        release.buffer = wrapped;
        release.event = event;
        if (pthread_create(&worker, NULL, release_public_handles, &release) != 0)
            goto cleanup;
        workerStarted = true;
        wrapped = NULL;
        event = NULL;
        if (__atomic_load_n(&owner.release, __ATOMIC_ACQUIRE) != 0)
            goto cleanup;
    } else {
        fill.dst = candidate;
        fill.value = 0x6b;
        if (expect_status(mgGraphExecPatchFillNode(exec, fillId, &fill, &error),
                          MG_STATUS_INVALID_ARGUMENT, "held patch blocked", &error) ||
            expect_status(mgGraphLaunch(exec, stream, &launch, &error), MG_STATUS_INVALID_ARGUMENT,
                          "held relaunch blocked", &error) ||
            launch)
            goto cleanup;
    }
    if (workerStarted)
        __atomic_store_n(&release.go, 1, __ATOMIC_RELEASE);
    if (!signal_independent_event(producer, nativeEvent, 1))
        goto cleanup;
    if (mode == 1) {
        pthread_join(worker, NULL);
        workerStarted = false;
        if (!wait_owner_release(&owner))
            goto cleanup;
    } else {
        if (!wait_uint32(&exec->in_flight_count, 0) || !wait_uint32(&exec->ref_count, 1))
            goto cleanup;
    }
    if (((uint8_t *)[native contents])[0] != 0x5a)
        goto cleanup;
    if (mode != 1) {
        if (expect_status(mgGraphExecPatchFillNode(exec, fillId, &fill, &error), MG_STATUS_OK,
                          "patch after held completion", &error) ||
            expect_status(mgGraphLaunch(exec, stream, &launch, &error), MG_STATUS_OK,
                          "held relaunch after completion", &error) ||
            expect_status(mgLaunchSynchronize(launch, &error), MG_STATUS_OK, "held resync",
                          &error) ||
            ((uint8_t *)[native contents])[0] != 0x6b)
            goto cleanup;
    }
    rc = 0;
cleanup:
    if (workerStarted) {
        __atomic_store_n(&release.go, 1, __ATOMIC_RELEASE);
        pthread_join(worker, NULL);
        workerStarted = false;
    }
    if (submitted && nativeEvent && nativeEvent.signaledValue < 1 &&
        !signal_independent_event(producer, nativeEvent, 1))
        _Exit(8);
    if (launch && !launch->completed)
        wait_for_raw_completion(launch);
    mgLaunchDestroy(launch);
    if (exec && submitted && !wait_uint32(&exec->in_flight_count, 0))
        _Exit(9);
    mgGraphExecDestroy(exec);
    mgGraphDestroy(graph);
    mgEventDestroy(event);
    mgBufferDestroy(wrapped);
    mgBufferDestroy(candidate);
    mgErrorDestroy(error);
    if (__atomic_load_n(&owner.retain, __ATOMIC_ACQUIRE) !=
        __atomic_load_n(&owner.release, __ATOMIC_ACQUIRE)) {
        if (!wait_owner_release(&owner)) {
            fprintf(stderr, "held owner timeout mode=%d\n", mode);
            return 1;
        }
    }
    if (rc)
        fprintf(stderr, "running destroy/partial test failed mode=%d\n", mode);
    return rc;
}

static int test_old_handle_new_held(mg_device_t *device, mg_stream_t *stream, id<MTLDevice> metal) {
    int rc = 1;
    bool submitted = false;
    mg_error_t *error = NULL;
    mg_graph_t *graph = NULL;
    mg_graph_exec_t *exec = NULL;
    mg_event_t *event = NULL;
    mg_node_t *waitNode = NULL, *fillNode = NULL;
    mg_buffer_t *buffer = NULL;
    mg_launch_t *old = NULL, *later = NULL;
    mg_node_id_t waitId = MG_NODE_ID_INVALID, fillId = MG_NODE_ID_INVALID;
    mg_fill_desc_t fill = {};
    id<MTLSharedEvent> nativeEvent = nil;
    id<MTLCommandQueue> producer = [metal newCommandQueue];
    if (!producer)
        goto cleanup;
    if (expect_status(mgEventCreate(device, &event, &error), MG_STATUS_OK, "old event", &error) ||
        expect_status(mgBufferCreateShared(device, 16, &buffer, &error), MG_STATUS_OK, "old buffer",
                      &error) ||
        expect_status(mgGraphCreate(&graph, &error), MG_STATUS_OK, "old graph", &error))
        goto cleanup;
    nativeEvent = (__bridge id<MTLSharedEvent>)event->impl;
    fill.size = sizeof(fill);
    fill.dst = buffer;
    fill.byte_count = 16;
    fill.value = 0x44;
    if (expect_status(mgGraphAddEventWaitNode(graph, event, 1, &waitNode, &error), MG_STATUS_OK,
                      "old wait", &error) ||
        expect_status(mgGraphAddFillNode(graph, &fill, &fillNode, &error), MG_STATUS_OK, "old fill",
                      &error) ||
        expect_status(mgGraphAddDependency(graph, waitNode, fillNode, &error), MG_STATUS_OK,
                      "old dependency", &error) ||
        expect_status(mgGraphSetNodePatchFlags(graph, waitNode, MG_PATCH_EVENT_VALUE, &error),
                      MG_STATUS_OK, "old wait patchable", &error) ||
        expect_status(mgGraphSetNodePatchFlags(graph, fillNode, MG_PATCH_FILL_VALUE, &error),
                      MG_STATUS_OK, "old fill patchable", &error))
        goto cleanup;
    waitId = mgNodeId(waitNode);
    fillId = mgNodeId(fillNode);
    if (expect_status(mgGraphInstantiate(graph, device, &exec, &error), MG_STATUS_OK,
                      "old instantiate", &error) ||
        expect_status(mgGraphLaunch(exec, stream, &old, &error), MG_STATUS_OK, "old launch",
                      &error))
        goto cleanup;
    submitted = true;
    if (!signal_independent_event(producer, nativeEvent, 1))
        goto cleanup;
    wait_for_raw_completion(old);
    if (!wait_uint32(&exec->in_flight_count, 0) ||
        expect_status(mgGraphExecPatchEventValue(exec, waitId, 2, &error), MG_STATUS_OK,
                      "patch later wait", &error) ||
        expect_status(mgGraphLaunch(exec, stream, &later, &error), MG_STATUS_OK,
                      "later held launch", &error))
        goto cleanup;
    mgLaunchDestroy(old);
    old = NULL;
    if (__atomic_load_n(&exec->in_flight_count, __ATOMIC_ACQUIRE) != 1)
        goto cleanup;
    fill.value = 0x55;
    if (expect_status(mgGraphExecPatchFillNode(exec, fillId, &fill, &error),
                      MG_STATUS_INVALID_ARGUMENT, "old destroy must not unblock later launch",
                      &error) ||
        !signal_independent_event(producer, nativeEvent, 2) ||
        expect_status(mgLaunchSynchronize(later, &error), MG_STATUS_OK, "later sync", &error) ||
        expect_status(mgGraphExecPatchFillNode(exec, fillId, &fill, &error), MG_STATUS_OK,
                      "patch after later", &error))
        goto cleanup;
    rc = 0;
cleanup:
    if (submitted && nativeEvent && nativeEvent.signaledValue < 2 &&
        !signal_independent_event(producer, nativeEvent, 2))
        _Exit(10);
    if (old && !old->completed)
        wait_for_raw_completion(old);
    if (later && !later->completed)
        wait_for_raw_completion(later);
    mgLaunchDestroy(old);
    mgLaunchDestroy(later);
    mgGraphExecDestroy(exec);
    mgGraphDestroy(graph);
    mgBufferDestroy(buffer);
    mgEventDestroy(event);
    mgErrorDestroy(error);
    if (rc)
        fprintf(stderr, "old-handle/new-launch test failed\n");
    return rc;
}

typedef struct reentry_owner {
    mg_stream_t *stream;
    mg_graph_exec_t *next;
    int retains, releases, done, status;
} reentry_owner_t;
static void reentry_retain(void *p) {
    __atomic_fetch_add(&((reentry_owner_t *)p)->retains, 1, __ATOMIC_RELAXED);
}
static void reentry_release(void *p) {
    reentry_owner_t *owner = (reentry_owner_t *)p;
    mg_launch_t *launch = NULL;
    mg_error_t *error = NULL;
    mg_status_t status = mgGraphLaunch(owner->next, owner->stream, &launch, &error);
    if (status == MG_STATUS_OK)
        status = mgLaunchSynchronize(launch, &error);
    mgLaunchDestroy(launch);
    mgErrorDestroy(error);
    __atomic_store_n(&owner->status, (int)status, __ATOMIC_RELEASE);
    __atomic_fetch_add(&owner->releases, 1, __ATOMIC_RELEASE);
    __atomic_store_n(&owner->done, 1, __ATOMIC_RELEASE);
}
static int test_owner_callback_reentry(mg_device_t *device, id<MTLDevice> metal) {
    int rc = 1;
    bool submitted = false;
    mg_error_t *error = NULL;
    mg_stream_t *stream = NULL;
    mg_event_t *event = NULL;
    mg_buffer_t *wrapped = NULL, *nextBuffer = NULL;
    mg_graph_t *graph = NULL, *nextGraph = NULL;
    mg_graph_exec_t *exec = NULL, *nextExec = NULL;
    mg_launch_t *launch = NULL;
    mg_node_t *wait = NULL, *fillNode = NULL;
    mg_fill_desc_t fill = {};
    mg_metal_buffer_wrap_desc_t wd = {};
    reentry_owner_t owner = {};
    id<MTLBuffer> native = [metal newBufferWithLength:16 options:MTLResourceStorageModeShared];
    id<MTLCommandQueue> producer = [metal newCommandQueue];
    id<MTLSharedEvent> nativeEvent = nil;
    if (!native || !producer)
        goto cleanup;
    if (expect_status(mgStreamCreate(device, &stream, &error), MG_STATUS_OK, "reentry stream",
                      &error) ||
        expect_status(mgEventCreate(device, &event, &error), MG_STATUS_OK, "reentry event",
                      &error) ||
        expect_status(mgBufferCreateShared(device, 16, &nextBuffer, &error), MG_STATUS_OK,
                      "reentry next buffer", &error) ||
        expect_status(mgGraphCreate(&nextGraph, &error), MG_STATUS_OK, "reentry next graph",
                      &error))
        goto cleanup;
    nativeEvent = (__bridge id<MTLSharedEvent>)event->impl;
    fill.size = sizeof(fill);
    fill.dst = nextBuffer;
    fill.byte_count = 16;
    fill.value = 0x66;
    if (expect_status(mgGraphAddFillNode(nextGraph, &fill, &fillNode, &error), MG_STATUS_OK,
                      "reentry next fill", &error) ||
        expect_status(mgGraphInstantiate(nextGraph, device, &nextExec, &error), MG_STATUS_OK,
                      "reentry next exec", &error))
        goto cleanup;
    owner.stream = stream;
    owner.next = nextExec;
    wd = wrap_desc(native, 16, MG_METAL_BUFFER_ACCESS_READ_WRITE,
                   MG_METAL_BUFFER_WRAP_MUTABLE | MG_METAL_BUFFER_WRAP_RETAIN_OWNER);
    wd.owner_context = &owner;
    wd.owner_retain = reentry_retain;
    wd.owner_release = reentry_release;
    if (expect_status(mgMetalBufferWrap(device, &wd, &wrapped, &error), MG_STATUS_OK,
                      "reentry wrap", &error) ||
        expect_status(mgGraphCreate(&graph, &error), MG_STATUS_OK, "reentry graph", &error))
        goto cleanup;
    fill.dst = wrapped;
    fill.value = 0x55;
    if (expect_status(mgGraphAddEventWaitNode(graph, event, 1, &wait, &error), MG_STATUS_OK,
                      "reentry wait", &error) ||
        expect_status(mgGraphAddFillNode(graph, &fill, &fillNode, &error), MG_STATUS_OK,
                      "reentry fill", &error) ||
        expect_status(mgGraphAddDependency(graph, wait, fillNode, &error), MG_STATUS_OK,
                      "reentry dependency", &error) ||
        expect_status(mgGraphInstantiate(graph, device, &exec, &error), MG_STATUS_OK,
                      "reentry exec", &error))
        goto cleanup;
    mgGraphDestroy(graph);
    graph = NULL;
    mgBufferDestroy(wrapped);
    wrapped = NULL;
    if (expect_status(mgGraphLaunch(exec, stream, &launch, &error), MG_STATUS_OK, "reentry launch",
                      &error))
        goto cleanup;
    submitted = true;
    mgLaunchDestroy(launch);
    launch = NULL;
    mgGraphExecDestroy(exec);
    exec = NULL;
    if (__atomic_load_n(&owner.releases, __ATOMIC_ACQUIRE) != 0 ||
        !signal_independent_event(producer, nativeEvent, 1))
        goto cleanup;
    {
        struct timespec start, now;
        clock_gettime(CLOCK_MONOTONIC, &start);
        while (!__atomic_load_n(&owner.done, __ATOMIC_ACQUIRE)) {
            usleep(1000);
            clock_gettime(CLOCK_MONOTONIC, &now);
            if (now.tv_sec - start.tv_sec >= 5) {
                fprintf(stderr, "owner callback reentry timed out\n");
                _Exit(11);
            }
        }
    }
    if (__atomic_load_n(&owner.retains, __ATOMIC_ACQUIRE) != 1 ||
        __atomic_load_n(&owner.releases, __ATOMIC_ACQUIRE) != 1 ||
        __atomic_load_n(&owner.status, __ATOMIC_ACQUIRE) != MG_STATUS_OK ||
        ((uint8_t *)mgBufferContents(nextBuffer))[0] != 0x66)
        goto cleanup;
    rc = 0;
cleanup:
    if (submitted && nativeEvent && nativeEvent.signaledValue < 1 &&
        !signal_independent_event(producer, nativeEvent, 1))
        _Exit(12);
    if (launch && !launch->completed)
        wait_for_raw_completion(launch);
    mgLaunchDestroy(launch);
    mgGraphExecDestroy(exec);
    mgGraphDestroy(graph);
    mgBufferDestroy(wrapped);
    mgGraphExecDestroy(nextExec);
    mgGraphDestroy(nextGraph);
    mgBufferDestroy(nextBuffer);
    mgEventDestroy(event);
    mgStreamDestroy(stream);
    mgErrorDestroy(error);
    if (rc)
        fprintf(stderr, "owner callback reentry failed\n");
    return rc;
}

static int test_native_deallocator_reentry(mg_device_t *device, id<MTLDevice> metal) {
    mg_error_t *error = NULL;
    mg_stream_t *stream = NULL;
    mg_event_t *event = NULL;
    mg_buffer_t *wrapped = NULL, *nextBuffer = NULL;
    mg_graph_t *graph = NULL, *nextGraph = NULL;
    mg_graph_exec_t *exec = NULL, *nextExec = NULL;
    mg_launch_t *launch = NULL;
    mg_node_t *wait = NULL, *fillNode = NULL;
    mg_fill_desc_t fill = {};
    reentry_owner_t owner = {};
    id<MTLCommandQueue> producer = [metal newCommandQueue];
    if (!producer || mgStreamCreate(device, &stream, &error) != MG_STATUS_OK ||
        mgEventCreate(device, &event, &error) != MG_STATUS_OK ||
        mgBufferCreateShared(device, 16, &nextBuffer, &error) != MG_STATUS_OK ||
        mgGraphCreate(&nextGraph, &error) != MG_STATUS_OK)
        _Exit(31);
    fill.size = sizeof(fill);
    fill.dst = nextBuffer;
    fill.byte_count = 16;
    fill.value = 0x67;
    if (mgGraphAddFillNode(nextGraph, &fill, &fillNode, &error) != MG_STATUS_OK ||
        mgGraphInstantiate(nextGraph, device, &nextExec, &error) != MG_STATUS_OK)
        _Exit(32);
    owner.stream = stream;
    owner.next = nextExec;
    void *bytes = NULL;
    size_t length = (size_t)getpagesize();
    if (posix_memalign(&bytes, length, length) != 0)
        _Exit(33);
    reentry_owner_t *ownerPtr = &owner;
    __weak id<MTLBuffer> weakNative = nil;
    id<MTLSharedEvent> nativeEvent = nil;
    @autoreleasepool {
        id<MTLBuffer> native = [metal newBufferWithBytesNoCopy:bytes
                                                        length:length
                                                       options:MTLResourceStorageModeShared
                                                   deallocator:^(void *p, NSUInteger size) {
                                                     (void)size;
                                                     free(p);
                                                     reentry_release(ownerPtr);
                                                   }];
        if (!native)
            _Exit(34);
        weakNative = native;
        mg_metal_buffer_wrap_desc_t wd = wrap_desc(
            native, length, MG_METAL_BUFFER_ACCESS_READ_WRITE, MG_METAL_BUFFER_WRAP_MUTABLE);
        if (mgMetalBufferWrap(device, &wd, &wrapped, &error) != MG_STATUS_OK ||
            mgGraphCreate(&graph, &error) != MG_STATUS_OK)
            _Exit(35);
        fill.dst = wrapped;
        fill.value = 0x55;
        if (mgGraphAddEventWaitNode(graph, event, 1, &wait, &error) != MG_STATUS_OK ||
            mgGraphAddFillNode(graph, &fill, &fillNode, &error) != MG_STATUS_OK ||
            mgGraphAddDependency(graph, wait, fillNode, &error) != MG_STATUS_OK ||
            mgGraphInstantiate(graph, device, &exec, &error) != MG_STATUS_OK)
            _Exit(36);
        nativeEvent = (__bridge id<MTLSharedEvent>)event->impl;
        mgGraphDestroy(graph);
        mgBufferDestroy(wrapped);
        if (mgGraphLaunch(exec, stream, &launch, &error) != MG_STATUS_OK)
            _Exit(37);
        mgLaunchDestroy(launch);
        mgGraphExecDestroy(exec);
        native = nil;
    }
    if (__atomic_load_n(&owner.done, __ATOMIC_ACQUIRE) ||
        !signal_independent_event(producer, nativeEvent, 1))
        _Exit(38);
    for (unsigned i = 0; i < 5000 && !__atomic_load_n(&owner.done, __ATOMIC_ACQUIRE); ++i)
        usleep(1000);
    if (!__atomic_load_n(&owner.done, __ATOMIC_ACQUIRE) || owner.status != MG_STATUS_OK ||
        owner.releases != 1 || ((uint8_t *)mgBufferContents(nextBuffer))[0] != 0x67) {
        fprintf(stderr, "native deallocator pending=%d weak=%d status=%d releases=%d\n",
                !owner.done, weakNative != nil, owner.status, owner.releases);
        _Exit(39);
    }
    mgGraphExecDestroy(nextExec);
    mgGraphDestroy(nextGraph);
    mgBufferDestroy(nextBuffer);
    mgEventDestroy(event);
    mgStreamDestroy(stream);
    mgErrorDestroy(error);
    fprintf(stderr, "native bytes-no-copy final deallocator same-stream reentry passed\n");
    return 0;
}

int main(void) {
    @autoreleasepool {
        int rc = 1;
        mg_error_t *error = NULL;
        mg_device_t *device = NULL;
        mg_stream_t *stream = NULL;
        mg_event_t *event = NULL;
        id<MTLDevice> metalDevice = nil;
        id<MTLCommandQueue> externalQueue = nil;

        mg_status_t status = mgDeviceCreateSystemDefault(&device, &error);
        if (status == MG_STATUS_UNSUPPORTED) {
            fprintf(stderr, "skipping: no system default Metal device\n");
            mgErrorDestroy(error);
            return 77;
        }
        if (expect_status(status, MG_STATUS_OK, "create device", &error) ||
            expect_status(mgStreamCreate(device, &stream, &error), MG_STATUS_OK, "create stream",
                          &error) ||
            expect_status(mgEventCreate(device, &event, &error), MG_STATUS_OK, "create event",
                          &error)) {
            goto cleanup;
        }

        metalDevice = (__bridge id<MTLDevice>)device->impl;
        fprintf(stderr, "Metal device: %s\n", [[metalDevice name] UTF8String]);
        status = mgLaunchSynchronize(NULL, &error);
        if (status != MG_STATUS_INVALID_ARGUMENT || !error ||
            mgErrorStage(error) != MG_ERROR_STAGE_SYNC ||
            mgErrorStatus(error) != MG_STATUS_INVALID_ARGUMENT) {
            fprintf(stderr, "null launch did not return a structured sync error\n");
            goto cleanup;
        }
        mgErrorDestroy(error);
        error = NULL;
        {
            mg_launch_t incomplete = {};
            status = mgLaunchSynchronize(&incomplete, &error);
            if (status != MG_STATUS_INVALID_ARGUMENT || !error ||
                mgErrorStage(error) != MG_ERROR_STAGE_SYNC || incomplete.completed ||
                incomplete.synchronize_count || incomplete.sync_mode_flags) {
                fprintf(stderr, "incomplete launch did not return a structured sync error\n");
                goto cleanup;
            }
            mgErrorDestroy(error);
            error = NULL;
        }
        if (test_owner_callback_reentry(device, metalDevice))
            goto cleanup;
        fprintf(stderr, "same-stream owner callback reentry passed\n");
        if (test_native_deallocator_reentry(device, metalDevice))
            goto cleanup;
        if (test_synthetic_error_callback(device))
            goto cleanup;
        fprintf(stderr,
                "synthetic terminal Error acknowledgement and repeated error reporting passed\n");
        if (test_old_handle_new_held(device, stream, metalDevice) ||
            test_running_destroy_or_partial(device, stream, metalDevice, 0) ||
            test_running_destroy_or_partial(device, stream, metalDevice, 1) ||
            test_running_destroy_or_partial(device, stream, metalDevice, 2) ||
            test_running_destroy_or_partial(device, stream, metalDevice, 3) ||
            test_running_destroy_or_partial(device, stream, metalDevice, 4) ||
            test_running_destroy_or_partial(device, stream, metalDevice, 5) ||
            test_running_destroy_or_partial(device, stream, metalDevice, 6) ||
            test_running_destroy_or_partial(device, stream, metalDevice, 7))
            goto cleanup;
        fprintf(stderr, "in-flight destruction and post-commit recovery tests passed\n");
        if (test_synthetic_completion_policy() ||
            test_failed_instantiation_owner(device, metalDevice) ||
            test_zero_destroy_and_preflight(device, stream) ||
            test_completed_raw_destroy(device, stream, metalDevice, 0) ||
            test_completed_raw_destroy(device, stream, metalDevice, 1) ||
            test_completed_raw_destroy(device, stream, metalDevice, 2) ||
            test_completed_raw_destroy(device, stream, metalDevice, 4))
            goto cleanup;
        fprintf(stderr, "raw completed-destroy and owner-lifetime tests passed\n");
        if (test_no_work_completion(device, stream, false) ||
            test_no_work_completion(device, stream, true))
            goto cleanup;
        fprintf(stderr, "empty and barrier-only launch completion tests passed\n");
        externalQueue = [metalDevice newCommandQueue];
        if (!externalQueue) {
            fprintf(stderr, "failed to create external command queue\n");
            goto cleanup;
        }

        if (test_external_write_explicit_sync_then_mg_read(device, stream, metalDevice,
                                                           externalQueue) ||
            test_mg_write_explicit_sync_then_external_read(device, stream, metalDevice, event) ||
            test_external_event_orders_mg_read(device, stream, metalDevice, externalQueue, event)) {
            goto cleanup;
        }
        fprintf(stderr, "real-work synchronization conformance tests passed\n");
        rc = 0;

    cleanup:
        mgEventDestroy(event);
        mgStreamDestroy(stream);
        mgDeviceDestroy(device);
        mgErrorDestroy(error);
        return rc;
    }
}
