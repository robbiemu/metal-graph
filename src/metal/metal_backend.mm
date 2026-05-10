#include "../core/internal.h"

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <stdlib.h>
#include <string.h>

static NSString *mg_string(const char *value) {
    return value ? [NSString stringWithUTF8String:value] : nil;
}

static const char *mg_ns_error_message(NSError *error) {
    if (!error) {
        return NULL;
    }
    return [[error localizedDescription] UTF8String];
}

static mg_status_t mg_clone_dispatch(const mg_node_t *node, mg_exec_dispatch_t *out_dispatch,
                                     mg_error_t **out_error) {
    memset(out_dispatch, 0, sizeof(*out_dispatch));
    out_dispatch->id = node->id;
    out_dispatch->metallib_path = mg_strdup(node->as.dispatch.metallib_path);
    out_dispatch->kernel_name = mg_strdup(node->as.dispatch.kernel_name);
    memcpy(out_dispatch->grid_size, node->as.dispatch.grid_size, sizeof(out_dispatch->grid_size));
    memcpy(out_dispatch->threads_per_threadgroup, node->as.dispatch.threads_per_threadgroup,
           sizeof(out_dispatch->threads_per_threadgroup));

    if (!out_dispatch->metallib_path || !out_dispatch->kernel_name) {
        return mg_set_oom(out_error, MG_ERROR_STAGE_INSTANTIATE);
    }

    if (node->as.dispatch.buffer_count > 0) {
        size_t bytes = sizeof(*out_dispatch->buffers) * node->as.dispatch.buffer_count;
        out_dispatch->buffers = (mg_buffer_binding_t *)malloc(bytes);
        if (!out_dispatch->buffers) {
            return mg_set_oom(out_error, MG_ERROR_STAGE_INSTANTIATE);
        }

        memcpy(out_dispatch->buffers, node->as.dispatch.buffers, bytes);
        out_dispatch->buffer_count = node->as.dispatch.buffer_count;
        for (uint32_t i = 0; i < out_dispatch->buffer_count; ++i) {
            mg_buffer_retain(out_dispatch->buffers[i].buffer);
        }
    }

    return MG_STATUS_OK;
}

static void mg_exec_dispatch_clear(mg_exec_dispatch_t *dispatch) {
    if (!dispatch) {
        return;
    }

    for (uint32_t i = 0; i < dispatch->buffer_count; ++i) {
        mg_buffer_release(dispatch->buffers[i].buffer);
    }

    if (dispatch->pipeline_impl) {
        id pipeline = (__bridge_transfer id)dispatch->pipeline_impl;
        (void)pipeline;
    }

    free(dispatch->metallib_path);
    free(dispatch->kernel_name);
    free(dispatch->buffers);
    memset(dispatch, 0, sizeof(*dispatch));
}

static void mg_exec_node_clear(mg_exec_node_t *node) {
    if (!node) {
        return;
    }

    switch (node->kind) {
    case MG_NODE_DISPATCH:
        mg_exec_dispatch_clear(&node->as.dispatch);
        break;
    case MG_NODE_COPY:
        mg_buffer_release(node->as.copy.src);
        mg_buffer_release(node->as.copy.dst);
        memset(&node->as.copy, 0, sizeof(node->as.copy));
        break;
    case MG_NODE_FILL:
        mg_buffer_release(node->as.fill.dst);
        memset(&node->as.fill, 0, sizeof(node->as.fill));
        break;
    case MG_NODE_EVENT_WAIT:
    case MG_NODE_EVENT_SIGNAL:
        mg_event_release(node->as.event.event);
        memset(&node->as.event, 0, sizeof(node->as.event));
        break;
    case MG_NODE_BARRIER:
        node->as.barrier_id = MG_NODE_ID_INVALID;
        break;
    }
    memset(node, 0, sizeof(*node));
}

