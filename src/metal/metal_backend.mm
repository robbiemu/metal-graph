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
    out_dispatch->metallib_path = mg_strdup(node->dispatch.metallib_path);
    out_dispatch->kernel_name = mg_strdup(node->dispatch.kernel_name);
    memcpy(out_dispatch->grid_size, node->dispatch.grid_size, sizeof(out_dispatch->grid_size));
    memcpy(out_dispatch->threads_per_threadgroup, node->dispatch.threads_per_threadgroup,
           sizeof(out_dispatch->threads_per_threadgroup));

    if (!out_dispatch->metallib_path || !out_dispatch->kernel_name) {
        return mg_set_oom(out_error, MG_ERROR_STAGE_INSTANTIATE);
    }

    if (node->dispatch.buffer_count > 0) {
        size_t bytes = sizeof(*out_dispatch->buffers) * node->dispatch.buffer_count;
        out_dispatch->buffers = (mg_buffer_binding_t *)malloc(bytes);
        if (!out_dispatch->buffers) {
            return mg_set_oom(out_error, MG_ERROR_STAGE_INSTANTIATE);
        }

        memcpy(out_dispatch->buffers, node->dispatch.buffers, bytes);
        out_dispatch->buffer_count = node->dispatch.buffer_count;
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

mg_status_t mg_device_create_system_default(mg_device_t **out_device, mg_error_t **out_error) {
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

void mg_device_destroy(mg_device_t *device) {
    if (!device) {
        return;
    }

    mg_backend_device_destroy(device);
    free(device);
}

mg_status_t mg_stream_create(mg_device_t *device, mg_stream_t **out_stream,
                             mg_error_t **out_error) {
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

void mg_stream_destroy(mg_stream_t *stream) {
    if (!stream) {
        return;
    }

    mg_backend_stream_destroy(stream);
    free(stream);
}

mg_status_t mg_buffer_create_shared(mg_device_t *device, size_t length, mg_buffer_t **out_buffer,
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

void *mg_backend_buffer_contents(mg_buffer_t *buffer) {
    if (!buffer || !buffer->impl) {
        return NULL;
    }

    id<MTLBuffer> metalBuffer = (__bridge id<MTLBuffer>)buffer->impl;
    return [metalBuffer contents];
}

mg_status_t mg_graph_instantiate(mg_graph_t *graph, mg_device_t *device, mg_graph_exec_t **out_exec,
                                 mg_error_t **out_error) {
    mg_clear_error(out_error);
    if (!graph || !device || !device->impl || !out_exec) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_INSTANTIATE,
                            MG_NODE_ID_INVALID, "graph, device, and out_exec are required", NULL);
    }

    *out_exec = NULL;
    mg_status_t status = mg_graph_validate(graph, out_error);
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

    exec->dispatch_count = graph->node_count;
    if (exec->dispatch_count > 0) {
        exec->dispatches =
            (mg_exec_dispatch_t *)calloc(exec->dispatch_count, sizeof(*exec->dispatches));
        if (!exec->dispatches) {
            free(order);
            free(exec);
            return mg_set_oom(out_error, MG_ERROR_STAGE_INSTANTIATE);
        }
    }

    id<MTLDevice> metalDevice = (__bridge id<MTLDevice>)device->impl;
    exec->device_impl = (__bridge_retained void *)metalDevice;

    for (size_t i = 0; i < exec->dispatch_count; ++i) {
        mg_node_t *node = graph->nodes[order[i]];
        status = mg_clone_dispatch(node, &exec->dispatches[i], out_error);
        if (status != MG_STATUS_OK) {
            free(order);
            mg_graph_exec_destroy(exec);
            return status;
        }

        NSString *path = mg_string(exec->dispatches[i].metallib_path);
        NSURL *url = [NSURL fileURLWithPath:path];
        NSError *libraryError = nil;
        id<MTLLibrary> library = [metalDevice newLibraryWithURL:url error:&libraryError];
        if (!library) {
            free(order);
            mg_status_t errorStatus = mg_set_error(
                out_error, MG_STATUS_BACKEND_ERROR, MG_ERROR_STAGE_INSTANTIATE, node->id,
                "failed to load Metal library", mg_ns_error_message(libraryError));
            mg_graph_exec_destroy(exec);
            return errorStatus;
        }

        id<MTLFunction> function =
            [library newFunctionWithName:mg_string(exec->dispatches[i].kernel_name)];
        if (!function) {
            free(order);
            mg_status_t errorStatus =
                mg_set_error(out_error, MG_STATUS_BACKEND_ERROR, MG_ERROR_STAGE_INSTANTIATE,
                             node->id, "failed to find Metal kernel function", NULL);
            mg_graph_exec_destroy(exec);
            return errorStatus;
        }

        NSError *pipelineError = nil;
        id<MTLComputePipelineState> pipeline =
            [metalDevice newComputePipelineStateWithFunction:function error:&pipelineError];
        if (!pipeline) {
            free(order);
            mg_status_t errorStatus = mg_set_error(
                out_error, MG_STATUS_BACKEND_ERROR, MG_ERROR_STAGE_INSTANTIATE, node->id,
                "failed to create Metal compute pipeline", mg_ns_error_message(pipelineError));
            mg_graph_exec_destroy(exec);
            return errorStatus;
        }

        exec->dispatches[i].pipeline_impl = (__bridge_retained void *)pipeline;
    }

    free(order);
    *out_exec = exec;
    return MG_STATUS_OK;
}

void mg_backend_graph_exec_destroy(mg_graph_exec_t *exec) {
    if (!exec) {
        return;
    }

    for (size_t i = 0; i < exec->dispatch_count; ++i) {
        mg_exec_dispatch_clear(&exec->dispatches[i]);
    }

    if (exec->device_impl) {
        id deviceObject = (__bridge_transfer id)exec->device_impl;
        (void)deviceObject;
        exec->device_impl = NULL;
    }
}

void mg_graph_exec_destroy(mg_graph_exec_t *exec) {
    if (!exec) {
        return;
    }

    mg_backend_graph_exec_destroy(exec);
    free(exec->dispatches);
    free(exec);
}

mg_status_t mg_graph_launch(mg_graph_exec_t *exec, mg_stream_t *stream, mg_launch_t **out_launch,
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

    size_t retainedCount = 0;
    for (size_t i = 0; i < exec->dispatch_count; ++i) {
        retainedCount += exec->dispatches[i].buffer_count;
    }

    mg_launch_t *launch = (mg_launch_t *)calloc(1, sizeof(*launch));
    if (!launch) {
        return mg_set_oom(out_error, MG_ERROR_STAGE_ENCODE);
    }

    if (retainedCount > 0) {
        launch->retained_buffers =
            (mg_buffer_t **)calloc(retainedCount, sizeof(*launch->retained_buffers));
        if (!launch->retained_buffers) {
            free(launch);
            return mg_set_oom(out_error, MG_ERROR_STAGE_ENCODE);
        }
    }

    launch->impl = (__bridge_retained void *)commandBuffer;

    for (size_t i = 0; i < exec->dispatch_count; ++i) {
        mg_exec_dispatch_t *dispatch = &exec->dispatches[i];
        id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];
        if (!encoder) {
            mg_launch_destroy(launch);
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
        MTLSize threads =
            MTLSizeMake(dispatch->threads_per_threadgroup[0], dispatch->threads_per_threadgroup[1],
                        dispatch->threads_per_threadgroup[2]);
        [encoder dispatchThreads:grid threadsPerThreadgroup:threads];
        [encoder endEncoding];
    }

    [commandBuffer commit];
    *out_launch = launch;
    return MG_STATUS_OK;
}

mg_status_t mg_launch_synchronize(mg_launch_t *launch, mg_error_t **out_error) {
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

    if (launch->impl) {
        id commandBuffer = (__bridge_transfer id)launch->impl;
        (void)commandBuffer;
        launch->impl = NULL;
    }
}

void mg_launch_destroy(mg_launch_t *launch) {
    if (!launch) {
        return;
    }

    mg_backend_launch_destroy(launch);
    free(launch->retained_buffers);
    free(launch);
}
