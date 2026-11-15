#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <dispatch/dispatch.h>
#import <objc/runtime.h>
#include "metal_graph/metal_graph.h"
#include "metal_graph/metal_graph_metal.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static const char producerSemaphoreKey = 0;

static void check(mg_status_t status, const char *where, mg_error_t **error) {
    if (status != MG_STATUS_OK) {
        fprintf(stderr, "%s: status %d: %s\n", where, status,
                *error ? mgErrorMessage(*error) : "no message");
        exit(2);
    }
    mgErrorDestroy(*error); *error = NULL;
}

static BOOL await_value(id<MTLSharedEvent> event, uint64_t value) {
    for (unsigned i = 0; i < 5000; ++i) {
        if (event.signaledValue >= value) return YES;
        usleep(1000);
    }
    return NO;
}

int main(void) { @autoreleasepool {
    id<MTLDevice> nativeDevice = MTLCreateSystemDefaultDevice();
    if (!nativeDevice) return 77;
    mg_error_t *error = NULL; mg_device_t *device = NULL; mg_stream_t *stream = NULL;
    mg_event_t *gateEvent = NULL, *readyEvent = NULL, *doneEvent = NULL;
    mg_buffer_t *buffer = NULL; mg_graph_t *graph = NULL; mg_graph_exec_t *exec = NULL;
    mg_node_t *ready = NULL, *wait = NULL, *fill = NULL, *done = NULL; mg_launch_t *launch = NULL;
    check(mgDeviceCreateSystemDefault(&device, &error), "device", &error);
    check(mgStreamCreate(device, &stream, &error), "stream", &error);
    __weak id<MTLSharedEvent> weakGate = nil;
    @autoreleasepool {
        id<MTLSharedEvent> gate = [nativeDevice newSharedEvent];
        if (!gate) return 77;
        weakGate = gate;
        check(mgMetalEventWrap(device, gate, &gateEvent, &error), "import gate", &error);
        gate = nil;
    }
    check(mgEventCreate(device, &readyEvent, &error), "ready event", &error);
    check(mgEventCreate(device, &doneEvent, &error), "done event", &error);
    __unsafe_unretained id<MTLSharedEvent> borrowed = nil;
    check(mgMetalEventGetSharedEvent(readyEvent, &borrowed, &error), "export ready", &error);
    id<MTLSharedEvent> readyNative = borrowed;
    borrowed = nil;
    check(mgMetalEventGetSharedEvent(doneEvent, &borrowed, &error), "export done", &error);
    id<MTLSharedEvent> doneNative = borrowed;
    id<MTLBuffer> nativeBuffer = [nativeDevice newBufferWithLength:32 options:MTLResourceStorageModeShared];
    if (!nativeBuffer || !readyNative || !doneNative) return 77;
    memset(nativeBuffer.contents, 0xCC, 32);
    mg_metal_buffer_wrap_desc_t wrap = {};
    wrap.size = sizeof(wrap); wrap.buffer = nativeBuffer; wrap.byte_length = 32;
    wrap.access = MG_METAL_BUFFER_ACCESS_WRITE;
    wrap.flags = MG_METAL_BUFFER_WRAP_RETAIN_BUFFER | MG_METAL_BUFFER_WRAP_MUTABLE;
    check(mgMetalBufferWrap(device, &wrap, &buffer, &error), "wrap buffer", &error);
    check(mgGraphCreate(&graph, &error), "graph", &error);
    check(mgGraphAddEventSignalNode(graph, readyEvent, 1, &ready, &error), "ready node", &error);
    check(mgGraphAddEventWaitNode(graph, gateEvent, 1, &wait, &error), "wait node", &error);
    mg_fill_desc_t desc = {};
    desc.size = sizeof(desc); desc.dst = buffer; desc.dst_offset = 8; desc.byte_count = 16; desc.value = 0xA5;
    check(mgGraphAddFillNode(graph, &desc, &fill, &error), "fill", &error);
    check(mgGraphAddEventSignalNode(graph, doneEvent, 1, &done, &error), "done node", &error);
    check(mgGraphAddDependency(graph, ready, wait, &error), "ready before wait", &error);
    check(mgGraphAddDependency(graph, wait, fill, &error), "wait before fill", &error);
    check(mgGraphAddDependency(graph, fill, done, &error), "fill before done", &error);
    check(mgGraphInstantiate(graph, device, &exec, &error), "instantiate", &error);
    mgGraphDestroy(graph); graph = NULL;
    mgEventDestroy(gateEvent); mgEventDestroy(readyEvent); mgEventDestroy(doneEvent);
    mgBufferDestroy(buffer);
    /* The CTest worker has a 30-second process deadline, including launch admission. */
    check(mgGraphLaunch(exec, stream, &launch, &error), "launch", &error);
    if (!await_value(readyNative, 1)) { fprintf(stderr, "ready signal timeout\n"); _Exit(3); }
    if (!weakGate || weakGate.signaledValue != 0 || doneNative.signaledValue != 0) {
        fprintf(stderr, "gate or completion state unexpected before release\n"); _Exit(4);
    }
    mgGraphExecDestroy(exec); mgLaunchDestroy(launch); mgStreamDestroy(stream); mgDeviceDestroy(device);
    if (!weakGate) { fprintf(stderr, "imported event released during held launch\n"); _Exit(5); }
    @autoreleasepool {
        id<MTLSharedEvent> producerGate = weakGate;
        id<MTLCommandQueue> queue = [nativeDevice newCommandQueue];
        id<MTLCommandBuffer> command = [queue commandBuffer];
        [command encodeSignalEvent:producerGate value:1];
        dispatch_semaphore_t producerDone = dispatch_semaphore_create(0);
        @synchronized (command) {
            objc_setAssociatedObject(command, &producerSemaphoreKey, producerDone, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [command addCompletedHandler:^(id<MTLCommandBuffer> completed) {
                dispatch_semaphore_t ready = nil;
                @synchronized (completed) {
                    ready = objc_getAssociatedObject(completed, &producerSemaphoreKey);
                    objc_setAssociatedObject(completed, &producerSemaphoreKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                }
                dispatch_semaphore_signal(ready);
            }];
        }
        [command commit];
        if (dispatch_semaphore_wait(producerDone, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC))) {
            fprintf(stderr, "producer completion timeout\n"); _Exit(6);
        }
        if (command.status != MTLCommandBufferStatusCompleted) { fprintf(stderr, "producer failed\n"); _Exit(6); }
        producerGate = nil; command = nil; queue = nil;
    }
    if (!await_value(doneNative, 1)) { fprintf(stderr, "graph completion timeout\n"); _Exit(7); }
    uint8_t expected[32]; memset(expected, 0xCC, 32); memset(expected + 8, 0xA5, 16);
    if (memcmp(nativeBuffer.contents, expected, 32)) { fprintf(stderr, "payload or guards mismatch\n"); _Exit(8); }
    BOOL released = NO;
    for (unsigned i = 0; i < 5000; ++i) {
        @autoreleasepool { if (!weakGate) { released = YES; break; } }
        usleep(1000);
    }
    if (!released) { fprintf(stderr, "imported event did not release after terminal work\n"); return 9; }
    printf("{\"status\":\"passed\",\"held_gpu_prefix_observed\":true,"
           "\"imported_event_alive_after_early_destroy\":true,"
           "\"event_released_after_terminal\":true,\"exact_payload_and_guards\":true,"
           "\"independent_gpu_signal\":true,\"host_signal\":false}\n");
    return 0;
} }