static mg_status_t mg_clone_exec_node(const mg_node_t *src, mg_exec_node_t *dst,
                                      mg_error_t **out_error) {
    memset(dst, 0, sizeof(*dst));
    dst->kind = src->kind;

    switch (src->kind) {
    case MG_NODE_DISPATCH:
        return mg_clone_dispatch(src, &dst->as.dispatch, out_error);
    case MG_NODE_COPY:
        dst->as.copy.id = src->id;
        dst->as.copy.src = src->as.copy.src;
        dst->as.copy.src_offset = src->as.copy.src_offset;
        dst->as.copy.dst = src->as.copy.dst;
        dst->as.copy.dst_offset = src->as.copy.dst_offset;
        dst->as.copy.byte_count = src->as.copy.byte_count;
        mg_buffer_retain(dst->as.copy.src);
        mg_buffer_retain(dst->as.copy.dst);
        return MG_STATUS_OK;
    case MG_NODE_FILL:
        dst->as.fill.id = src->id;
        dst->as.fill.dst = src->as.fill.dst;
        dst->as.fill.dst_offset = src->as.fill.dst_offset;
        dst->as.fill.byte_count = src->as.fill.byte_count;
        dst->as.fill.value = src->as.fill.value;
        mg_buffer_retain(dst->as.fill.dst);
        return MG_STATUS_OK;
    case MG_NODE_EVENT_WAIT:
    case MG_NODE_EVENT_SIGNAL:
        dst->as.event.id = src->id;
        dst->as.event.event = src->as.event.event;
        dst->as.event.value = src->as.event.value;
        mg_event_retain(dst->as.event.event);
        return MG_STATUS_OK;
    case MG_NODE_BARRIER:
        dst->as.barrier_id = src->id;
        return MG_STATUS_OK;
    }

    return mg_set_error(out_error, MG_STATUS_INTERNAL_ERROR, MG_ERROR_STAGE_INSTANTIATE, src->id,
                        "unknown node kind", NULL);
}

mg_status_t mgDeviceCreateSystemDefault(mg_device_t **out_device, mg_error_t **out_error) {
    mg_clear_error(out_error);
    if (!out_device) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_CREATE,
                            MG_NODE_ID_INVALID, "out_device is required", NULL);
    }

    *out_device = NULL;
    id<MTLDevice> metalDevice = MTLCreateSystemDefaultDevice();
    if (!metalDevice) {
        return mg_set_error(out_error, MG_STATUS_UNSUPPORTED, MG_ERROR_STAGE_CREATE,
                            MG_NODE_ID_INVALID, "no system default Metal device is available",
                            NULL);
    }

    mg_device_t *device = (mg_device_t *)calloc(1, sizeof(*device));
    if (!device) {
        return mg_set_oom(out_error, MG_ERROR_STAGE_CREATE);
    }

    device->impl = (__bridge_retained void *)metalDevice;
    *out_device = device;
    return MG_STATUS_OK;
}

void mg_backend_device_destroy(mg_device_t *device) {
    if (!device || !device->impl) {
        return;
    }

    id deviceObject = (__bridge_transfer id)device->impl;
    (void)deviceObject;
    device->impl = NULL;
}

void mgDeviceDestroy(mg_device_t *device) {
    if (!device) {
        return;
    }

    mg_backend_device_destroy(device);
    free(device);
}

mg_status_t mgStreamCreate(mg_device_t *device, mg_stream_t **out_stream, mg_error_t **out_error) {
    mg_clear_error(out_error);
    if (!device || !device->impl || !out_stream) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_CREATE,
                            MG_NODE_ID_INVALID, "device and out_stream are required", NULL);
    }

    *out_stream = NULL;
    id<MTLDevice> metalDevice = (__bridge id<MTLDevice>)device->impl;
    id<MTLCommandQueue> queue = [metalDevice newCommandQueue];
    if (!queue) {
        return mg_set_error(out_error, MG_STATUS_BACKEND_ERROR, MG_ERROR_STAGE_CREATE,
                            MG_NODE_ID_INVALID, "failed to create Metal command queue", NULL);
    }

    mg_stream_t *stream = (mg_stream_t *)calloc(1, sizeof(*stream));
    if (!stream) {
        return mg_set_oom(out_error, MG_ERROR_STAGE_CREATE);
    }

    stream->impl = (__bridge_retained void *)queue;
    *out_stream = stream;
    return MG_STATUS_OK;
}

void mg_backend_stream_destroy(mg_stream_t *stream) {
    if (!stream || !stream->impl) {
        return;
    }

    id queueObject = (__bridge_transfer id)stream->impl;
    (void)queueObject;
    stream->impl = NULL;
}

