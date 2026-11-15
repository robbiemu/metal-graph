#include "metal_graph/metal_graph.h"
#include "metal_graph/metal_graph_metal.h"

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <dispatch/dispatch.h>
#import <objc/runtime.h>

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* All runtime access in this file uses public headers and the new event bridge. */
static void require(bool condition, const char *message) {
    if (!condition) { fprintf(stderr, "event bridge test failed: %s\n", message); _Exit(1); }
}
static void expect(mg_status_t actual, mg_status_t wanted, mg_error_t **error, const char *call) {
    if (actual != wanted || (wanted != MG_STATUS_OK &&
        (!*error || mgErrorStatus(*error) != wanted || mgErrorStage(*error) != MG_ERROR_STAGE_CREATE))) {
        fprintf(stderr, "%s: got %s, expected %s; stage=%d message=%s\n", call,
                mgStatusString(actual), mgStatusString(wanted), *error ? mgErrorStage(*error) : 0,
                *error ? mgErrorMessage(*error) : "no error"); _Exit(1);
    }
    mgErrorDestroy(*error); *error = NULL;
}
#define API(call) expect((call), MG_STATUS_OK, &error, #call)
#define INVALID(call) expect((call), MG_STATUS_INVALID_ARGUMENT, &error, #call)
static void wait_done(dispatch_semaphore_t done, const char *message) {
    require(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0,
            message);
}
static const char completionSemaphoreKey = 0;
static dispatch_semaphore_t completion(id<MTLCommandBuffer> command) {
    require(command != nil, "native command allocation");
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    @synchronized (command) {
        objc_setAssociatedObject(command, &completionSemaphoreKey, done, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [command addCompletedHandler:^(id<MTLCommandBuffer> completed) {
            dispatch_semaphore_t ready = nil;
            @synchronized (completed) {
                ready = objc_getAssociatedObject(completed, &completionSemaphoreKey);
                objc_setAssociatedObject(completed, &completionSemaphoreKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            dispatch_semaphore_signal(ready);
        }];
    }
    return done;
}
static void sync_bounded(mg_launch_t *launch) {
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block mg_status_t status = MG_STATUS_INTERNAL_ERROR;
    __block mg_error_t *error = NULL;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        status = mgLaunchSynchronize(launch, &error); dispatch_semaphore_signal(done);
    });
    wait_done(done, "explicit MG synchronization deadline");
    expect(status, MG_STATUS_OK, &error, "bounded mgLaunchSynchronize");
}
static mg_launch_t *launch_bounded(mg_graph_exec_t *exec, mg_stream_t *stream) {
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block mg_launch_t *launch = NULL;
    __block mg_status_t status = MG_STATUS_INTERNAL_ERROR;
    __block mg_error_t *error = NULL;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        status = mgGraphLaunch(exec, stream, &launch, &error); dispatch_semaphore_signal(done);
    });
    wait_done(done, "MG launch deadline");
    expect(status, MG_STATUS_OK, &error, "bounded mgGraphLaunch");
    return launch;
}
static mg_metal_buffer_wrap_desc_t buffer_desc(id<MTLBuffer> buffer) {
    mg_metal_buffer_wrap_desc_t d = {};
    d.size = sizeof(d); d.buffer = buffer; d.byte_length = 64;
    d.access = MG_METAL_BUFFER_ACCESS_READ_WRITE;
    d.flags = MG_METAL_BUFFER_WRAP_RETAIN_BUFFER | MG_METAL_BUFFER_WRAP_HOST_VISIBLE |
              MG_METAL_BUFFER_WRAP_MUTABLE;
    return d;
}
static void check_bytes(const uint8_t *bytes, size_t offset, size_t count, uint8_t value,
                         uint8_t guard, const char *message) {
    for (size_t i = 0; i < 64; ++i)
        require(bytes[i] == (i >= offset && i < offset + count ? value : guard), message);
}
static void diagnostics(mg_launch_t *launch, bool wait, bool completed) {
    mg_error_t *error = NULL;
    mg_launch_diagnostics_t d = {}; d.size = sizeof(d);
    API(mgLaunchGetDiagnostics(launch, &d, &error));
    require(d.event_wait_count == (wait ? 1u : 0u) && d.event_signal_count == (wait ? 0u : 1u),
            "event diagnostic counts");
    uint32_t flags = wait ? MG_SYNC_MODE_EVENT_WAIT : MG_SYNC_MODE_EVENT_SIGNAL;
    if (completed) flags |= MG_SYNC_MODE_LAUNCH_SYNCHRONIZE;
    require(d.sync_mode_flags == flags && d.synchronize_count == (completed ? 1u : 0u) &&
            d.completed == (completed ? 1u : 0u), "explicit synchronization diagnostics");
}
/* Only the non-nil device-conflict branch is synthetic; native shared events are device-neutral. */
@interface MGDeviceBoundEventFixture : NSObject <MTLSharedEvent>
@property(nonatomic, strong) id<MTLSharedEvent> event;
@property(nonatomic, strong) id<MTLDevice> device;
@property(atomic, copy) NSString *label;
@property(atomic) uint64_t signaledValue;
@end
@implementation MGDeviceBoundEventFixture
- (void)notifyListener:(MTLSharedEventListener *)listener atValue:(uint64_t)value block:(MTLSharedEventNotificationBlock)block {
    [self.event notifyListener:listener atValue:value block:block];
}
- (MTLSharedEventHandle *)newSharedEventHandle { return [self.event newSharedEventHandle]; }
- (BOOL)waitUntilSignaledValue:(uint64_t)value timeoutMS:(uint64_t)timeout {
    return [self.event waitUntilSignaledValue:value timeoutMS:timeout];
}
@end
static void invalid_inputs(mg_device_t *device, id<MTLDevice> metal) {
    mg_error_t *error = NULL;
    mg_event_t *out = (mg_event_t *)(uintptr_t)1;
    id<MTLSharedEvent> native = [metal newSharedEvent];
    require(native != nil, "allocate invalid-input fixture event");
    INVALID(mgMetalEventWrap(NULL, native, &out, &error)); require(!out, "NULL device clears output");
    out = (mg_event_t *)(uintptr_t)1;
    INVALID(mgMetalEventWrap(device, nil, &out, &error)); require(!out, "nil event clears output");
    INVALID(mgMetalEventWrap(device, native, NULL, &error));
    out = (mg_event_t *)(uintptr_t)1;
    NSObject *foreign = [NSObject new];
    INVALID(mgMetalEventWrap(device, (id<MTLSharedEvent>)foreign, &out, &error));
    require(!out, "foreign protocol clears output");
    id<MTLEvent> ordinary = [metal newEvent];
    if (ordinary) {
        out = (mg_event_t *)(uintptr_t)1;
        INVALID(mgMetalEventWrap(device, (id<MTLSharedEvent>)ordinary, &out, &error));
        require(!out, "non-shared Metal event rejected");
    }
    API(mgMetalEventWrap(device, native, &out, &error));
    __unsafe_unretained id<MTLSharedEvent> borrowed = native;
    INVALID(mgMetalEventGetSharedEvent(NULL, &borrowed, &error)); require(!borrowed, "NULL getter clears output");
    INVALID(mgMetalEventGetSharedEvent(out, NULL, &error));
    API(mgMetalEventGetSharedEvent(out, &borrowed, &error)); require(borrowed == native, "native event identity");
    mgEventDestroy(out);
    MGDeviceBoundEventFixture *bound = [MGDeviceBoundEventFixture new]; bound.event = native;
    bound.device = (id<MTLDevice>)[NSObject new]; out = (mg_event_t *)(uintptr_t)1;
    INVALID(mgMetalEventWrap(device, bound, &out, &error)); require(!out, "synthetic conflicting nonnil device rejected");
    bool otherFound = false;
    for (id<MTLDevice> other in MTLCopyAllDevices()) {
        if (other == metal) continue;
        id<MTLSharedEvent> otherEvent = [other newSharedEvent];
        require(otherEvent != nil, "other-device event allocation");
        out = (mg_event_t *)(uintptr_t)1;
        if (otherEvent.device && otherEvent.device != metal) {
            INVALID(mgMetalEventWrap(device, otherEvent, &out, &error)); require(!out, "device mismatch clears output");
        } else {
            API(mgMetalEventWrap(device, otherEvent, &out, &error)); mgEventDestroy(out);
        }
        otherFound = true; break;
    }
    if (!otherFound) fprintf(stderr, "skipping real cross-device shared-event compatibility: one Metal device; nonnil mismatch branch is synthetic\n");
}
static void lifetime_and_zero(mg_device_t *device, mg_stream_t *stream, id<MTLDevice> metal) {
    __weak id<MTLSharedEvent> weak = nil;
    @autoreleasepool {
        mg_error_t *error = NULL;
        id<MTLSharedEvent> native = [metal newSharedEvent]; weak = native;
        mg_event_t *first = NULL, *second = NULL;
        API(mgMetalEventWrap(device, native, &first, &error));
        API(mgMetalEventWrap(device, native, &second, &error));
        __unsafe_unretained id<MTLSharedEvent> a = nil, b = nil;
        API(mgMetalEventGetSharedEvent(first, &a, &error)); API(mgMetalEventGetSharedEvent(second, &b, &error));
        require(a == native && b == native && a.signaledValue == 0, "duplicate wrap identity/initial timeline");
        native = nil; require(weak != nil, "native retained by wrappers");
        mgEventDestroy(first); require(weak != nil, "duplicate retains independently");
        mg_graph_t *graph = NULL; mg_graph_exec_t *exec = NULL; mg_node_t *wait = NULL;
        API(mgGraphCreate(&graph, &error));
        API(mgGraphAddEventWaitNode(graph, second, 0, &wait, &error));
        mgEventDestroy(second); second = NULL;
        API(mgGraphInstantiate(graph, device, &exec, &error)); mgGraphDestroy(graph);
        mg_launch_t *launch = launch_bounded(exec, stream); sync_bounded(launch);
        diagnostics(launch, true, true);
        mgGraphExecDestroy(exec);
        require(weak != nil, "launch retains event after source graph/public handles/exec destruction");
        mgLaunchDestroy(launch);
    }
    for (unsigned i = 0; i < 2000 && weak != nil; ++i) {
        @autoreleasepool { usleep(1000); }
    }
    require(weak == nil, "native event released after last runtime reference");
    /* Explicit foreign strong ownership outlives the exported wrapper (+0 result). */
    __weak id<MTLSharedEvent> createdWeak = nil;
    @autoreleasepool {
        mg_error_t *error = NULL; mg_event_t *event = NULL;
        API(mgEventCreate(device, &event, &error));
        __unsafe_unretained id<MTLSharedEvent> borrowed = nil;
        API(mgMetalEventGetSharedEvent(event, &borrowed, &error));
        id<MTLSharedEvent> retained = borrowed; createdWeak = retained;
        mgEventDestroy(event);
        require(retained != nil && retained.signaledValue == 0, "explicit foreign retain after wrapper destruction");
        retained = nil;
    }
    require(createdWeak == nil, "borrowed export does not leak native event");
}
static void external_producer_to_mg_wait(mg_device_t *device, mg_stream_t *stream, id<MTLDevice> metal) {
    mg_error_t *error = NULL;
    id<MTLCommandQueue> producerQueue = [metal newCommandQueue];
    id<MTLBuffer> source = [metal newBufferWithLength:64 options:MTLResourceStorageModeShared];
    id<MTLSharedEvent> native = [metal newSharedEvent];
    require(producerQueue && source && native, "external producer resources");
    mg_event_t *event = NULL; mg_buffer_t *wrapped = NULL, *destination = NULL;
    API(mgMetalEventWrap(device, native, &event, &error));
    __unsafe_unretained id<MTLSharedEvent> borrowed = nil;
    API(mgMetalEventGetSharedEvent(event, &borrowed, &error)); require(borrowed == native, "import/export identity");
    native = nil;
    mg_metal_buffer_wrap_desc_t wrap = buffer_desc(source);
    API(mgMetalBufferWrap(device, &wrap, &wrapped, &error));
    API(mgBufferCreateShared(device, 64, &destination, &error));
    mg_graph_t *graph = NULL; mg_graph_exec_t *exec = NULL; mg_node_t *wait = NULL, *copy = NULL;
    mg_copy_desc_t desc = {}; desc.size = sizeof(desc); desc.src = wrapped; desc.src_offset = 12;
    desc.dst = destination; desc.dst_offset = 20; desc.byte_count = 16;
    API(mgGraphCreate(&graph, &error)); API(mgGraphAddEventWaitNode(graph, event, 1, &wait, &error));
    API(mgGraphSetNodePatchFlags(graph, wait, MG_PATCH_EVENT_VALUE, &error));
    API(mgGraphAddCopyNode(graph, &desc, &copy, &error)); API(mgGraphAddDependency(graph, wait, copy, &error));
    mg_node_id_t waitId = mgNodeId(wait);
    API(mgGraphInstantiate(graph, device, &exec, &error));
    mgGraphDestroy(graph); mgEventDestroy(event); mgBufferDestroy(wrapped);
    for (uint64_t target = 1; target <= 2; ++target) {
        if (target > 1) API(mgGraphExecPatchEventValue(exec, waitId, target, &error));
        memset(source.contents, 0xa5, 64); memset(mgBufferContents(destination), 0xc3, 64);
        require(borrowed.signaledValue == target - 1, "import timeline preserved and unsatisfied");
        id<MTLCommandBuffer> producer = [producerQueue commandBuffer];
        id<MTLBlitCommandEncoder> blit = [producer blitCommandEncoder]; require(blit != nil, "producer encoder");
        [blit fillBuffer:source range:NSMakeRange(12, 16) value:(uint8_t)(0x60 + target)]; [blit endEncoding];
        [producer encodeSignalEvent:borrowed value:target];
        dispatch_semaphore_t producerDone = completion(producer);
        dispatch_semaphore_t returned = dispatch_semaphore_create(0);
        __block mg_launch_t *launch = NULL; __block mg_error_t *launchError = NULL;
        __block mg_status_t launchStatus = MG_STATUS_INTERNAL_ERROR;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            launchStatus = mgGraphLaunch(exec, stream, &launch, &launchError); dispatch_semaphore_signal(returned);
        });
        bool beforeProducer = dispatch_semaphore_wait(returned, dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC)) == 0;
        bool unsatisfied = borrowed.signaledValue < target;
        if (beforeProducer && launchStatus == MG_STATUS_OK) diagnostics(launch, true, false);
        /* Normal GPU producer release occurs even if a regression blocked launch on the host. */
        [producer commit];
        if (!beforeProducer) wait_done(returned, "launch return after independent producer");
        wait_done(producerDone, "independent producer completion");
        require(beforeProducer && unsatisfied, "MG waiter submitted before unsignaled independent producer");
        expect(launchStatus, MG_STATUS_OK, &launchError, "waiter-first mgGraphLaunch");
        require(producer.status == MTLCommandBufferStatusCompleted, "producer success");
        sync_bounded(launch); diagnostics(launch, true, true);
        check_bytes((const uint8_t *)source.contents, 12, 16, (uint8_t)(0x60 + target), 0xa5, "producer source guards");
        check_bytes((const uint8_t *)mgBufferContents(destination), 20, 16, (uint8_t)(0x60 + target), 0xc3, "MG consumer payload/guards");
        require(borrowed.signaledValue == target, "import monotonic signal value");
        mgLaunchDestroy(launch);
        fprintf(stderr, "public event import target=%llu waiter-first=1 unsatisfied=1 guards=1\n", (unsigned long long)target);
    }
    mgGraphExecDestroy(exec); mgBufferDestroy(destination);
}
static void mg_signal_to_external_consumer(mg_device_t *device, mg_stream_t *stream, id<MTLDevice> metal) {
    mg_error_t *error = NULL;
    id<MTLCommandQueue> consumerQueue = [metal newCommandQueue];
    id<MTLBuffer> source = [metal newBufferWithLength:64 options:MTLResourceStorageModeShared];
    id<MTLBuffer> destination = [metal newBufferWithLength:64 options:MTLResourceStorageModeShared];
    require(consumerQueue && source && destination, "external consumer resources");
    mg_event_t *event = NULL; mg_buffer_t *wrapped = NULL;
    API(mgEventCreate(device, &event, &error));
    __unsafe_unretained id<MTLSharedEvent> borrowed = nil;
    API(mgMetalEventGetSharedEvent(event, &borrowed, &error));
    id<MTLSharedEvent> retained = borrowed;
    mg_metal_buffer_wrap_desc_t wrap = buffer_desc(source); API(mgMetalBufferWrap(device, &wrap, &wrapped, &error));
    mg_graph_t *graph = NULL; mg_graph_exec_t *exec = NULL; mg_node_t *fill = NULL, *signal = NULL;
    mg_fill_desc_t desc = {}; desc.size = sizeof(desc); desc.dst = wrapped;
    desc.dst_offset = 12; desc.byte_count = 16; desc.value = 0x7e;
    API(mgGraphCreate(&graph, &error)); API(mgGraphAddFillNode(graph, &desc, &fill, &error));
    API(mgGraphAddEventSignalNode(graph, event, 1, &signal, &error));
    API(mgGraphSetNodePatchFlags(graph, signal, MG_PATCH_EVENT_VALUE, &error));
    API(mgGraphAddDependency(graph, fill, signal, &error));
    mg_node_id_t signalId = mgNodeId(signal);
    API(mgGraphInstantiate(graph, device, &exec, &error));
    mgGraphDestroy(graph); mgEventDestroy(event); mgBufferDestroy(wrapped);
    for (uint64_t target = 1; target <= 2; ++target) {
        if (target > 1) API(mgGraphExecPatchEventValue(exec, signalId, target, &error));
        memset(source.contents, 0xa5, 64); memset(destination.contents, 0xd2, 64);
        id<MTLCommandBuffer> consumer = [consumerQueue commandBuffer];
        require(consumer != nil && retained.signaledValue == target - 1, "export timeline unsatisfied before consumer submit");
        [consumer encodeWaitForEvent:retained value:target];
        id<MTLBlitCommandEncoder> blit = [consumer blitCommandEncoder]; require(blit != nil, "consumer encoder");
        [blit copyFromBuffer:source sourceOffset:12 toBuffer:destination destinationOffset:24 size:16]; [blit endEncoding];
        dispatch_semaphore_t consumerDone = completion(consumer);
        bool unsatisfied = retained.signaledValue < target;
        [consumer commit];
        require(unsatisfied && retained.signaledValue < target, "external waiter committed before MG producer");
        mg_launch_t *launch = launch_bounded(exec, stream); diagnostics(launch, false, false);
        wait_done(consumerDone, "external consumer completion after MG signal");
        require(consumer.status == MTLCommandBufferStatusCompleted, "consumer success");
        sync_bounded(launch); diagnostics(launch, false, true);
        check_bytes((const uint8_t *)source.contents, 12, 16, 0x7e, 0xa5, "MG producer guards");
        check_bytes((const uint8_t *)destination.contents, 24, 16, 0x7e, 0xd2, "external consumer payload/guards");
        require(retained.signaledValue == target, "export monotonic signal value");
        mgLaunchDestroy(launch);
        fprintf(stderr, "public event export target=%llu waiter-first=1 unsatisfied=1 guards=1\n", (unsigned long long)target);
    }
    mgGraphExecDestroy(exec);
    require(retained.signaledValue == 2, "foreign strong reference beyond wrapper/graph/exec/launch lifetime");
    mg_event_t *rewrapped = NULL; API(mgMetalEventWrap(device, retained, &rewrapped, &error));
    API(mgMetalEventGetSharedEvent(rewrapped, &borrowed, &error));
    require(borrowed == retained && borrowed.signaledValue == 2, "rewrap preserves native identity/timeline");
    mgEventDestroy(rewrapped);
}
int main(void) {
    @autoreleasepool {
        mg_error_t *error = NULL; mg_device_t *device = NULL; mg_stream_t *stream = NULL;
        mg_status_t status = mgDeviceCreateSystemDefault(&device, &error);
        if (status == MG_STATUS_UNSUPPORTED) { fprintf(stderr, "skipping event bridge: no Metal device\n"); mgErrorDestroy(error); return 77; }
        expect(status, MG_STATUS_OK, &error, "default device");
        API(mgStreamCreate(device, &stream, &error));
        mg_event_t *created = NULL; API(mgEventCreate(device, &created, &error));
        __unsafe_unretained id<MTLSharedEvent> borrowed = nil;
        API(mgMetalEventGetSharedEvent(created, &borrowed, &error));
        id<MTLDevice> metal = MTLCreateSystemDefaultDevice(); mgEventDestroy(created);
        require(metal != nil, "native default device");
        fprintf(stderr, "Metal device: %s\n", metal.name.UTF8String);
        invalid_inputs(device, metal);
        lifetime_and_zero(device, stream, metal);
        external_producer_to_mg_wait(device, stream, metal);
        mg_signal_to_external_consumer(device, stream, metal);
        mgStreamDestroy(stream); mgDeviceDestroy(device);
        fprintf(stderr, "public Metal shared-event bridge tests passed\n");
        return 0;
    }
}
