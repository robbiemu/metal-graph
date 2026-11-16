#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include "metal_graph/metal_graph.h"
#include "metal_graph/metal_graph_metal.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void check(mg_status_t status, mg_error_t **error) {
    if (status != MG_STATUS_OK) {
        fprintf(stderr, "%s\n", *error ? mgErrorMessage(*error) : mgStatusString(status));
        exit(1);
    }
    mgErrorDestroy(*error);
    *error = NULL;
}

// No MLX, private runtime headers, offline shaders, or external packages are needed.
int main(void) {
    @autoreleasepool {
        id<MTLDevice> metal = MTLCreateSystemDefaultDevice();
        if (!metal)
            return 77;
        id<MTLCommandQueue> producerQueue = [metal newCommandQueue];
        id<MTLCommandQueue> consumerQueue = [metal newCommandQueue];
        id<MTLSharedEvent> ready = [metal newSharedEvent];
        id<MTLBuffer> source = [metal newBufferWithLength:32 options:MTLResourceStorageModeShared];
        id<MTLBuffer> staging = [metal newBufferWithLength:32
                                                   options:MTLResourceStorageModeShared |
                                                           MTLResourceHazardTrackingModeUntracked];
        id<MTLBuffer> result = [metal newBufferWithLength:32 options:MTLResourceStorageModeShared];
        if (!producerQueue || !consumerQueue || !ready || !source || !staging || !result)
            return 1;
        memset(source.contents, 0, 32);
        memset(result.contents, 0, 32);

        mg_error_t *error = NULL;
        mg_device_t *device = NULL;
        mg_stream_t *stream = NULL;
        mg_buffer_t *input = NULL, *intermediate = NULL, *output = NULL;
        mg_event_t *readyEvent = NULL, *doneEvent = NULL;
        mg_graph_t *graph = NULL;
        mg_graph_exec_t *exec = NULL;
        mg_launch_t *launch = NULL;
        mg_node_t *wait = NULL, *copy = NULL, *copyOut = NULL, *signal = NULL;
        check(mgDeviceCreateSystemDefault(&device, &error), &error);
        check(mgStreamCreate(device, &stream, &error), &error);
        mg_metal_buffer_wrap_desc_t wrap = {};
        wrap.size = sizeof(wrap);
        wrap.buffer = source;
        wrap.byte_length = 32;
        wrap.access = MG_METAL_BUFFER_ACCESS_READ;
        wrap.flags = MG_METAL_BUFFER_WRAP_RETAIN_BUFFER;
        check(mgMetalBufferWrap(device, &wrap, &input, &error), &error);
        wrap.buffer = result;
        wrap.access = MG_METAL_BUFFER_ACCESS_WRITE;
        wrap.flags |= MG_METAL_BUFFER_WRAP_MUTABLE;
        check(mgMetalBufferWrap(device, &wrap, &output, &error), &error);
        wrap.buffer = staging;
        wrap.access = MG_METAL_BUFFER_ACCESS_READ_WRITE;
        check(mgMetalBufferWrap(device, &wrap, &intermediate, &error), &error);
        check(mgMetalEventWrap(device, ready, &readyEvent, &error), &error);
        check(mgEventCreate(device, &doneEvent, &error), &error);
        __unsafe_unretained id<MTLSharedEvent> borrowed = nil;
        check(mgMetalEventGetSharedEvent(doneEvent, &borrowed, &error), &error);
        id<MTLSharedEvent> done = borrowed; // Explicit strong ownership beyond the MG handle.

        check(mgGraphCreate(&graph, &error), &error);
        check(mgGraphAddEventWaitNode(graph, readyEvent, 1, &wait, &error), &error);
        mg_copy_desc_t copyDesc = {};
        copyDesc.size = sizeof(copyDesc);
        copyDesc.src = input;
        copyDesc.dst = intermediate;
        copyDesc.byte_count = 32;
        check(mgGraphAddCopyNode(graph, &copyDesc, &copy, &error), &error);
        copyDesc.src = intermediate;
        copyDesc.dst = output;
        check(mgGraphAddCopyNode(graph, &copyDesc, &copyOut, &error), &error);
        check(mgGraphAddEventSignalNode(graph, doneEvent, 1, &signal, &error), &error);
        check(mgGraphAddDependency(graph, wait, copy, &error), &error);
        // The runtime supplies the fence between these untracked blit passes.
        check(mgGraphAddDependency(graph, copy, copyOut, &error), &error);
        check(mgGraphAddDependency(graph, copyOut, signal, &error), &error);
        check(mgGraphInstantiate(graph, device, &exec, &error), &error);
        mgGraphDestroy(graph);
        mgBufferDestroy(input);
        mgBufferDestroy(intermediate);
        mgBufferDestroy(output);
        mgEventDestroy(readyEvent);
        mgEventDestroy(doneEvent);

        // Both consumers are submitted before the independent producer signals.
        id<MTLCommandBuffer> consumer = [consumerQueue commandBuffer];
        [consumer encodeWaitForEvent:done value:1];
        [consumer commit];
        check(mgGraphLaunch(exec, stream, &launch, &error), &error);
        mgGraphExecDestroy(exec);
        mgStreamDestroy(stream); // Accepted work retains its executable and queue.
        mg_launch_diagnostics_t diagnostics = {};
        diagnostics.size = sizeof(diagnostics);
        check(mgLaunchGetDiagnostics(launch, &diagnostics, &error), &error);
        if (diagnostics.completed || diagnostics.synchronize_count != 0 ||
            diagnostics.event_wait_count != 1 || diagnostics.event_signal_count != 1)
            return 1;

        id<MTLCommandBuffer> producer = [producerQueue commandBuffer];
        id<MTLBlitCommandEncoder> blit = [producer blitCommandEncoder];
        if (!producer || !consumer || !blit)
            return 1;
        [blit fillBuffer:source range:NSMakeRange(0, 32) value:0x5A];
        [blit endEncoding];
        [producer encodeSignalEvent:ready value:1];
        [producer commit];
        check(mgLaunchSynchronize(launch, &error), &error);
        [consumer waitUntilCompleted]; // Explicit foreign-consumer completion.
        if (consumer.status != MTLCommandBufferStatusCompleted)
            return 1;
        check(mgLaunchGetDiagnostics(launch, &diagnostics, &error), &error);
        if (!diagnostics.completed || diagnostics.synchronize_count != 1)
            return 1;
        for (size_t i = 0; i < 32; ++i) {
            if (((const unsigned char *)result.contents)[i] != 0x5A)
                return 1;
        }
        mgLaunchDestroy(launch);
        mgDeviceDestroy(device);
        puts("Native producer -> Metal Graph -> native consumer passed.");
        return 0;
    }
}