void mgStreamDestroy(mg_stream_t *stream) {
    if (!stream) {
        return;
    }

    mg_backend_stream_destroy(stream);
    free(stream);
}

mg_status_t mgBufferCreateShared(mg_device_t *device, size_t length, mg_buffer_t **out_buffer,
                                 mg_error_t **out_error) {
    mg_clear_error(out_error);
    if (!device || !device->impl || !out_buffer || length == 0) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_CREATE,
                            MG_NODE_ID_INVALID,
                            "device, nonzero length, and out_buffer are required", NULL);
    }

    *out_buffer = NULL;
    id<MTLDevice> metalDevice = (__bridge id<MTLDevice>)device->impl;
    id<MTLBuffer> metalBuffer = [metalDevice newBufferWithLength:length
                                                         options:MTLResourceStorageModeShared];
    if (!metalBuffer) {
        return mg_set_error(out_error, MG_STATUS_BACKEND_ERROR, MG_ERROR_STAGE_CREATE,
                            MG_NODE_ID_INVALID, "failed to create Metal buffer", NULL);
    }

    mg_buffer_t *buffer = (mg_buffer_t *)calloc(1, sizeof(*buffer));
    if (!buffer) {
        return mg_set_oom(out_error, MG_ERROR_STAGE_CREATE);
    }

    buffer->impl = (__bridge_retained void *)metalBuffer;
    buffer->length = length;
    buffer->ref_count = 1;
    *out_buffer = buffer;
    return MG_STATUS_OK;
}

void mg_backend_buffer_destroy(mg_buffer_t *buffer) {
    if (!buffer || !buffer->impl) {
        return;
    }

    id bufferObject = (__bridge_transfer id)buffer->impl;
    (void)bufferObject;
    buffer->impl = NULL;
}

mg_status_t mgEventCreate(mg_device_t *device, mg_event_t **out_event, mg_error_t **out_error) {
    mg_clear_error(out_error);
    if (!device || !device->impl || !out_event) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_CREATE,
                            MG_NODE_ID_INVALID, "device and out_event are required", NULL);
    }

    *out_event = NULL;
    id<MTLDevice> metalDevice = (__bridge id<MTLDevice>)device->impl;
    if (![metalDevice respondsToSelector:@selector(newSharedEvent)]) {
        return mg_set_error(out_error, MG_STATUS_UNSUPPORTED, MG_ERROR_STAGE_CREATE,
                            MG_NODE_ID_INVALID, "MTLSharedEvent is not available", NULL);
    }

    id<MTLSharedEvent> sharedEvent = [metalDevice newSharedEvent];
    if (!sharedEvent) {
        return mg_set_error(out_error, MG_STATUS_BACKEND_ERROR, MG_ERROR_STAGE_CREATE,
                            MG_NODE_ID_INVALID, "failed to create Metal shared event", NULL);
    }

    mg_event_t *event = (mg_event_t *)calloc(1, sizeof(*event));
    if (!event) {
        return mg_set_oom(out_error, MG_ERROR_STAGE_CREATE);
    }

    event->impl = (__bridge_retained void *)sharedEvent;
    event->ref_count = 1;
    *out_event = event;
    return MG_STATUS_OK;
}

void mg_backend_event_destroy(mg_event_t *event) {
    if (!event || !event->impl) {
        return;
    }

    id eventObject = (__bridge_transfer id)event->impl;
    (void)eventObject;
    event->impl = NULL;
}

void *mg_backend_buffer_contents(mg_buffer_t *buffer) {
    if (!buffer || !buffer->impl) {
        return NULL;
    }

    id<MTLBuffer> metalBuffer = (__bridge id<MTLBuffer>)buffer->impl;
    return [metalBuffer contents];
}

