#include "metal_graph/metal_graph.h"
#include "metal_graph/metal_graph_metal.h"
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <atomic>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

struct OwnerCounts {
    std::atomic<int> retained{0};
    std::atomic<int> released{0};
};
static void owner_retain(void *p) { static_cast<OwnerCounts *>(p)->retained.fetch_add(1); }
static void owner_release(void *p) { static_cast<OwnerCounts *>(p)->released.fetch_add(1); }
static void check(mg_status_t status, const char *where, mg_error_t **error) {
    if (status != MG_STATUS_OK) {
        fprintf(stderr, "%s: status %d: %s\n", where, status,
                *error ? mgErrorMessage(*error) : "no message");
        _Exit(2);
    }
    mgErrorDestroy(*error);
    *error = NULL;
}

int main(void) {
    @autoreleasepool {
        id<MTLDevice> metal = MTLCreateSystemDefaultDevice();
        if (!metal)
            return 77;
        id<MTLBuffer> native = [metal newBufferWithLength:32 options:MTLResourceStorageModeShared];
        if (!native)
            return 77;
        memset(native.contents, 0xCC, 32);
        OwnerCounts owner;
        mg_device_t *device = NULL;
        mg_stream_t *firstStream = NULL, *secondStream = NULL;
        mg_buffer_t *firstBuffer = NULL, *secondBuffer = NULL;
        mg_event_t *event = NULL;
        mg_graph_t *firstGraph = NULL, *secondGraph = NULL;
        mg_graph_exec_t *firstExec = NULL, *secondExec = NULL;
        mg_node_t *wait = NULL, *firstFill = NULL, *secondFill = NULL;
        mg_error_t *error = NULL;
        check(mgDeviceCreateSystemDefault(&device, &error), "device", &error);
        check(mgStreamCreate(device, &firstStream, &error), "first stream", &error);
        check(mgStreamCreate(device, &secondStream, &error), "second stream", &error);
        check(mgEventCreate(device, &event, &error), "event", &error);
        __unsafe_unretained id<MTLSharedEvent> borrowed = nil;
        check(mgMetalEventGetSharedEvent(event, &borrowed, &error), "export event", &error);
        id<MTLSharedEvent> nativeEvent = borrowed;
        mg_metal_buffer_wrap_desc_t wrap = {};
        wrap.size = sizeof(wrap);
        wrap.buffer = native;
        wrap.byte_length = 32;
        wrap.access = MG_METAL_BUFFER_ACCESS_WRITE;
        wrap.flags = MG_METAL_BUFFER_WRAP_RETAIN_BUFFER | MG_METAL_BUFFER_WRAP_MUTABLE;
        check(mgMetalBufferWrap(device, &wrap, &firstBuffer, &error), "wrap first", &error);
        wrap.flags |= MG_METAL_BUFFER_WRAP_RETAIN_OWNER;
        wrap.owner_context = &owner;
        wrap.owner_retain = owner_retain;
        wrap.owner_release = owner_release;
        check(mgMetalBufferWrap(device, &wrap, &secondBuffer, &error), "wrap second", &error);
        check(mgGraphCreate(&firstGraph, &error), "first graph", &error);
        check(mgGraphCreate(&secondGraph, &error), "second graph", &error);
        check(mgGraphAddEventWaitNode(firstGraph, event, 1, &wait, &error), "wait", &error);
        mg_fill_desc_t fill = {};
        fill.size = sizeof(fill);
        fill.dst = firstBuffer;
        fill.dst_offset = 8;
        fill.byte_count = 16;
        fill.value = 0x11;
        check(mgGraphAddFillNode(firstGraph, &fill, &firstFill, &error), "first fill", &error);
        check(mgGraphAddDependency(firstGraph, wait, firstFill, &error), "wait dependency", &error);
        fill.dst = secondBuffer;
        fill.value = 0x22;
        check(mgGraphAddFillNode(secondGraph, &fill, &secondFill, &error), "second fill", &error);
        check(mgGraphInstantiate(firstGraph, device, &firstExec, &error), "first exec", &error);
        check(mgGraphInstantiate(secondGraph, device, &secondExec, &error), "second exec", &error);
        mgGraphDestroy(firstGraph);
        mgGraphDestroy(secondGraph);
        mgBufferDestroy(firstBuffer);
        mgBufferDestroy(secondBuffer);
        mg_launch_t *firstLaunch = NULL, *secondLaunch = NULL;
        check(mgGraphLaunch(firstExec, firstStream, &firstLaunch, &error), "first launch", &error);
        if (nativeEvent.signaledValue != 0)
            _Exit(3);
        mg_status_t secondStatus = mgGraphLaunch(secondExec, secondStream, &secondLaunch, &error);
        mgErrorDestroy(error);
        error = NULL;
        if (secondStatus == MG_STATUS_OK) {
            /* The first writer is still gated: finish the unexpected writer before release. */
            check(mgLaunchSynchronize(secondLaunch, &error), "unexpected second sync", &error);
            mgLaunchDestroy(secondLaunch);
        } else if (secondLaunch) {
            _Exit(4);
        }
        mgGraphExecDestroy(secondExec);
        secondExec = NULL;
        bool ownerReleasedWhileHeld = false;
        for (unsigned i = 0; i < 3000; ++i) {
            if (owner.released.load() == 1) {
                ownerReleasedWhileHeld = true;
                break;
            }
            usleep(1000);
        }
        @autoreleasepool {
            id<MTLCommandQueue> queue = [metal newCommandQueue];
            id<MTLCommandBuffer> command = [queue commandBuffer];
            [command encodeSignalEvent:nativeEvent value:1];
            [command commit];
            [command waitUntilCompleted];
            if (command.status != MTLCommandBufferStatusCompleted)
                _Exit(5);
        }
        check(mgLaunchSynchronize(firstLaunch, &error), "first sync", &error);
        uint8_t expected[32];
        memset(expected, 0xCC, 32);
        memset(expected + 8, 0x11, 16);
        bool bytesCorrect = memcmp(native.contents, expected, 32) == 0;
        mgLaunchDestroy(firstLaunch);
        mgGraphExecDestroy(firstExec);
        mgEventDestroy(event);
        mgStreamDestroy(firstStream);
        mgStreamDestroy(secondStream);
        mgDeviceDestroy(device);
        bool passed = secondStatus != MG_STATUS_OK && owner.retained.load() == 1 &&
                      ownerReleasedWhileHeld && owner.released.load() == 1 && bytesCorrect;
        printf("{\"status\":\"%s\",\"second_status\":%d,\"owner_retains\":%d,"
               "\"owner_releases\":%d,\"owner_released_while_first_held\":%s,"
               "\"exact_payload_and_guards\":%s,\"host_signal\":false}\n",
               passed ? "passed" : "failed", secondStatus, owner.retained.load(),
               owner.released.load(), ownerReleasedWhileHeld ? "true" : "false",
               bytesCorrect ? "true" : "false");
        fflush(stdout);
        if (!passed)
            _Exit(1);
        return 0;
    }
}