mg_status_t mgGraphInstantiate(mg_graph_t *graph, mg_device_t *device, mg_graph_exec_t **out_exec,
                               mg_error_t **out_error) {
    mg_clear_error(out_error);
    if (!graph || !device || !device->impl || !out_exec) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_INSTANTIATE,
                            MG_NODE_ID_INVALID, "graph, device, and out_exec are required", NULL);
    }

    *out_exec = NULL;
    mg_status_t status = mgGraphValidate(graph, out_error);
    if (status != MG_STATUS_OK) {
        return status;
    }

    size_t *order = NULL;
    if (graph->node_count > 0) {
        order = (size_t *)malloc(graph->node_count * sizeof(*order));
        if (!order) {
            return mg_set_oom(out_error, MG_ERROR_STAGE_INSTANTIATE);
        }
        status = mg_graph_topological_order(graph, order, out_error);
        if (status != MG_STATUS_OK) {
            free(order);
            return status;
        }
    }

    mg_graph_exec_t *exec = (mg_graph_exec_t *)calloc(1, sizeof(*exec));
    if (!exec) {
        free(order);
        return mg_set_oom(out_error, MG_ERROR_STAGE_INSTANTIATE);
    }

    exec->node_count = graph->node_count;
    if (exec->node_count > 0) {
        exec->nodes = (mg_exec_node_t *)calloc(exec->node_count, sizeof(*exec->nodes));
        if (!exec->nodes) {
            free(order);
            free(exec);
            return mg_set_oom(out_error, MG_ERROR_STAGE_INSTANTIATE);
        }
    }

    id<MTLDevice> metalDevice = (__bridge id<MTLDevice>)device->impl;
    exec->device_impl = (__bridge_retained void *)metalDevice;

    for (size_t i = 0; i < exec->node_count; ++i) {
        mg_node_t *node = graph->nodes[order[i]];
        status = mg_clone_exec_node(node, &exec->nodes[i], out_error);
        if (status != MG_STATUS_OK) {
            free(order);
            mgGraphExecDestroy(exec);
            return status;
        }

        if (exec->nodes[i].kind != MG_NODE_DISPATCH) {
            continue;
        }

        mg_exec_dispatch_t *dispatch = &exec->nodes[i].as.dispatch;
        NSString *path = mg_string(dispatch->metallib_path);
        NSURL *url = [NSURL fileURLWithPath:path];
        NSError *libraryError = nil;
        id<MTLLibrary> library = [metalDevice newLibraryWithURL:url error:&libraryError];
        if (!library) {
            free(order);
            mg_status_t errorStatus = mg_set_error(
                out_error, MG_STATUS_BACKEND_ERROR, MG_ERROR_STAGE_INSTANTIATE, dispatch->id,
                "failed to load Metal library", mg_ns_error_message(libraryError));
            mgGraphExecDestroy(exec);
            return errorStatus;
        }

        id<MTLFunction> function = [library newFunctionWithName:mg_string(dispatch->kernel_name)];
        if (!function) {
            free(order);
            mg_status_t errorStatus =
                mg_set_error(out_error, MG_STATUS_BACKEND_ERROR, MG_ERROR_STAGE_INSTANTIATE,
                             dispatch->id, "failed to find Metal kernel function", NULL);
            mgGraphExecDestroy(exec);
            return errorStatus;
        }

        NSError *pipelineError = nil;
        id<MTLComputePipelineState> pipeline =
            [metalDevice newComputePipelineStateWithFunction:function error:&pipelineError];
        if (!pipeline) {
            free(order);
            mg_status_t errorStatus = mg_set_error(
                out_error, MG_STATUS_BACKEND_ERROR, MG_ERROR_STAGE_INSTANTIATE, dispatch->id,
                "failed to create Metal compute pipeline", mg_ns_error_message(pipelineError));
            mgGraphExecDestroy(exec);
            return errorStatus;
        }

        dispatch->pipeline_impl = (__bridge_retained void *)pipeline;
    }

    free(order);
    *out_exec = exec;
    return MG_STATUS_OK;
}

void mg_backend_graph_exec_destroy(mg_graph_exec_t *exec) {
    if (!exec) {
        return;
    }

    for (size_t i = 0; i < exec->node_count; ++i) {
        mg_exec_node_clear(&exec->nodes[i]);
    }

    if (exec->device_impl) {
        id deviceObject = (__bridge_transfer id)exec->device_impl;
        (void)deviceObject;
        exec->device_impl = NULL;
    }
}

void mgGraphExecDestroy(mg_graph_exec_t *exec) {
    if (!exec) {
        return;
    }

    mg_backend_graph_exec_destroy(exec);
    free(exec->nodes);
    free(exec);
}

mg_status_t mgGraphLaunch(mg_graph_exec_t *exec, mg_stream_t *stream, mg_launch_t **out_launch,
                          mg_error_t **out_error) {
    mg_clear_error(out_error);
    if (!exec || !stream || !stream->impl || !out_launch) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_ENCODE,
                            MG_NODE_ID_INVALID, "exec, stream, and out_launch are required", NULL);
    }

    *out_launch = NULL;
    id<MTLCommandQueue> queue = (__bridge id<MTLCommandQueue>)stream->impl;
    id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];
    if (!commandBuffer) {
        return mg_set_error(out_error, MG_STATUS_BACKEND_ERROR, MG_ERROR_STAGE_ENCODE,
                            MG_NODE_ID_INVALID, "failed to create Metal command buffer", NULL);
    }

    mg_launch_t *launch = (mg_launch_t *)calloc(1, sizeof(*launch));
    if (!launch) {
        return mg_set_oom(out_error, MG_ERROR_STAGE_ENCODE);
    }

    size_t retainedCount = 0;
    size_t retainedEventCount = 0;
    for (size_t i = 0; i < exec->node_count; ++i) {
        switch (exec->nodes[i].kind) {
        case MG_NODE_DISPATCH:
            retainedCount += exec->nodes[i].as.dispatch.buffer_count;
            break;
        case MG_NODE_COPY:
            retainedCount += 2;
            break;
        case MG_NODE_FILL:
            retainedCount += 1;
            break;
        case MG_NODE_EVENT_WAIT:
        case MG_NODE_EVENT_SIGNAL:
            retainedEventCount += 1;
            break;
        default:
            break;
        }
    }

    if (retainedCount > 0) {
        launch->retained_buffers =
            (mg_buffer_t **)calloc(retainedCount, sizeof(*launch->retained_buffers));
        if (!launch->retained_buffers) {
            free(launch);
            return mg_set_oom(out_error, MG_ERROR_STAGE_ENCODE);
        }
    }
    if (retainedEventCount > 0) {
        launch->retained_events =
            (mg_event_t **)calloc(retainedEventCount, sizeof(*launch->retained_events));
        if (!launch->retained_events) {
            free(launch->retained_buffers);
            free(launch);
            return mg_set_oom(out_error, MG_ERROR_STAGE_ENCODE);
        }
    }

    launch->impl = (__bridge_retained void *)commandBuffer;

    for (size_t i = 0; i < exec->node_count; ++i) {
        mg_exec_node_t *node = &exec->nodes[i];
        switch (node->kind) {
        case MG_NODE_DISPATCH: {
            mg_exec_dispatch_t *dispatch = &node->as.dispatch;
            id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];
            if (!encoder) {
                mgLaunchDestroy(launch);
                return mg_set_error(out_error, MG_STATUS_BACKEND_ERROR, MG_ERROR_STAGE_ENCODE,
                                    dispatch->id, "failed to create Metal compute encoder", NULL);
            }

            id<MTLComputePipelineState> pipeline =
                (__bridge id<MTLComputePipelineState>)dispatch->pipeline_impl;
            [encoder setComputePipelineState:pipeline];
            for (uint32_t j = 0; j < dispatch->buffer_count; ++j) {
                mg_buffer_t *buffer = dispatch->buffers[j].buffer;
                id<MTLBuffer> metalBuffer = (__bridge id<MTLBuffer>)buffer->impl;
                [encoder setBuffer:metalBuffer
                            offset:dispatch->buffers[j].offset
                           atIndex:dispatch->buffers[j].index];
                mg_buffer_retain(buffer);
                launch->retained_buffers[launch->retained_buffer_count++] = buffer;
            }

            MTLSize grid =
                MTLSizeMake(dispatch->grid_size[0], dispatch->grid_size[1], dispatch->grid_size[2]);
            MTLSize threads = MTLSizeMake(dispatch->threads_per_threadgroup[0],
                                          dispatch->threads_per_threadgroup[1],
                                          dispatch->threads_per_threadgroup[2]);
            [encoder dispatchThreads:grid threadsPerThreadgroup:threads];
            [encoder endEncoding];
            break;
        }
        case MG_NODE_COPY: {
            id<MTLBlitCommandEncoder> encoder = [commandBuffer blitCommandEncoder];
            if (!encoder) {
                mgLaunchDestroy(launch);
                return mg_set_error(out_error, MG_STATUS_BACKEND_ERROR, MG_ERROR_STAGE_ENCODE,
                                    node->as.copy.id, "failed to create Metal blit encoder", NULL);
            }
            id<MTLBuffer> src = (__bridge id<MTLBuffer>)node->as.copy.src->impl;
            id<MTLBuffer> dst = (__bridge id<MTLBuffer>)node->as.copy.dst->impl;
            [encoder copyFromBuffer:src
                       sourceOffset:node->as.copy.src_offset
                           toBuffer:dst
                  destinationOffset:node->as.copy.dst_offset
                               size:node->as.copy.byte_count];
            [encoder endEncoding];
            mg_buffer_retain(node->as.copy.src);
            launch->retained_buffers[launch->retained_buffer_count++] = node->as.copy.src;
            mg_buffer_retain(node->as.copy.dst);
            launch->retained_buffers[launch->retained_buffer_count++] = node->as.copy.dst;
            break;
        }
        case MG_NODE_FILL: {
            id<MTLBlitCommandEncoder> encoder = [commandBuffer blitCommandEncoder];
            if (!encoder) {
                mgLaunchDestroy(launch);
                return mg_set_error(out_error, MG_STATUS_BACKEND_ERROR, MG_ERROR_STAGE_ENCODE,
                                    node->as.fill.id, "failed to create Metal blit encoder", NULL);
            }
            id<MTLBuffer> dst = (__bridge id<MTLBuffer>)node->as.fill.dst->impl;
            NSRange range = NSMakeRange(node->as.fill.dst_offset, node->as.fill.byte_count);
            [encoder fillBuffer:dst range:range value:node->as.fill.value];
            [encoder endEncoding];
            mg_buffer_retain(node->as.fill.dst);
            launch->retained_buffers[launch->retained_buffer_count++] = node->as.fill.dst;
            break;
        }
        case MG_NODE_EVENT_WAIT: {
            id<MTLSharedEvent> event = (__bridge id<MTLSharedEvent>)node->as.event.event->impl;
            [commandBuffer encodeWaitForEvent:event value:node->as.event.value];
            mg_event_retain(node->as.event.event);
            launch->retained_events[launch->retained_event_count++] = node->as.event.event;
            break;
        }
        case MG_NODE_EVENT_SIGNAL: {
            id<MTLSharedEvent> event = (__bridge id<MTLSharedEvent>)node->as.event.event->impl;
            [commandBuffer encodeSignalEvent:event value:node->as.event.value];
            mg_event_retain(node->as.event.event);
            launch->retained_events[launch->retained_event_count++] = node->as.event.event;
            break;
        }
        case MG_NODE_BARRIER:
            break;
        }
    }

    [commandBuffer commit];
    *out_launch = launch;
    return MG_STATUS_OK;
}

mg_status_t mgLaunchSynchronize(mg_launch_t *launch, mg_error_t **out_error) {
    mg_clear_error(out_error);
    if (!launch || !launch->impl) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_SYNC,
                            MG_NODE_ID_INVALID, "launch is required", NULL);
    }

    id<MTLCommandBuffer> commandBuffer = (__bridge id<MTLCommandBuffer>)launch->impl;
    [commandBuffer waitUntilCompleted];
    if (commandBuffer.status == MTLCommandBufferStatusError) {
        return mg_set_error(out_error, MG_STATUS_BACKEND_ERROR, MG_ERROR_STAGE_COMPLETE,
                            MG_NODE_ID_INVALID, "Metal command buffer failed",
                            mg_ns_error_message(commandBuffer.error));
    }

    return MG_STATUS_OK;
}

void mg_backend_launch_destroy(mg_launch_t *launch) {
    if (!launch) {
        return;
    }

    for (size_t i = 0; i < launch->retained_buffer_count; ++i) {
        mg_buffer_release(launch->retained_buffers[i]);
    }
    for (size_t i = 0; i < launch->retained_event_count; ++i) {
        mg_event_release(launch->retained_events[i]);
    }

    if (launch->impl) {
        id commandBuffer = (__bridge_transfer id)launch->impl;
        (void)commandBuffer;
        launch->impl = NULL;
    }
}

void mgLaunchDestroy(mg_launch_t *launch) {
    if (!launch) {
        return;
    }

    mg_backend_launch_destroy(launch);
    free(launch->retained_buffers);
    free(launch->retained_events);
    free(launch);
}
