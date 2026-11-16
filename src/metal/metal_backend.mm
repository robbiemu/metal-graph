#include "../core/internal.h"
#include "metal_graph/metal_graph_metal.h"

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <dispatch/dispatch.h>
#import <objc/runtime.h>
#if MG_ENABLE_MPSGRAPH
#import <MetalPerformanceShadersGraph/MetalPerformanceShadersGraph.h>
#endif

#include <stdlib.h>
#include <string.h>

bool mg_backend_physical_overlap(const mg_buffer_t *a, size_t ao, size_t ac, const mg_buffer_t *b,
                                 size_t bo, size_t bc) {
    if (!a || !b || !ac || !bc)
        return false;
    if (a == b || (a->impl && a->impl == b->impl))
        return ao <= bo ? bo - ao < ac : ao - bo < bc;
    if (!a->impl || !b->impl || !a->origin_kind || !b->origin_kind)
        return false;
    id<MTLBuffer> an = (__bridge id<MTLBuffer>)a->impl;
    id<MTLBuffer> bn = (__bridge id<MTLBuffer>)b->impl;
    id<MTLHeap> heap = an.heap;
    if (!heap || heap != bn.heap)
        return false;
    if (@available(macOS 10.15, *)) {
        if (heap.type == MTLHeapTypePlacement) {
            if (an.heapOffset > SIZE_MAX - ao || bn.heapOffset > SIZE_MAX - bo)
                return true;
            ao += an.heapOffset;
            bo += bn.heapOffset;
            if (ac > SIZE_MAX - ao || bc > SIZE_MAX - bo)
                return true;
            return ao <= bo ? bo - ao < ac : ao - bo < bc;
        }
        if (heap.type == MTLHeapTypeAutomatic)
            return [an isAliasable] || [bn isAliasable];
    }
    return true;
}

#include "hazard_tracking.inc"

static NSString *mg_string(const char *value) {
    return value ? [NSString stringWithUTF8String:value] : nil;
}

static const char *mg_ns_error_message(NSError *error) {
    if (!error) {
        return NULL;
    }
    return [[error localizedDescription] UTF8String];
}

static size_t mg_metal_buffer_offset(const mg_buffer_t *buffer, size_t relative_offset) {
    return buffer->byte_offset + relative_offset;
}

static mg_status_t mg_clone_dispatch(const mg_node_t *node, mg_exec_dispatch_t *out_dispatch,
                                     mg_error_t **out_error) {
    memset(out_dispatch, 0, sizeof(*out_dispatch));
    out_dispatch->id = node->id;
    out_dispatch->patch_flags = node->patch_flags;
    out_dispatch->metallib_path = mg_strdup(node->as.dispatch.metallib_path);
    out_dispatch->kernel_name = mg_strdup(node->as.dispatch.kernel_name);
    memcpy(out_dispatch->grid_size, node->as.dispatch.grid_size, sizeof(out_dispatch->grid_size));
    memcpy(out_dispatch->threads_per_threadgroup, node->as.dispatch.threads_per_threadgroup,
           sizeof(out_dispatch->threads_per_threadgroup));
    memcpy(out_dispatch->max_grid_size, node->as.dispatch.max_grid_size,
           sizeof(out_dispatch->max_grid_size));

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
    if (node->as.dispatch.scalar_count > 0) {
        out_dispatch->scalars = (mg_scalar_binding_t *)calloc(node->as.dispatch.scalar_count,
                                                              sizeof(*out_dispatch->scalars));
        if (!out_dispatch->scalars) {
            return mg_set_oom(out_error, MG_ERROR_STAGE_INSTANTIATE);
        }
        out_dispatch->scalar_count = node->as.dispatch.scalar_count;
        for (uint32_t i = 0; i < out_dispatch->scalar_count; ++i) {
            void *data = malloc(node->as.dispatch.scalars[i].byte_count);
            if (!data) {
                return mg_set_oom(out_error, MG_ERROR_STAGE_INSTANTIATE);
            }
            memcpy(data, node->as.dispatch.scalars[i].data,
                   node->as.dispatch.scalars[i].byte_count);
            out_dispatch->scalars[i] = (mg_scalar_binding_t){
                node->as.dispatch.scalars[i].index,
                data,
                node->as.dispatch.scalars[i].byte_count,
            };
        }
    }
    if (node->as.dispatch.resource_count > 0) {
        size_t bytes = sizeof(*out_dispatch->resources) * node->as.dispatch.resource_count;
        out_dispatch->resources = (mg_dispatch_resource_desc_t *)malloc(bytes);
        if (!out_dispatch->resources) {
            return mg_set_oom(out_error, MG_ERROR_STAGE_INSTANTIATE);
        }
        memcpy(out_dispatch->resources, node->as.dispatch.resources, bytes);
        out_dispatch->resource_count = node->as.dispatch.resource_count;
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
    for (uint32_t i = 0; i < dispatch->scalar_count; ++i) {
        free((void *)dispatch->scalars[i].data);
    }

    if (dispatch->pipeline_impl) {
        id pipeline = (__bridge_transfer id)dispatch->pipeline_impl;
        (void)pipeline;
    }

    free(dispatch->metallib_path);
    free(dispatch->kernel_name);
    free(dispatch->buffers);
    free(dispatch->scalars);
    free(dispatch->resources);
    memset(dispatch, 0, sizeof(*dispatch));
}

static mg_status_t mg_clone_mpsgraph_tensors(const mg_mpsgraph_tensor_t *src, uint32_t count,
                                             mg_mpsgraph_tensor_t **out_tensors,
                                             uint32_t *out_count, mg_error_t **out_error) {
    *out_tensors = NULL;
    *out_count = 0;
    if (count == 0) {
        return MG_STATUS_OK;
    }

    mg_mpsgraph_tensor_t *tensors = (mg_mpsgraph_tensor_t *)calloc(count, sizeof(*tensors));
    if (!tensors) {
        return mg_set_oom(out_error, MG_ERROR_STAGE_INSTANTIATE);
    }

    for (uint32_t i = 0; i < count; ++i) {
        tensors[i] = src[i];
        tensors[i].shape = NULL;
        if (src[i].rank > 0) {
            tensors[i].shape = (size_t *)malloc(sizeof(*tensors[i].shape) * src[i].rank);
            if (!tensors[i].shape) {
                for (uint32_t j = 0; j < i; ++j) {
                    mg_buffer_release(tensors[j].buffer);
                    free(tensors[j].shape);
                }
                free(tensors);
                return mg_set_oom(out_error, MG_ERROR_STAGE_INSTANTIATE);
            }
            memcpy(tensors[i].shape, src[i].shape, sizeof(*tensors[i].shape) * src[i].rank);
        }
        mg_buffer_retain(tensors[i].buffer);
    }

    *out_tensors = tensors;
    *out_count = count;
    return MG_STATUS_OK;
}

static void mg_exec_mpsgraph_tensor_array_clear(mg_mpsgraph_tensor_t *tensors, uint32_t count) {
    for (uint32_t i = 0; i < count; ++i) {
        mg_buffer_release(tensors[i].buffer);
        free(tensors[i].shape);
    }
    free(tensors);
}

static mg_status_t mg_clone_mpsgraph(const mg_node_t *node, mg_exec_mpsgraph_t *out_mpsgraph,
                                     mg_error_t **out_error) {
    memset(out_mpsgraph, 0, sizeof(*out_mpsgraph));
    out_mpsgraph->id = node->id;
    out_mpsgraph->package_path = mg_strdup(node->as.mpsgraph.package_path);
    if (!out_mpsgraph->package_path) {
        return mg_set_oom(out_error, MG_ERROR_STAGE_INSTANTIATE);
    }

    mg_status_t status =
        mg_clone_mpsgraph_tensors(node->as.mpsgraph.feeds, node->as.mpsgraph.feed_count,
                                  &out_mpsgraph->feeds, &out_mpsgraph->feed_count, out_error);
    if (status != MG_STATUS_OK) {
        return status;
    }
    return mg_clone_mpsgraph_tensors(node->as.mpsgraph.targets, node->as.mpsgraph.target_count,
                                     &out_mpsgraph->targets, &out_mpsgraph->target_count,
                                     out_error);
}

static void mg_exec_mpsgraph_clear(mg_exec_mpsgraph_t *mpsgraph) {
    if (!mpsgraph) {
        return;
    }

#if MG_ENABLE_MPSGRAPH
    if (mpsgraph->executable_impl) {
        id executable = (__bridge_transfer id)mpsgraph->executable_impl;
        (void)executable;
    }
    if (mpsgraph->retained_package_path) {
        NSString *path = mg_string(mpsgraph->retained_package_path);
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    }
#endif
    free(mpsgraph->package_path);
    free(mpsgraph->retained_package_path);
    mg_exec_mpsgraph_tensor_array_clear(mpsgraph->feeds, mpsgraph->feed_count);
    mg_exec_mpsgraph_tensor_array_clear(mpsgraph->targets, mpsgraph->target_count);
    memset(mpsgraph, 0, sizeof(*mpsgraph));
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
    case MG_NODE_MPSGRAPH:
        mg_exec_mpsgraph_clear(&node->as.mpsgraph);
        break;
    case MG_NODE_BARRIER:
        node->as.barrier_id = MG_NODE_ID_INVALID;
        break;
    default:
        if ((int)node->kind == MG_NODE_INTERNAL_WORKSPACE) {
            memset(&node->as.workspace, 0, sizeof(node->as.workspace));
        } else if ((int)node->kind == MG_NODE_INTERNAL_WORKSPACE_FILL) {
            mg_buffer_release(node->as.workspace_fill.dst);
            memset(&node->as.workspace_fill, 0, sizeof(node->as.workspace_fill));
        }
        break;
    }
    memset(node, 0, sizeof(*node));
}

static mg_status_t mg_clone_exec_node(const mg_node_t *src, mg_exec_node_t *dst,
                                      const mg_workspace_plan_t *workspace,
                                      mg_error_t **out_error) {
    memset(dst, 0, sizeof(*dst));
    dst->kind = src->kind;

    switch (src->kind) {
    case MG_NODE_DISPATCH:
        return mg_clone_dispatch(src, &dst->as.dispatch, out_error);
    case MG_NODE_COPY:
        dst->as.copy.id = src->id;
        dst->as.copy.patch_flags = src->patch_flags;
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
        dst->as.fill.patch_flags = src->patch_flags;
        dst->as.fill.dst = src->as.fill.dst;
        dst->as.fill.dst_offset = src->as.fill.dst_offset;
        dst->as.fill.byte_count = src->as.fill.byte_count;
        dst->as.fill.value = src->as.fill.value;
        mg_buffer_retain(dst->as.fill.dst);
        return MG_STATUS_OK;
    case MG_NODE_EVENT_WAIT:
    case MG_NODE_EVENT_SIGNAL:
        dst->as.event.id = src->id;
        dst->as.event.patch_flags = src->patch_flags;
        dst->as.event.event = src->as.event.event;
        dst->as.event.value = src->as.event.value;
        mg_event_retain(dst->as.event.event);
        return MG_STATUS_OK;
    case MG_NODE_BARRIER:
        dst->as.barrier_id = src->id;
        return MG_STATUS_OK;
    case MG_NODE_MPSGRAPH:
        return mg_clone_mpsgraph(src, &dst->as.mpsgraph, out_error);
    default:
        if ((int)src->kind == MG_NODE_INTERNAL_WORKSPACE) {
            dst->as.workspace.id = src->id;
            dst->as.workspace.size = src->as.workspace.size;
            dst->as.workspace.alignment = src->as.workspace.alignment;
            return mg_workspace_plan_offset_for_node(workspace, src->id, &dst->as.workspace.offset,
                                                     out_error);
        }
        if ((int)src->kind == MG_NODE_INTERNAL_WORKSPACE_FILL) {
            dst->as.workspace_fill.id = src->id;
            dst->as.workspace_fill.size = src->as.workspace_fill.size;
            dst->as.workspace_fill.alignment = src->as.workspace_fill.alignment;
            dst->as.workspace_fill.value = src->as.workspace_fill.value;
            dst->as.workspace_fill.dst = src->as.workspace_fill.dst;
            dst->as.workspace_fill.dst_offset = src->as.workspace_fill.dst_offset;
            mg_buffer_retain(dst->as.workspace_fill.dst);
            return mg_workspace_plan_offset_for_node(workspace, src->id,
                                                     &dst->as.workspace_fill.offset, out_error);
        }
        break;
    }

    return mg_set_error(out_error, MG_STATUS_INTERNAL_ERROR, MG_ERROR_STAGE_INSTANTIATE, src->id,
                        "unknown node kind", NULL);
}

static mg_status_t mg_workspace_allocate(mg_graph_exec_t *exec, id<MTLDevice> metalDevice,
                                         mg_error_t **out_error) {
    if (exec->workspace.total_size == 0) {
        return MG_STATUS_OK;
    }

    id<MTLBuffer> workspace = [metalDevice newBufferWithLength:exec->workspace.total_size
                                                       options:MTLResourceStorageModePrivate];
    if (!workspace) {
        return mg_set_error(out_error, MG_STATUS_BACKEND_ERROR, MG_ERROR_STAGE_BACKEND_ALLOCATE,
                            MG_NODE_ID_INVALID, "failed to allocate Metal workspace buffer", NULL);
    }

    exec->workspace.backend_impl = (__bridge_retained void *)workspace;
    return MG_STATUS_OK;
}

static void mg_workspace_backend_destroy(mg_workspace_plan_t *workspace) {
    if (!workspace || !workspace->backend_impl) {
        return;
    }

    id workspaceObject = (__bridge_transfer id)workspace->backend_impl;
    (void)workspaceObject;
    workspace->backend_impl = NULL;
}

static void mg_icb_backend_destroy(mg_icb_plan_t *icb) {
    if (!icb || !icb->backend_impl) {
        return;
    }
    id icbObject = (__bridge_transfer id)icb->backend_impl;
    (void)icbObject;
    icb->backend_impl = NULL;
}

#if MG_ENABLE_MPSGRAPH
static MPSDataType mg_mpsgraph_data_type(mg_tensor_data_type_t data_type) {
    switch (data_type) {
    case MG_TENSOR_DATA_TYPE_FLOAT32:
        return MPSDataTypeFloat32;
    default:
        return MPSDataTypeInvalid;
    }
}

static MPSShape *mg_mpsgraph_shape(const mg_mpsgraph_tensor_t *tensor) {
    NSMutableArray<NSNumber *> *shape = [NSMutableArray arrayWithCapacity:tensor->rank];
    for (uint32_t i = 0; i < tensor->rank; ++i) {
        [shape addObject:@((NSUInteger)tensor->shape[i])];
    }
    return shape;
}

static MPSGraphTensorData *mg_mpsgraph_tensor_data(const mg_mpsgraph_tensor_t *tensor) {
    id<MTLBuffer> buffer = (__bridge id<MTLBuffer>)tensor->buffer->impl;
    return [[MPSGraphTensorData alloc] initWithMTLBuffer:buffer
                                                   shape:mg_mpsgraph_shape(tensor)
                                                dataType:mg_mpsgraph_data_type(tensor->data_type)];
}
#endif

static mg_status_t mg_mpsgraph_load_executable(mg_exec_mpsgraph_t *mpsgraph,
                                               mg_error_t **out_error) {
#if MG_ENABLE_MPSGRAPH
    NSString *sourcePath = mg_string(mpsgraph->package_path);
    NSString *retainedPath = [NSTemporaryDirectory()
        stringByAppendingPathComponent:[NSString stringWithFormat:@"metal-graph-exec-%@"
                                                                   ".mpsgraphpackage",
                                                                  [[NSUUID UUID] UUIDString]]];
    NSURL *sourceURL = [NSURL fileURLWithPath:sourcePath];
    NSURL *retainedURL = [NSURL fileURLWithPath:retainedPath];
    NSError *copyError = nil;
    if (![[NSFileManager defaultManager] copyItemAtURL:sourceURL
                                                 toURL:retainedURL
                                                 error:&copyError]) {
        return mg_set_error(out_error, MG_STATUS_BACKEND_ERROR, MG_ERROR_STAGE_INSTANTIATE,
                            mpsgraph->id, "failed to retain MPSGraph executable package",
                            mg_ns_error_message(copyError));
    }
    mpsgraph->retained_package_path = mg_strdup([retainedPath fileSystemRepresentation]);
    if (!mpsgraph->retained_package_path) {
        [[NSFileManager defaultManager] removeItemAtURL:retainedURL error:nil];
        return mg_set_oom(out_error, MG_ERROR_STAGE_INSTANTIATE);
    }

    @try {
        MPSGraphExecutable *executable =
            [[MPSGraphExecutable alloc] initWithMPSGraphPackageAtURL:retainedURL
                                               compilationDescriptor:nil];
        if (!executable) {
            return mg_set_error(out_error, MG_STATUS_BACKEND_ERROR, MG_ERROR_STAGE_INSTANTIATE,
                                mpsgraph->id, "failed to load MPSGraph executable package", NULL);
        }
        mpsgraph->executable_impl = (__bridge_retained void *)executable;
        return MG_STATUS_OK;
    } @catch (NSException *exception) {
        return mg_set_error(out_error, MG_STATUS_BACKEND_ERROR, MG_ERROR_STAGE_INSTANTIATE,
                            mpsgraph->id, "failed to load MPSGraph executable package",
                            [[exception reason] UTF8String]);
    }
#else
    (void)mpsgraph;
    return mg_set_error(out_error, MG_STATUS_UNSUPPORTED, MG_ERROR_STAGE_INSTANTIATE,
                        mpsgraph ? mpsgraph->id : MG_NODE_ID_INVALID,
                        "MPSGraph support is not enabled in this build", NULL);
#endif
}

static mg_icb_fallback_reason_t mg_icb_dispatch_eligible(const mg_exec_dispatch_t *dispatch) {
    if (!dispatch) {
        return MG_ICB_FALLBACK_INELIGIBLE_NODE;
    }
    if (dispatch->patch_flags != 0 || dispatch->scalar_count != 0) {
        return MG_ICB_FALLBACK_PATCHABLE_FIELD;
    }
    for (uint32_t i = 0; i < dispatch->buffer_count; ++i) {
        const mg_dispatch_resource_desc_t *resource = mg_dispatch_find_resource(
            dispatch->resources, dispatch->resource_count, dispatch->buffers[i].index);
        if (!resource || resource->byte_count == 0 ||
            resource->access == MG_RESOURCE_ACCESS_UNKNOWN) {
            return MG_ICB_FALLBACK_UNKNOWN_RESOURCE_ACCESS;
        }
    }
    return MG_ICB_FALLBACK_NONE;
}

static mg_status_t mg_icb_plan_build(mg_graph_exec_t *exec, id<MTLDevice> metalDevice) {
    exec->icb.enabled_flags = MG_OPTIMIZATION_ICB;
    SEL icbSelector = @selector(newIndirectCommandBufferWithDescriptor:maxCommandCount:options:);
    exec->icb.available = [metalDevice respondsToSelector:icbSelector] ? 1u : 0u;

    if (exec->node_count == 0) {
        return MG_STATUS_OK;
    }
    exec->icb.groups_planned = 1;

    if (exec->node_count != 1) {
        exec->icb.groups_fallback = 1;
        exec->icb.last_fallback_reason = MG_ICB_FALLBACK_INELIGIBLE_NODE;
        return MG_STATUS_OK;
    }

    if (!exec->icb.available) {
        exec->icb.groups_fallback = 1;
        exec->icb.last_fallback_reason = MG_ICB_FALLBACK_UNSUPPORTED;
        return MG_STATUS_OK;
    }

    NSUInteger maxKernelBufferBindCount = 0;
    for (size_t i = 0; i < exec->node_count; ++i) {
        if (exec->nodes[i].kind != MG_NODE_DISPATCH) {
            exec->icb.groups_fallback = 1;
            exec->icb.last_fallback_reason = MG_ICB_FALLBACK_INELIGIBLE_NODE;
            return MG_STATUS_OK;
        }
        mg_exec_dispatch_t *dispatch = &exec->nodes[i].as.dispatch;
        mg_icb_fallback_reason_t reason = mg_icb_dispatch_eligible(dispatch);
        if (reason != MG_ICB_FALLBACK_NONE) {
            exec->icb.groups_fallback = 1;
            exec->icb.last_fallback_reason = reason;
            return MG_STATUS_OK;
        }
        for (uint32_t j = 0; j < dispatch->buffer_count; ++j) {
            NSUInteger candidate = (NSUInteger)dispatch->buffers[j].index + 1u;
            if (candidate > maxKernelBufferBindCount) {
                maxKernelBufferBindCount = candidate;
            }
        }
    }

    MTLIndirectCommandBufferDescriptor *descriptor = [MTLIndirectCommandBufferDescriptor new];
    descriptor.commandTypes = MTLIndirectCommandTypeConcurrentDispatchThreads;
    descriptor.inheritPipelineState = NO;
    descriptor.inheritBuffers = NO;
    descriptor.maxKernelBufferBindCount = maxKernelBufferBindCount;

    id<MTLIndirectCommandBuffer> icb =
        [metalDevice newIndirectCommandBufferWithDescriptor:descriptor
                                            maxCommandCount:(NSUInteger)exec->node_count
                                                    options:0];
    if (!icb) {
        exec->icb.groups_fallback = 1;
        exec->icb.last_fallback_reason = MG_ICB_FALLBACK_BACKEND_ERROR;
        return MG_STATUS_OK;
    }

    for (size_t i = 0; i < exec->node_count; ++i) {
        mg_exec_dispatch_t *dispatch = &exec->nodes[i].as.dispatch;
        id<MTLIndirectComputeCommand> command = [icb indirectComputeCommandAtIndex:(NSUInteger)i];
        [command reset];
        id<MTLComputePipelineState> pipeline =
            (__bridge id<MTLComputePipelineState>)dispatch->pipeline_impl;
        [command setComputePipelineState:pipeline];
        for (uint32_t j = 0; j < dispatch->buffer_count; ++j) {
            mg_buffer_t *buffer = dispatch->buffers[j].buffer;
            id<MTLBuffer> metalBuffer = (__bridge id<MTLBuffer>)buffer->impl;
            [command setKernelBuffer:metalBuffer
                              offset:mg_metal_buffer_offset(buffer, dispatch->buffers[j].offset)
                             atIndex:dispatch->buffers[j].index];
        }

        MTLSize grid =
            MTLSizeMake(dispatch->grid_size[0], dispatch->grid_size[1], dispatch->grid_size[2]);
        MTLSize threads =
            MTLSizeMake(dispatch->threads_per_threadgroup[0], dispatch->threads_per_threadgroup[1],
                        dispatch->threads_per_threadgroup[2]);
        [command concurrentDispatchThreads:grid threadsPerThreadgroup:threads];
    }

    exec->icb.backend_impl = (__bridge_retained void *)icb;
    exec->icb.command_count = exec->node_count;
    exec->icb.groups_fallback = 0;
    exec->icb.last_fallback_reason = MG_ICB_FALLBACK_NONE;
    return MG_STATUS_OK;
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

/* All accepted jobs for this stream share one asynchronous whole-job FIFO. */
@protocol MGStreamJob <NSObject>
- (void)startWithCompletion:(dispatch_block_t)done onQueue:(dispatch_queue_t)queue;
- (void)failBeforeStart:(NSException *)exception;
@end

@interface MGStreamScheduler : NSObject {
    dispatch_queue_t _serial;
    NSMutableArray<id<MGStreamJob>> *_pending;
    id<MGStreamJob> _active;
}
- (void)enqueue:(id<MGStreamJob>)job;
@end
@implementation MGStreamScheduler
- (instancetype)init {
    self = [super init];
    if (!self)
        return nil;
    _serial = dispatch_queue_create("metalgraph.stream.scheduler", DISPATCH_QUEUE_SERIAL);
    _pending = [NSMutableArray new];
    if (!_serial || !_pending)
        return nil;
    return self;
}
- (void)startNext {
    if (_active || _pending.count == 0)
        return;
    _active = _pending.firstObject;
    [_pending removeObjectAtIndex:0];
    [_active
        startWithCompletion:^{
          dispatch_async(self->_serial, ^{
            /* Transfer one owning reference through an opaque pointer; no strong local for the
             * retired job survives on this serial queue if concurrent cleanup finishes first. */
            void *retired = (__bridge_retained void *)self->_active;
            self->_active = nil;
            [self startNext];
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
              id finished = (__bridge_transfer id)retired;
              (void)[finished self];
            });
          });
        }
                    onQueue:_serial];
}
- (void)enqueue:(id<MGStreamJob>)job {
    /* The queued block captures only an owning opaque token, never a strong job local. */
    void *ownedJob = (__bridge_retained void *)job;
    @try {
        dispatch_async(_serial, ^{
          __unsafe_unretained id<MGStreamJob> borrowedJob = (__bridge id<MGStreamJob>)ownedJob;
          @try {
              [self->_pending addObject:borrowedJob];
          } @catch (NSException *exception) {
              [borrowedJob failBeforeStart:exception];
              dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                id finished = (__bridge_transfer id)ownedJob;
                (void)[finished self];
              });
              return;
          }
          /* The FIFO array now owns the job. Drop the token before starting it. */
          id transferred = (__bridge_transfer id)ownedJob;
          transferred = nil;
          [self startNext];
        });
    } @catch (NSException *exception) {
        id released = (__bridge_transfer id)ownedJob;
        (void)released;
        @throw exception;
    }
}
@end

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

    MGStreamScheduler *scheduler = [MGStreamScheduler new];
    if (!scheduler) {
        free(stream);
        return mg_set_oom(out_error, MG_ERROR_STAGE_CREATE);
    }
    stream->impl = (__bridge_retained void *)queue;
    stream->scheduler_impl = (__bridge_retained void *)scheduler;
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
    if (stream->scheduler_impl) {
        id scheduler = (__bridge_transfer id)stream->scheduler_impl;
        (void)scheduler;
        stream->scheduler_impl = NULL;
    }
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
    buffer->device_impl = (__bridge void *)metalDevice;
    buffer->length = length;
    buffer->origin_kind = MG_BUFFER_ORIGIN_LIBRARY_OWNED;
    buffer->is_host_visible = 1;
    buffer->is_mutable = 1;
    buffer->retained_backend_impl = 1;
    buffer->source_framework = mg_strdup("Metal Graph");
    if (!buffer->source_framework) {
        mg_backend_buffer_destroy(buffer);
        free(buffer);
        return mg_set_oom(out_error, MG_ERROR_STAGE_CREATE);
    }
    buffer->ref_count = 1;
    *out_buffer = buffer;
    return MG_STATUS_OK;
}

static bool mg_metal_buffer_access_valid(mg_metal_buffer_access_t access) {
    return access == MG_METAL_BUFFER_ACCESS_READ || access == MG_METAL_BUFFER_ACCESS_WRITE ||
           access == MG_METAL_BUFFER_ACCESS_READ_WRITE;
}

static bool mg_metal_buffer_access_writes(mg_metal_buffer_access_t access) {
    return access == MG_METAL_BUFFER_ACCESS_WRITE ||
           access == MG_METAL_BUFFER_ACCESS_READ_WRITE;
}

mg_status_t mgMetalBufferWrap(mg_device_t *device, const mg_metal_buffer_wrap_desc_t *desc,
                              mg_buffer_t **out_buffer, mg_error_t **out_error) {
    mg_clear_error(out_error);
    if (out_buffer) {
        *out_buffer = NULL;
    }

    if (!device || !device->impl || !desc || !out_buffer) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_CREATE,
                            MG_NODE_ID_INVALID, "device, desc, and out_buffer are required", NULL);
    }
    if (desc->size != sizeof(*desc)) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_CREATE,
                            MG_NODE_ID_INVALID, "Metal buffer wrap descriptor size is invalid",
                            NULL);
    }
    if (!desc->buffer) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_CREATE,
                            MG_NODE_ID_INVALID, "Metal buffer wrap requires a buffer", NULL);
    }
    if (desc->byte_length == 0 || desc->byte_offset > SIZE_MAX - desc->byte_length) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_CREATE,
                            MG_NODE_ID_INVALID, "Metal buffer wrap range is invalid", NULL);
    }
    if (!mg_metal_buffer_access_valid(desc->access)) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_CREATE,
                            MG_NODE_ID_INVALID, "Metal buffer wrap access is invalid", NULL);
    }

    uint32_t valid_flags = MG_METAL_BUFFER_WRAP_RETAIN_BUFFER | MG_METAL_BUFFER_WRAP_RETAIN_OWNER |
                           MG_METAL_BUFFER_WRAP_HOST_VISIBLE | MG_METAL_BUFFER_WRAP_MUTABLE;
    if (desc->flags & ~valid_flags) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_CREATE,
                            MG_NODE_ID_INVALID, "Metal buffer wrap flags are invalid", NULL);
    }
    if (!(desc->flags & MG_METAL_BUFFER_WRAP_RETAIN_BUFFER) &&
        !(desc->flags & MG_METAL_BUFFER_WRAP_RETAIN_OWNER)) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_CREATE,
                            MG_NODE_ID_INVALID,
                            "Metal buffer wrap requires retained buffer or owner lifetime", NULL);
    }
    bool retains_owner = (desc->flags & MG_METAL_BUFFER_WRAP_RETAIN_OWNER) != 0;
    if (retains_owner &&
        (!desc->owner_context || !desc->owner_retain || !desc->owner_release)) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_CREATE,
                            MG_NODE_ID_INVALID, "Metal buffer wrap owner retention is invalid",
                            NULL);
    }
    if (!retains_owner && (desc->owner_context || desc->owner_retain || desc->owner_release)) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_CREATE,
                            MG_NODE_ID_INVALID,
                            "Metal buffer wrap owner callbacks require RETAIN_OWNER", NULL);
    }
    bool mutable_requested = (desc->flags & MG_METAL_BUFFER_WRAP_MUTABLE) != 0;
    if (mg_metal_buffer_access_writes(desc->access) && !mutable_requested) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_CREATE,
                            MG_NODE_ID_INVALID,
                            "Metal buffer wrap write access requires MUTABLE flag", NULL);
    }

    id<MTLDevice> metalDevice = (__bridge id<MTLDevice>)device->impl;
    id<MTLBuffer> metalBuffer = desc->buffer;
    if (metalBuffer.device != metalDevice) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_CREATE,
                            MG_NODE_ID_INVALID, "Metal buffer belongs to a different device", NULL);
    }
    if (desc->byte_offset + desc->byte_length > [metalBuffer length]) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_CREATE,
                            MG_NODE_ID_INVALID, "Metal buffer wrap range exceeds buffer length",
                            NULL);
    }
    bool host_visible = (desc->flags & MG_METAL_BUFFER_WRAP_HOST_VISIBLE) != 0;
    if (host_visible && [metalBuffer contents] == NULL) {
        return mg_set_error(out_error, MG_STATUS_UNSUPPORTED, MG_ERROR_STAGE_CREATE,
                            MG_NODE_ID_INVALID,
                            "Metal buffer wrap requested host visibility for non-host-visible "
                            "storage",
                            NULL);
    }

    mg_buffer_t *buffer = (mg_buffer_t *)calloc(1, sizeof(*buffer));
    if (!buffer) {
        return mg_set_oom(out_error, MG_ERROR_STAGE_CREATE);
    }
    buffer->source_framework = mg_strdup("Metal");
    if (!buffer->source_framework) {
        free(buffer);
        return mg_set_oom(out_error, MG_ERROR_STAGE_CREATE);
    }

    if (desc->label) {
        metalBuffer.label = [NSString stringWithUTF8String:desc->label];
    }
    if (retains_owner) {
        desc->owner_retain(desc->owner_context);
        buffer->owner_context = desc->owner_context;
        buffer->owner_release = desc->owner_release;
    }

    if (desc->flags & MG_METAL_BUFFER_WRAP_RETAIN_BUFFER) {
        buffer->impl = (__bridge_retained void *)metalBuffer;
        buffer->retained_backend_impl = 1;
    } else {
        buffer->impl = (__bridge void *)metalBuffer;
    }
    buffer->device_impl = (__bridge void *)metalDevice;
    buffer->length = desc->byte_length;
    buffer->byte_offset = desc->byte_offset;
    buffer->origin_kind = MG_BUFFER_ORIGIN_EXTERNAL_METAL;
    buffer->is_zero_copy = 1;
    buffer->is_external = 1;
    buffer->is_host_visible = host_visible ? 1 : 0;
    buffer->is_mutable = mutable_requested ? 1 : 0;
    buffer->ref_count = 1;
    *out_buffer = buffer;
    return MG_STATUS_OK;
}

void mg_backend_buffer_destroy(mg_buffer_t *buffer) {
    if (!buffer || !buffer->impl) {
        return;
    }

    if (buffer->retained_backend_impl) {
        id bufferObject = (__bridge_transfer id)buffer->impl;
        (void)bufferObject;
    }
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

mg_status_t mgMetalEventWrap(mg_device_t *device, id<MTLSharedEvent> shared_event,
                             mg_event_t **out_event, mg_error_t **out_error) {
    mg_clear_error(out_error);
    if (out_event)
        *out_event = NULL;
    if (!device || !device->impl || !shared_event || !out_event) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_CREATE,
                            MG_NODE_ID_INVALID, "device, shared event and output are required",
                            NULL);
    }
    if (![shared_event conformsToProtocol:@protocol(MTLSharedEvent)]) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_CREATE,
                            MG_NODE_ID_INVALID, "native event must conform to MTLSharedEvent",
                            NULL);
    }
    id<MTLDevice> metalDevice = (__bridge id<MTLDevice>)device->impl;
    /* Metal shared events normally report nil because they span multiple devices. */
    if (shared_event.device && shared_event.device != metalDevice) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_CREATE,
                            MG_NODE_ID_INVALID, "shared event belongs to a different device", NULL);
    }
    mg_event_t *event = (mg_event_t *)calloc(1, sizeof(*event));
    if (!event)
        return mg_set_oom(out_error, MG_ERROR_STAGE_CREATE);
    event->impl = (__bridge_retained void *)shared_event;
    event->ref_count = 1;
    *out_event = event;
    return MG_STATUS_OK;
}

mg_status_t mgMetalEventGetSharedEvent(const mg_event_t *event,
                                       id<MTLSharedEvent> __unsafe_unretained *out_event,
                                       mg_error_t **out_error) {
    mg_clear_error(out_error);
    if (out_event)
        *out_event = nil;
    if (!event || !event->impl || !out_event) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_CREATE,
                            MG_NODE_ID_INVALID, "event and native event output are required", NULL);
    }
    id nativeEvent = (__bridge id)event->impl;
    if (![nativeEvent conformsToProtocol:@protocol(MTLSharedEvent)]) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_CREATE,
                            MG_NODE_ID_INVALID, "event does not contain a Metal shared event",
                            NULL);
    }
    *out_event = nativeEvent;
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
    void *contents = [metalBuffer contents];
    if (!contents) {
        return NULL;
    }
    return (uint8_t *)contents + buffer->byte_offset;
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

    exec->ref_count = 1;
    exec->node_count = graph->node_count;
    status = mg_graph_plan_workspace(graph, order, &exec->workspace, out_error);
    if (status != MG_STATUS_OK) {
        free(order);
        free(exec);
        return status;
    }

    if (exec->node_count > 0) {
        exec->nodes = (mg_exec_node_t *)calloc(exec->node_count, sizeof(*exec->nodes));
        if (!exec->nodes) {
            free(order);
            mg_workspace_plan_clear(&exec->workspace);
            free(exec);
            return mg_set_oom(out_error, MG_ERROR_STAGE_INSTANTIATE);
        }
    }

    /* Freeze explicit edges in executable order, independent of the source graph. */
    if (graph->edge_count) {
        if (graph->edge_count > SIZE_MAX / sizeof(*exec->edges) ||
            !(exec->edges = (mg_edge_t *)malloc(graph->edge_count * sizeof(*exec->edges)))) {
            free(order);
            mgGraphExecDestroy(exec);
            return mg_set_oom(out_error, MG_ERROR_STAGE_INSTANTIATE);
        }
        exec->edge_count = graph->edge_count;
        for (size_t e = 0; e < graph->edge_count; ++e) {
            size_t before = 0, after = 0;
            while (order[before] != graph->edges[e].before)
                ++before;
            while (order[after] != graph->edges[e].after)
                ++after;
            exec->edges[e] = (mg_edge_t){before, after};
        }
    }

    id<MTLDevice> metalDevice = (__bridge id<MTLDevice>)device->impl;
    exec->device_impl = (__bridge_retained void *)metalDevice;
    status = mg_workspace_allocate(exec, metalDevice, out_error);
    if (status != MG_STATUS_OK) {
        free(order);
        mgGraphExecDestroy(exec);
        return status;
    }

    for (size_t i = 0; i < exec->node_count; ++i) {
        mg_node_t *node = graph->nodes[order[i]];
        status = mg_clone_exec_node(node, &exec->nodes[i], &exec->workspace, out_error);
        if (status != MG_STATUS_OK) {
            free(order);
            mgGraphExecDestroy(exec);
            return status;
        }

        if (exec->nodes[i].kind == MG_NODE_MPSGRAPH) {
            status = mg_mpsgraph_load_executable(&exec->nodes[i].as.mpsgraph, out_error);
            if (status != MG_STATUS_OK) {
                free(order);
                mgGraphExecDestroy(exec);
                return status;
            }
            continue;
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

        MTLComputePipelineDescriptor *pipelineDescriptor = [MTLComputePipelineDescriptor new];
        pipelineDescriptor.computeFunction = function;
        if ([pipelineDescriptor respondsToSelector:@selector(setSupportIndirectCommandBuffers:)]) {
            pipelineDescriptor.supportIndirectCommandBuffers = YES;
        }
        NSError *pipelineError = nil;
        id<MTLComputePipelineState> pipeline =
            [metalDevice newComputePipelineStateWithDescriptor:pipelineDescriptor
                                                       options:0
                                                    reflection:nil
                                                         error:&pipelineError];
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

    status = mg_icb_plan_build(exec, metalDevice);
    if (status != MG_STATUS_OK) {
        free(order);
        mgGraphExecDestroy(exec);
        return status;
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

    mg_workspace_backend_destroy(&exec->workspace);
    mg_workspace_plan_clear(&exec->workspace);
    mg_icb_backend_destroy(&exec->icb);

    if (exec->device_impl) {
        id deviceObject = (__bridge_transfer id)exec->device_impl;
        (void)deviceObject;
        exec->device_impl = NULL;
    }
}

static void mg_exec_release(mg_graph_exec_t *exec) {
    if (!exec)
        return;
    if (__atomic_fetch_sub(&exec->ref_count, 1, __ATOMIC_ACQ_REL) != 1)
        return;
    mg_backend_graph_exec_destroy(exec);
    free(exec->nodes);
    free(exec->edges);
    free(exec);
}

void mgGraphExecDestroy(mg_graph_exec_t *exec) { mg_exec_release(exec); }

/* Immutable association key; each command buffer carries its own completion unit. */
static const char mg_completion_unit_key = 0;

/* The block retained by Metal owns this tracker independently of the public launch handle.
 * Its exec reference in turn retains all frozen graph resources and logical owners. */
@class MGLaunchCompletionTracker;
@interface MGLaunchCompletionUnit : NSObject {
    NSLock *_lock;
    MGLaunchCompletionTracker *_tracker;
    mg_node_id_t _node;
    BOOL _graph;
    dispatch_semaphore_t _testHold;
}
- (instancetype)initWithTracker:(MGLaunchCompletionTracker *)tracker
                           node:(mg_node_id_t)node
                          graph:(BOOL)graph;
@property(nonatomic) BOOL syntheticError;
@property(nonatomic, strong) dispatch_semaphore_t testHold;
- (void)finish;
- (void)finishWithError:(NSError *)error failed:(BOOL)failed;
@end

@interface MGLaunchCompletionTracker : NSObject {
    NSCondition *_lock;
    mg_graph_exec_t *_exec;
    id<MTLCommandQueue> _queue;
    NSError *_firstError;
    NSString *_errorMessage;
    NSString *_backendMessage;
    mg_status_t _errorStatus;
    mg_error_stage_t _errorStage;
    mg_node_id_t _errorNode;
    BOOL _errorGraph;
    BOOL _failed;
    BOOL _jobMode;
    BOOL _jobTerminal;
    BOOL _jobFinishing;
    BOOL _accountingFailure;
    mg_node_id_t _accountingNode;
    mg_error_stage_t _accountingStage;
    MGHazardSnapshot *_hazards;
    dispatch_block_t _stageDone;
    NSUInteger _pending;
    BOOL _sealed;
    BOOL _submitted;
    BOOL _acknowledged;
}
- (instancetype)initWithExec:(mg_graph_exec_t *)exec queue:(id<MTLCommandQueue>)queue;
- (MGLaunchCompletionUnit *)registerCommandBuffer:(id<MTLCommandBuffer>)buffer
                                             node:(mg_node_id_t)node
                                   syntheticError:(BOOL)syntheticError;
- (MGLaunchCompletionUnit *)beginGraphUnit:(mg_node_id_t)node;
- (void)finishedUnitWithError:(NSError *)error
                       failed:(BOOL)failed
                         node:(mg_node_id_t)node
                        graph:(BOOL)graph;
- (BOOL)waitForTerminal;
- (void)markAccountingFailure:(mg_node_id_t)node stage:(mg_error_stage_t)stage;
- (void)activateJob;
- (void)setHazards:(MGHazardSnapshot *)hazards;
- (void)beginStage:(dispatch_block_t)done;
- (void)finishJob;
- (void)testWaitForTerminalReady:(dispatch_semaphore_t)ready;
- (BOOL)getFailure:(NSError *__autoreleasing *)error node:(mg_node_id_t *)node graph:(BOOL *)graph;
- (void)recordStatus:(mg_status_t)status
               stage:(mg_error_stage_t)stage
                node:(mg_node_id_t)node
             message:(NSString *)message
             backend:(NSString *)backend;
- (mg_status_t)copyFailure:(mg_error_t **)outError;
- (void)seal;
- (void)acknowledge;
- (void)acknowledgeIfUnsubmitted;
@end

@implementation MGLaunchCompletionTracker
- (instancetype)initWithExec:(mg_graph_exec_t *)exec queue:(id<MTLCommandQueue>)queue {
    self = [super init];
    if (!self)
        return nil;
    _lock = [NSCondition new];
    if (!_lock)
        return nil;
    _exec = exec;
    _queue = queue;
    __atomic_fetch_add(&exec->ref_count, 1, __ATOMIC_RELAXED);
    return self;
}
- (void)acknowledgeLocked {
    if (!_acknowledged) {
        _acknowledged = YES;
        __atomic_fetch_sub(&_exec->in_flight_count, 1, __ATOMIC_ACQ_REL);
    }
}
- (void)finishedUnitWithError:(NSError *)error
                       failed:(BOOL)failed
                         node:(mg_node_id_t)node
                        graph:(BOOL)graph {
    NSString *description = nil;
    @try {
        description = error.localizedDescription;
    } @catch (NSException *exception) {
        (void)exception;
    }
    [_lock lock];
    if (failed && !_failed) {
        _failed = YES;
        _firstError = error;
        _errorNode = node;
        _errorGraph = graph;
        _errorStatus = MG_STATUS_BACKEND_ERROR;
        _errorStage = MG_ERROR_STAGE_COMPLETE;
        _errorMessage = graph ? @"MPSGraph executable failed" : @"Metal command buffer failed";
        _backendMessage = description;
    }
    if (_pending)
        --_pending;
    dispatch_block_t done = nil;
    if (_sealed && !_pending) {
        if (_jobMode) {
            done = _stageDone;
            _stageDone = nil;
        } else if (_submitted)
            [self acknowledgeLocked];
        [_lock broadcast];
    }
    [_lock unlock];
    if (done)
        done();
}
- (MGLaunchCompletionUnit *)beginGraphUnit:(mg_node_id_t)node {
    MGLaunchCompletionUnit *unit = [[MGLaunchCompletionUnit alloc] initWithTracker:self
                                                                              node:node
                                                                             graph:YES];
    if (!unit)
        return nil;
    [_lock lock];
    ++_pending;
    [_lock unlock];
    return unit;
}
- (MGLaunchCompletionUnit *)registerCommandBuffer:(id<MTLCommandBuffer>)buffer
                                             node:(mg_node_id_t)node
                                   syntheticError:(BOOL)syntheticError {
    MGLaunchCompletionUnit *unit = [[MGLaunchCompletionUnit alloc] initWithTracker:self
                                                                              node:node
                                                                             graph:NO];
    if (!unit)
        return nil;
    unit.syntheticError = syntheticError;
    unit.testHold = (__bridge dispatch_semaphore_t)_exec->test_completion_hold;
    [_lock lock];
    ++_pending;
    [_lock unlock];
    @try {
        if (_exec->test_raw_failure == 3) {
            _exec->test_raw_failure = 0;
            @throw [NSException exceptionWithName:@"MGInjectedRegistrationFailure"
                                           reason:@"injected registration failure"
                                         userInfo:nil];
        }
        @synchronized(buffer) {
            objc_setAssociatedObject(buffer, &mg_completion_unit_key, unit,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [buffer addCompletedHandler:^(id<MTLCommandBuffer> completed) {
              MGLaunchCompletionUnit *done = nil;
              @synchronized(completed) {
                  done = objc_getAssociatedObject(completed, &mg_completion_unit_key);
                  objc_setAssociatedObject(completed, &mg_completion_unit_key, nil,
                                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
              }
              BOOL failed = completed.status == MTLCommandBufferStatusError || done.syntheticError;
              NSError *reported = done.syntheticError ? [NSError errorWithDomain:@"MGInjectedRoot"
                                                                            code:1
                                                                        userInfo:nil]
                                                      : (failed ? completed.error : nil);
              if (done.testHold)
                  dispatch_semaphore_wait(done.testHold,
                                          dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC));
              [done finishWithError:reported failed:failed];
            }];
        }
    } @catch (NSException *exception) {
        (void)exception;
        @synchronized(buffer) {
            objc_setAssociatedObject(buffer, &mg_completion_unit_key, nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        [unit finish];
        return nil;
    }
    [_lock lock];
    _submitted = YES;
    [_lock unlock];
    return unit;
}
- (BOOL)waitForTerminal {
    [_lock lock];
    while (_jobMode ? (!_jobTerminal && !_accountingFailure) : (!_sealed || _pending))
        [_lock wait];
    BOOL terminal = _jobMode ? _jobTerminal : YES;
    [_lock unlock];
    return terminal;
}
- (void)markAccountingFailure:(mg_node_id_t)node stage:(mg_error_stage_t)stage {
    [_lock lock];
    _accountingNode = node;
    _accountingStage = stage;
    _accountingFailure = YES;
    [_lock broadcast];
    [_lock unlock];
}
- (void)activateJob {
    [_lock lock];
    _jobMode = YES;
    _jobTerminal = NO;
    [_lock unlock];
}
- (void)setHazards:(MGHazardSnapshot *)hazards {
    _hazards = hazards;
}
- (void)beginStage:(dispatch_block_t)done {
    dispatch_block_t copied = [done copy];
    [_lock lock];
    _jobMode = YES;
    _sealed = NO;
    _submitted = NO;
    _pending = 0;
    _stageDone = copied;
    [_lock unlock];
}
- (void)finishJob {
    [_lock lock];
    BOOL finish = !_jobTerminal && !_jobFinishing;
    if (finish)
        _jobFinishing = YES;
    [_lock unlock];
    if (finish) {
        [_hazards retire];
        [_lock lock];
        [self acknowledgeLocked];
        _jobTerminal = YES;
        [_lock broadcast];
        [_lock unlock];
    }
}
- (void)testWaitForTerminalReady:(dispatch_semaphore_t)ready {
    [_lock lock];
    dispatch_semaphore_signal(ready);
    while (!_sealed || _pending)
        [_lock wait];
    [_lock unlock];
}
- (BOOL)getFailure:(NSError *__autoreleasing *)error node:(mg_node_id_t *)node graph:(BOOL *)graph {
    [_lock lock];
    BOOL failed = _failed;
    if (error)
        *error = _firstError;
    if (node)
        *node = _errorNode;
    if (graph)
        *graph = _errorGraph;
    [_lock unlock];
    return failed;
}
- (void)recordStatus:(mg_status_t)status
               stage:(mg_error_stage_t)stage
                node:(mg_node_id_t)node
             message:(NSString *)message
             backend:(NSString *)backend {
    NSString *messageCopy = [message copy];
    NSString *backendCopy = [backend copy];
    [_lock lock];
    if (!_failed) {
        _failed = YES;
        _errorStatus = status;
        _errorStage = stage;
        _errorNode = node;
        _errorMessage = messageCopy;
        _backendMessage = backendCopy;
    }
    [_lock unlock];
}
- (mg_status_t)copyFailure:(mg_error_t **)outError {
    [_lock lock];
    BOOL failed = _failed;
    mg_status_t status = _errorStatus;
    mg_error_stage_t stage = _errorStage;
    mg_node_id_t node = _errorNode;
    NSString *message = _errorMessage;
    NSString *backend = _backendMessage;
    if (_accountingFailure) {
        failed = YES;
        status = MG_STATUS_UNSUPPORTED;
        stage = _accountingStage;
        node = _accountingNode;
        message =
            _jobTerminal
                ? @"MPSGraph submission was unaccounted; physical completion was later established"
                : @"MPSGraph submission completion is unaccounted; resources remain retained";
    }
    [_lock unlock];
    if (!failed)
        return MG_STATUS_OK;
    return mg_set_error(outError, status, stage, node, message.UTF8String, backend.UTF8String);
}
- (void)seal {
    [_lock lock];
    _sealed = YES;
    dispatch_block_t done = nil;
    if (!_pending) {
        if (_jobMode) {
            done = _stageDone;
            _stageDone = nil;
        } else if (_submitted)
            [self acknowledgeLocked];
        [_lock broadcast];
    }
    [_lock unlock];
    if (done)
        done();
}
- (void)acknowledge {
    [_lock lock];
    [self acknowledgeLocked];
    [_lock unlock];
}
- (void)acknowledgeIfUnsubmitted {
    [_lock lock];
    if (!_submitted)
        [self acknowledgeLocked];
    [_lock unlock];
}
- (void)dealloc {
    mg_graph_exec_t *ownedExec = _exec;
    _exec = NULL;
    void *ownedHazards = (__bridge_retained void *)_hazards;
    _hazards = nil;
    void *ownedQueue = (__bridge_retained void *)_queue;
    _queue = nil;
    if (ownedExec || ownedHazards || ownedQueue)
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
          id hazards = (__bridge_transfer id)ownedHazards;
          id queue = (__bridge_transfer id)ownedQueue;
          if (ownedExec)
              mg_exec_release(ownedExec);
          (void)[hazards self];
          (void)[queue self];
        });
}
@end

@implementation MGLaunchCompletionUnit
- (instancetype)initWithTracker:(MGLaunchCompletionTracker *)tracker
                           node:(mg_node_id_t)node
                          graph:(BOOL)graph {
    self = [super init];
    if (!self)
        return nil;
    _lock = [NSLock new];
    if (!_lock)
        return nil;
    _tracker = tracker;
    _node = node;
    _graph = graph;
    return self;
}
- (void)finish {
    [self finishWithError:nil failed:NO];
}
- (void)finishWithError:(NSError *)error failed:(BOOL)failed {
    [_lock lock];
    void *retired = (__bridge_retained void *)_tracker;
    _tracker = nil;
    [_lock unlock];
    if (!retired)
        return;
    __unsafe_unretained MGLaunchCompletionTracker *tracker =
        (__bridge MGLaunchCompletionTracker *)retired;
    [tracker finishedUnitWithError:error failed:failed node:_node graph:_graph];
    /* The callback thread must not perform the final exec/owner release. */
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
      id finished = (__bridge_transfer id)retired;
      (void)[finished self];
    });
}
@end

/* Internal test: establish a waiter under the lock before sealing an empty tracker. */
bool mg_test_tracker_seal_zero_pending(mg_graph_exec_t *exec, mg_stream_t *stream) {
    MGLaunchCompletionTracker *tracker =
        [[MGLaunchCompletionTracker alloc] initWithExec:exec
                                                  queue:(__bridge id<MTLCommandQueue>)stream->impl];
    if (!tracker)
        return false;
    dispatch_semaphore_t ready = dispatch_semaphore_create(0);
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block MGLaunchCompletionTracker *heldTracker = tracker;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
      [heldTracker testWaitForTerminalReady:ready];
      heldTracker = nil;
      dispatch_semaphore_signal(done);
    });
    long started =
        dispatch_semaphore_wait(ready, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    [tracker seal];
    long finished =
        dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    return started == 0 && finished == 0;
}

/* Internal deterministic failure injection; one-shot and owned by the test exec. */
void mg_test_fail_next_raw_after_commit(mg_graph_exec_t *exec) { exec->test_raw_failure = 2; }
void mg_test_fail_next_raw_before_commit(mg_graph_exec_t *exec) { exec->test_raw_failure = 1; }
void mg_test_fail_next_raw_registration(mg_graph_exec_t *exec) { exec->test_raw_failure = 3; }

static mg_node_id_t mg_exec_node_id(const mg_exec_node_t *node) {
    switch (node->kind) {
    case MG_NODE_DISPATCH:
        return node->as.dispatch.id;
    case MG_NODE_COPY:
        return node->as.copy.id;
    case MG_NODE_FILL:
        return node->as.fill.id;
    case MG_NODE_EVENT_WAIT:
    case MG_NODE_EVENT_SIGNAL:
        return node->as.event.id;
    case MG_NODE_BARRIER:
        return node->as.barrier_id;
    case MG_NODE_MPSGRAPH:
        return node->as.mpsgraph.id;
    default:
        if ((int)node->kind == MG_NODE_INTERNAL_WORKSPACE)
            return node->as.workspace.id;
        if ((int)node->kind == MG_NODE_INTERNAL_WORKSPACE_FILL)
            return node->as.workspace_fill.id;
        return MG_NODE_ID_INVALID;
    }
}

/* A job is held by the stream scheduler, never by a borrowed public launch/stream handle. */
@interface MGAsyncJob : NSObject <MGStreamJob> {
    mg_graph_exec_t *_exec; /* retained by _tracker */
    MGLaunchCompletionTracker *_tracker;
    id<MTLCommandQueue> _queue;
    dispatch_queue_t _schedulerQueue;
    dispatch_block_t _done;
    NSMutableArray<id<MTLCommandBuffer>> *_stageRoots;
    size_t _index;
    BOOL _emptySubmitted;
    BOOL _stageOpen;
    BOOL _terminal;
}
@property(nonatomic, strong) id<MTLFence> passFence;
@property(nonatomic, assign) BOOL manualHazards;
- (instancetype)initWithExec:(mg_graph_exec_t *)exec
                     tracker:(MGLaunchCompletionTracker *)tracker
                       queue:(id<MTLCommandQueue>)queue;
- (BOOL)registerGraphRoot:(id<MTLCommandBuffer>)root node:(mg_node_id_t)node;
- (BOOL)knowsGraphRoot:(id<MTLCommandBuffer>)root;
- (BOOL)takeFreshRootFailure;
@end

static bool mg_manual_hazard_buffer(mg_buffer_t *buffer) {
    if (!buffer || !buffer->impl)
        return true;
    id<MTLBuffer> native = (__bridge id<MTLBuffer>)buffer->impl;
    return native.heap != nil || native.hazardTrackingMode != MTLHazardTrackingModeTracked;
}
static bool mg_exec_manual_hazards(mg_graph_exec_t *exec, size_t *passes) {
    bool required = false;
    *passes = 0;
    for (size_t i = 0; i < exec->node_count; ++i) {
        mg_exec_node_t *node = &exec->nodes[i];
        switch (node->kind) {
        case MG_NODE_DISPATCH:
            ++*passes;
            for (uint32_t j = 0; j < node->as.dispatch.buffer_count; ++j)
                required |= mg_manual_hazard_buffer(node->as.dispatch.buffers[j].buffer);
            break;
        case MG_NODE_COPY:
            ++*passes;
            required |= mg_manual_hazard_buffer(node->as.copy.src);
            required |= mg_manual_hazard_buffer(node->as.copy.dst);
            break;
        case MG_NODE_FILL:
            ++*passes;
            required |= mg_manual_hazard_buffer(node->as.fill.dst);
            break;
        case MG_NODE_MPSGRAPH:
            for (uint32_t j = 0; j < node->as.mpsgraph.feed_count; ++j)
                required |= mg_manual_hazard_buffer(node->as.mpsgraph.feeds[j].buffer);
            for (uint32_t j = 0; j < node->as.mpsgraph.target_count; ++j)
                required |= mg_manual_hazard_buffer(node->as.mpsgraph.targets[j].buffer);
            break;
        default:
            if ((int)node->kind == MG_NODE_INTERNAL_WORKSPACE_FILL) {
                *passes += 2;
                required |= mg_manual_hazard_buffer(node->as.workspace_fill.dst);
                id<MTLBuffer> workspace = (__bridge id<MTLBuffer>)exec->workspace.backend_impl;
                if (workspace && (workspace.heap ||
                                  workspace.hazardTrackingMode != MTLHazardTrackingModeTracked))
                    required = true;
            }
            break;
        }
    }
    return required;
}
void mg_test_fail_next_fence(mg_graph_exec_t *exec) { exec->test_fence_failure = 1; }

#if MG_ENABLE_MPSGRAPH
@interface MGTrackedMPSCommandBuffer : MPSCommandBuffer
@property(nonatomic, weak) MGAsyncJob *job;
@property(nonatomic) mg_node_id_t nodeId;
@property(nonatomic, strong) id<MTLCommandBuffer> unregisteredFreshRoot;
@end
@implementation MGTrackedMPSCommandBuffer
- (void)commitAndContinue {
    id<MTLCommandBuffer> oldRoot = self.rootCommandBuffer;
    if (!oldRoot || ![self.job registerGraphRoot:oldRoot node:self.nodeId])
        @throw [NSException exceptionWithName:@"MGRootTracking"
                                       reason:@"could not register MPS root before continuation"
                                     userInfo:nil];
    [super commitAndContinue];
    id<MTLCommandBuffer> newRoot = self.rootCommandBuffer;
    BOOL injected = [self.job takeFreshRootFailure];
    if (!newRoot || newRoot == oldRoot || injected ||
        ![self.job registerGraphRoot:newRoot node:self.nodeId]) {
        if (newRoot && newRoot != oldRoot &&
            (newRoot.status == MTLCommandBufferStatusNotEnqueued ||
             newRoot.status == MTLCommandBufferStatusEnqueued))
            self.unregisteredFreshRoot = newRoot;
        @throw [NSException exceptionWithName:@"MGRootTracking"
                                       reason:@"could not register continued MPS root"
                                     userInfo:nil];
    }
}
@end
#endif

void mg_test_set_mps_continuations(mg_graph_exec_t *exec, uint8_t count) {
    exec->test_mps_continuations = count;
    exec->test_mps_observed_roots = 0;
}
void mg_test_fail_mps_new_root(mg_graph_exec_t *exec) { exec->test_mps_failure = 1; }
void mg_test_set_mps_failure(mg_graph_exec_t *exec, uint8_t mode) { exec->test_mps_failure = mode; }
void mg_test_resolve_unknown_root(mg_graph_exec_t *exec) {
    void *owned = __atomic_exchange_n(&exec->test_unknown_unit, NULL, __ATOMIC_ACQ_REL);
    MGLaunchCompletionUnit *unit = (__bridge_transfer MGLaunchCompletionUnit *)owned;
    [unit finish];
}

@implementation MGAsyncJob
- (instancetype)initWithExec:(mg_graph_exec_t *)exec
                     tracker:(MGLaunchCompletionTracker *)tracker
                       queue:(id<MTLCommandQueue>)queue {
    self = [super init];
    if (!self)
        return nil;
    _exec = exec;
    _tracker = tracker;
    _queue = queue;
    _stageRoots = [NSMutableArray new];
    if (!_stageRoots)
        return nil;
    return self;
}
- (void)finishJob {
    if (_terminal)
        return;
    _terminal = YES;
    [_stageRoots removeAllObjects];
    [_tracker finishJob];
    dispatch_block_t done = _done;
    _done = nil;
    if (done)
        done();
}
- (void)stageFinished {
    _stageOpen = NO;
    [_stageRoots removeAllObjects];
    if ([_tracker getFailure:nil node:NULL graph:NULL]) {
        [self finishJob];
        return;
    }
    [self advanceSafely];
}
- (void)beginStage {
    if (_exec->test_stage_failure) {
        _exec->test_stage_failure = 0;
        @throw [NSException exceptionWithName:@"MGInjectedStage"
                                       reason:@"synthetic stage setup failure"
                                     userInfo:nil];
    }
    [_tracker beginStage:^{
      dispatch_async(self->_schedulerQueue, ^{
        [self stageFinished];
      });
    }];
    _stageOpen = YES;
}
- (void)recordFailure:(mg_status_t)status
                stage:(mg_error_stage_t)stage
                 node:(mg_node_id_t)node
              message:(NSString *)message
              backend:(NSString *)backend {
    [_tracker recordStatus:status stage:stage node:node message:message backend:backend];
}
- (BOOL)takeFreshRootFailure {
    if (_exec->test_mps_failure != 1)
        return NO;
    _exec->test_mps_failure = 0;
    return YES;
}
- (BOOL)knowsGraphRoot:(id<MTLCommandBuffer>)root {
    if (!root)
        return NO;
    for (id<MTLCommandBuffer> known in _stageRoots)
        if (known == root)
            return YES;
    return NO;
}
- (BOOL)registerGraphRoot:(id<MTLCommandBuffer>)root node:(mg_node_id_t)node {
    if ([self knowsGraphRoot:root])
        return YES;
    if (!root)
        return NO;
    @try {
        [_stageRoots addObject:root];
    } @catch (NSException *exception) {
        (void)exception;
        return NO;
    }
    BOOL syntheticError = _exec->test_mps_failure == 6;
    if (syntheticError)
        _exec->test_mps_failure = 0;
    MGLaunchCompletionUnit *unit = [_tracker registerCommandBuffer:root
                                                              node:node
                                                    syntheticError:syntheticError];
    if (!unit) {
        [_stageRoots removeLastObject];
        return NO;
    }
    return YES;
}
- (void)cancelKnownUncommittedRoots {
    for (id<MTLCommandBuffer> root in _stageRoots) {
        MTLCommandBufferStatus status = root.status;
        if (status == MTLCommandBufferStatusNotEnqueued ||
            status == MTLCommandBufferStatusEnqueued) {
            MGLaunchCompletionUnit *unit = nil;
            @synchronized(root) {
                unit = objc_getAssociatedObject(root, &mg_completion_unit_key);
                objc_setAssociatedObject(root, &mg_completion_unit_key, nil,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            [unit finish];
        }
    }
}
- (void)runGraphStage {
#if MG_ENABLE_MPSGRAPH
    mg_exec_mpsgraph_t *mpsgraph = &_exec->nodes[_index].as.mpsgraph;
    mg_node_id_t nodeId = mpsgraph->id;
    id<MTLCommandBuffer> root = [_queue commandBuffer];
    if (!root) {
        [self recordFailure:MG_STATUS_BACKEND_ERROR
                      stage:MG_ERROR_STAGE_ENCODE
                       node:nodeId
                    message:@"failed to create MPSGraph command buffer"
                    backend:nil];
        [self finishJob];
        return;
    }
    [self beginStage];
    MGLaunchCompletionUnit *graphUnit = [_tracker beginGraphUnit:nodeId];
    if (!graphUnit || ![self registerGraphRoot:root node:nodeId]) {
        [graphUnit finish];
        [self recordFailure:MG_STATUS_BACKEND_ERROR
                      stage:MG_ERROR_STAGE_ENCODE
                       node:nodeId
                    message:@"failed to prepare MPSGraph completion tracking"
                    backend:nil];
        [self cancelKnownUncommittedRoots];
        [_tracker seal];
        return;
    }
    MGTrackedMPSCommandBuffer *wrapper = nil;
    id<MTLCommandBuffer> rootAtEncode = nil;
    id<MTLCommandBuffer> finalEncodedRoot = nil;
    BOOL graphEncodeEntered = NO;
    BOOL graphEncodeReturned = NO;
    BOOL unknownRoot = NO;
    mg_error_stage_t failureStage = MG_ERROR_STAGE_ENCODE;
    @try {
        NSMutableArray<MPSGraphTensorData *> *inputs =
            [NSMutableArray arrayWithCapacity:mpsgraph->feed_count];
        NSMutableArray<MPSGraphTensorData *> *results =
            [NSMutableArray arrayWithCapacity:mpsgraph->target_count];
        for (uint32_t i = 0; i < mpsgraph->feed_count; ++i) {
            MPSGraphTensorData *data = mg_mpsgraph_tensor_data(&mpsgraph->feeds[i]);
            if (!data)
                @throw [NSException exceptionWithName:@"MGGraphEncode"
                                               reason:@"failed to create MPSGraph feed"
                                             userInfo:nil];
            [inputs addObject:data];
        }
        for (uint32_t i = 0; i < mpsgraph->target_count; ++i) {
            MPSGraphTensorData *data = mg_mpsgraph_tensor_data(&mpsgraph->targets[i]);
            if (!data)
                @throw [NSException exceptionWithName:@"MGGraphEncode"
                                               reason:@"failed to create MPSGraph target"
                                             userInfo:nil];
            [results addObject:data];
        }
        wrapper = [[MGTrackedMPSCommandBuffer alloc] initWithCommandBuffer:root];
        if (!wrapper)
            @throw [NSException exceptionWithName:@"MGGraphEncode"
                                           reason:@"failed to create MPS wrapper"
                                         userInfo:nil];
        wrapper.job = self;
        wrapper.nodeId = nodeId;
        if (_exec->test_mps_failure == 5) {
            _exec->test_mps_failure = 0;
            @throw [NSException exceptionWithName:@"MGInjectedGraphAllocation"
                                           reason:@"injected MPS descriptor allocation failure"
                                         userInfo:nil];
        }
        MPSGraphExecutableExecutionDescriptor *descriptor =
            [MPSGraphExecutableExecutionDescriptor new];
        if (!descriptor)
            @throw [NSException exceptionWithName:@"MGGraphEncode"
                                           reason:@"failed to create MPS execution descriptor"
                                         userInfo:nil];
        descriptor.waitUntilCompleted = NO;
        BOOL syntheticGraphError = _exec->test_mps_failure == 2;
        BOOL syntheticEncodeThrow = _exec->test_mps_failure == 12;
        BOOL syntheticPartialTail = _exec->test_mps_failure == 13;
        if (syntheticGraphError)
            _exec->test_mps_failure = 0;
        @synchronized(graphUnit) {
            descriptor.completionHandler = ^(NSArray<MPSGraphTensorData *> *values,
                                             NSError *error) {
              (void)values;
              @synchronized(graphUnit) {
              }
              if (syntheticEncodeThrow || syntheticPartialTail)
                  return; /* controlled missing callback token */
              NSError *reported = syntheticGraphError ? [NSError errorWithDomain:@"MGInjectedGraph"
                                                                            code:1
                                                                        userInfo:nil]
                                                      : error;
              [graphUnit finishWithError:reported failed:(reported != nil)];
            };
        }
        while (_exec->test_mps_continuations) {
            --_exec->test_mps_continuations;
            [wrapper commitAndContinue];
        }
        MPSGraphExecutable *executable = (__bridge MPSGraphExecutable *)mpsgraph->executable_impl;
        rootAtEncode = wrapper.rootCommandBuffer;
        graphEncodeEntered = YES;
        [executable encodeToCommandBuffer:wrapper
                              inputsArray:inputs
                             resultsArray:results
                      executionDescriptor:descriptor];
        if (syntheticEncodeThrow) {
            _exec->test_mps_failure = 0;
            [wrapper
                commitAndContinue]; /* model an encode throw after submitting actual graph work */
            __atomic_store_n(&_exec->test_unknown_unit, (__bridge_retained void *)graphUnit,
                             __ATOMIC_RELEASE);
            @throw [NSException exceptionWithName:@"MGInjectedEncodeThrow"
                                           reason:@"synthetic encode exception after submission"
                                         userInfo:nil];
        }
        if (syntheticPartialTail) {
            _exec->test_mps_failure = 0;
            [wrapper
                commitAndContinue]; /* model an internal continuation with an uncommitted tail */
            __atomic_store_n(&_exec->test_unknown_unit, (__bridge_retained void *)graphUnit,
                             __ATOMIC_RELEASE);
            _exec->test_mps_failure = 3;
        }
        graphEncodeReturned = YES;
        finalEncodedRoot = wrapper.rootCommandBuffer;
        id<MTLCommandBuffer> liveRoot = wrapper.rootCommandBuffer;
        if (!liveRoot || ![self knowsGraphRoot:liveRoot]) {
            unknownRoot = YES;
            @throw [NSException exceptionWithName:@"MGUnknownMPSRoot"
                                           reason:@"MPSGraph changed to an untracked root"
                                         userInfo:nil];
        }
        _exec->test_mps_observed_roots = (uint32_t)_stageRoots.count;
        if (_exec->test_mps_failure == 10 || _exec->test_mps_failure == 11) {
            BOOL earlierError = _exec->test_mps_failure == 11;
            _exec->test_mps_failure = 0;
            if (earlierError)
                [self recordFailure:MG_STATUS_BACKEND_ERROR
                              stage:MG_ERROR_STAGE_COMPLETE
                               node:nodeId
                            message:@"synthetic earlier root error"
                            backend:@"synthetic backend detail"];
            __atomic_store_n(&_exec->test_unknown_unit, (__bridge_retained void *)graphUnit,
                             __ATOMIC_RELEASE);
            unknownRoot = YES;
            @throw [NSException exceptionWithName:@"MGInjectedUnknownRoot"
                                           reason:@"synthetic unknown submission"
                                         userInfo:nil];
        }
        if (_exec->test_mps_failure == 8 || _exec->test_mps_failure == 9) {
            uint8_t mode = _exec->test_mps_failure;
            _exec->test_mps_failure = mode == 8 ? 1 : 0;
            [wrapper
                commitAndContinue]; /* test-only: the retired root contains encoded graph work */
            if (mode == 9)
                _exec->test_mps_failure = 3;
        }
        failureStage = MG_ERROR_STAGE_COMMIT;
        if (_exec->test_mps_failure == 3) {
            _exec->test_mps_failure = 0;
            @throw [NSException exceptionWithName:@"MGInjectedGraphCommit"
                                           reason:@"injected failure before final MPS commit"
                                         userInfo:nil];
        }
        [wrapper commit];
        if (_exec->test_mps_failure == 4) {
            _exec->test_mps_failure = 0;
            [self recordFailure:MG_STATUS_BACKEND_ERROR
                          stage:MG_ERROR_STAGE_COMMIT
                           node:nodeId
                        message:@"injected failure after final MPS commit"
                        backend:nil];
        }
        ++_index;
    } @catch (NSException *exception) {
        if (wrapper &&
            (![self knowsGraphRoot:wrapper.rootCommandBuffer] || !wrapper.rootCommandBuffer)) {
            id<MTLCommandBuffer> current = wrapper.rootCommandBuffer;
            BOOL provenFresh = current && current == wrapper.unregisteredFreshRoot &&
                               (current.status == MTLCommandBufferStatusNotEnqueued ||
                                current.status == MTLCommandBufferStatusEnqueued);
            if (!provenFresh)
                unknownRoot = YES;
        }
        MTLCommandBufferStatus encodedStatus =
            rootAtEncode ? rootAtEncode.status : MTLCommandBufferStatusNotEnqueued;
        BOOL graphMayHaveSubmitted = graphEncodeEntered && rootAtEncode &&
                                     encodedStatus != MTLCommandBufferStatusNotEnqueued &&
                                     encodedStatus != MTLCommandBufferStatusEnqueued;
        if (!graphEncodeReturned && graphMayHaveSubmitted)
            unknownRoot = YES;
        MTLCommandBufferStatus tailStatus =
            finalEncodedRoot ? finalEncodedRoot.status : MTLCommandBufferStatusNotEnqueued;
        if (graphEncodeReturned && graphMayHaveSubmitted && finalEncodedRoot &&
            (tailStatus == MTLCommandBufferStatusNotEnqueued ||
             tailStatus == MTLCommandBufferStatusEnqueued))
            unknownRoot = YES;
        [self recordFailure:(unknownRoot ? MG_STATUS_UNSUPPORTED : MG_STATUS_BACKEND_ERROR)
                      stage:failureStage
                       node:nodeId
                    message:@"failed to encode or commit MPSGraph segment"
                    backend:exception.reason];
        if (unknownRoot)
            [_tracker markAccountingFailure:nodeId stage:failureStage];
        [self cancelKnownUncommittedRoots];
        if (!unknownRoot && !graphMayHaveSubmitted)
            [graphUnit finish];
        /* Unknown roots deliberately retain the graph unit; callback may retire it, but
         * absent a callback the state remains fail-closed rather than releasing live owners. */
    }
    [_tracker seal];
#else
    [self recordFailure:MG_STATUS_UNSUPPORTED
                  stage:MG_ERROR_STAGE_ENCODE
                   node:mg_exec_node_id(&_exec->nodes[_index])
                message:@"MPSGraph support disabled"
                backend:nil];
    [self finishJob];
#endif
}
- (void)advance {
    if (_terminal)
        return;
    if (_index < _exec->node_count && _exec->nodes[_index].kind == MG_NODE_MPSGRAPH) {
        [self runGraphStage];
        return;
    }
    if (_index >= _exec->node_count && (_exec->node_count != 0 || _emptySubmitted)) {
        [self finishJob];
        return;
    }
    if (_exec->node_count == 0)
        _emptySubmitted = YES;
    id<MTLCommandBuffer> buffer = [_queue commandBuffer];
    if (!buffer) {
        [self recordFailure:MG_STATUS_BACKEND_ERROR
                      stage:MG_ERROR_STAGE_ENCODE
                       node:MG_NODE_ID_INVALID
                    message:@"failed to create Metal command buffer"
                    backend:nil];
        [self finishJob];
        return;
    }
    BOOL hasWork = _exec->node_count == 0;
    BOOL fenceUpdated = NO;
    mg_node_id_t stageNode = MG_NODE_ID_INVALID;
    @try {
        bool useICB = !_manualHazards && _index == 0 && _exec->icb.backend_impl &&
                      (_exec->icb.enabled_flags & MG_OPTIMIZATION_ICB);
        if (useICB) {
            id<MTLComputeCommandEncoder> encoder = [buffer computeCommandEncoder];
            if (!encoder)
                @throw [NSException exceptionWithName:@"MGEncode"
                                               reason:@"failed to create ICB encoder"
                                             userInfo:nil];
            id<MTLIndirectCommandBuffer> icb =
                (__bridge id<MTLIndirectCommandBuffer>)_exec->icb.backend_impl;
            [encoder executeCommandsInBuffer:icb
                                   withRange:NSMakeRange(0, _exec->icb.command_count)];
            [encoder endEncoding];
            _index = _exec->node_count;
            hasWork = YES;
        } else {
            while (_index < _exec->node_count && _exec->nodes[_index].kind != MG_NODE_MPSGRAPH) {
                mg_exec_node_t *node = &_exec->nodes[_index++];
                stageNode = mg_exec_node_id(node);
                switch (node->kind) {
                case MG_NODE_DISPATCH: {
                    mg_exec_dispatch_t *d = &node->as.dispatch;
                    id<MTLComputeCommandEncoder> encoder = [buffer computeCommandEncoder];
                    if (!encoder)
                        @throw [NSException exceptionWithName:@"MGEncode"
                                                       reason:@"failed to create compute encoder"
                                                     userInfo:nil];
                    if (_passFence && fenceUpdated)
                        [encoder waitForFence:_passFence];
                    [encoder setComputePipelineState:(__bridge id<MTLComputePipelineState>)d->
                                                     pipeline_impl];
                    for (uint32_t j = 0; j < d->buffer_count; ++j)
                        [encoder setBuffer:(__bridge id<MTLBuffer>)d->buffers[j].buffer->impl
                                    offset:mg_metal_buffer_offset(d->buffers[j].buffer,
                                                                  d->buffers[j].offset)
                                   atIndex:d->buffers[j].index];
                    for (uint32_t j = 0; j < d->scalar_count; ++j)
                        [encoder setBytes:d->scalars[j].data
                                   length:d->scalars[j].byte_count
                                  atIndex:d->scalars[j].index];
                    [encoder dispatchThreads:MTLSizeMake(d->grid_size[0], d->grid_size[1],
                                                         d->grid_size[2])
                        threadsPerThreadgroup:MTLSizeMake(d->threads_per_threadgroup[0],
                                                          d->threads_per_threadgroup[1],
                                                          d->threads_per_threadgroup[2])];
                    if (_passFence) {
                        [encoder updateFence:_passFence];
                        fenceUpdated = YES;
                    }
                    [encoder endEncoding];
                    hasWork = YES;
                    break;
                }
                case MG_NODE_COPY: {
                    mg_exec_copy_t *c = &node->as.copy;
                    id<MTLBlitCommandEncoder> encoder = [buffer blitCommandEncoder];
                    if (!encoder)
                        @throw [NSException exceptionWithName:@"MGEncode"
                                                       reason:@"failed to create copy encoder"
                                                     userInfo:nil];
                    if (_passFence && fenceUpdated)
                        [encoder waitForFence:_passFence];
                    [encoder copyFromBuffer:(__bridge id<MTLBuffer>)c->src->impl
                               sourceOffset:mg_metal_buffer_offset(c->src, c->src_offset)
                                   toBuffer:(__bridge id<MTLBuffer>)c->dst->impl
                          destinationOffset:mg_metal_buffer_offset(c->dst, c->dst_offset)
                                       size:c->byte_count];
                    if (_passFence) {
                        [encoder updateFence:_passFence];
                        fenceUpdated = YES;
                    }
                    [encoder endEncoding];
                    hasWork = YES;
                    break;
                }
                case MG_NODE_FILL: {
                    mg_exec_fill_t *f = &node->as.fill;
                    id<MTLBlitCommandEncoder> encoder = [buffer blitCommandEncoder];
                    if (!encoder)
                        @throw [NSException exceptionWithName:@"MGEncode"
                                                       reason:@"failed to create fill encoder"
                                                     userInfo:nil];
                    if (_passFence && fenceUpdated)
                        [encoder waitForFence:_passFence];
                    [encoder fillBuffer:(__bridge id<MTLBuffer>)f->dst->impl
                                  range:NSMakeRange(mg_metal_buffer_offset(f->dst, f->dst_offset),
                                                    f->byte_count)
                                  value:f->value];
                    if (_passFence) {
                        [encoder updateFence:_passFence];
                        fenceUpdated = YES;
                    }
                    [encoder endEncoding];
                    hasWork = YES;
                    break;
                }
                case MG_NODE_EVENT_WAIT:
                case MG_NODE_EVENT_SIGNAL: {
                    id<MTLSharedEvent> event =
                        (__bridge id<MTLSharedEvent>)node->as.event.event->impl;
                    if (node->kind == MG_NODE_EVENT_WAIT)
                        [buffer encodeWaitForEvent:event value:node->as.event.value];
                    else
                        [buffer encodeSignalEvent:event value:node->as.event.value];
                    hasWork = YES;
                    break;
                }
                case MG_NODE_BARRIER:
                    break;
                default:
                    if ((int)node->kind == MG_NODE_INTERNAL_WORKSPACE)
                        break;
                    if ((int)node->kind == MG_NODE_INTERNAL_WORKSPACE_FILL) {
                        mg_exec_workspace_fill_t *w = &node->as.workspace_fill;
                        id<MTLBlitCommandEncoder> encoder = [buffer blitCommandEncoder];
                        if (!encoder)
                            @throw
                                [NSException exceptionWithName:@"MGEncode"
                                                        reason:@"failed to create workspace encoder"
                                                      userInfo:nil];
                        if (_passFence && fenceUpdated)
                            [encoder waitForFence:_passFence];
                        id<MTLBuffer> workspace =
                            (__bridge id<MTLBuffer>)_exec->workspace.backend_impl;
                        [encoder fillBuffer:workspace
                                      range:NSMakeRange(w->offset, w->size)
                                      value:w->value];
                        if (_passFence) {
                            [encoder updateFence:_passFence];
                            fenceUpdated = YES;
                            [encoder endEncoding];
                            encoder = [buffer blitCommandEncoder];
                            if (!encoder)
                                @throw [NSException
                                    exceptionWithName:@"MGEncode"
                                               reason:@"failed to create workspace copy encoder"
                                             userInfo:nil];
                            [encoder waitForFence:_passFence];
                        }
                        [encoder copyFromBuffer:workspace
                                   sourceOffset:w->offset
                                       toBuffer:(__bridge id<MTLBuffer>)w->dst->impl
                              destinationOffset:mg_metal_buffer_offset(w->dst, w->dst_offset)
                                           size:w->size];
                        if (_passFence) {
                            [encoder updateFence:_passFence];
                            fenceUpdated = YES;
                        }
                        [encoder endEncoding];
                        hasWork = YES;
                        break;
                    }
                    @throw [NSException exceptionWithName:@"MGEncode"
                                                   reason:@"unknown executable node kind"
                                                 userInfo:nil];
                }
            }
        }
    } @catch (NSException *exception) {
        [self recordFailure:MG_STATUS_BACKEND_ERROR
                      stage:MG_ERROR_STAGE_ENCODE
                       node:stageNode
                    message:@"failed to encode raw segment"
                    backend:exception.reason];
        [self finishJob];
        return;
    }
    if (!hasWork) {
        [self advance];
        return;
    }
    [self beginStage];
    MGLaunchCompletionUnit *unit = nil;
    @try {
        [_stageRoots addObject:buffer];
        unit = [_tracker registerCommandBuffer:buffer node:MG_NODE_ID_INVALID syntheticError:NO];
        if (!unit)
            @throw [NSException exceptionWithName:@"MGRegistration"
                                           reason:@"failed to register completion handler"
                                         userInfo:nil];
    } @catch (NSException *exception) {
        [self recordFailure:MG_STATUS_BACKEND_ERROR
                      stage:MG_ERROR_STAGE_ENCODE
                       node:stageNode
                    message:@"failed to prepare raw command buffer"
                    backend:exception.reason];
        [_tracker seal];
        return;
    } @
    try {
        if (_exec->test_raw_failure == 1) {
            _exec->test_raw_failure = 0;
            @throw [NSException exceptionWithName:@"MGInjectedCommitFailure"
                                           reason:@"injected failure before raw commit"
                                         userInfo:nil];
        }
        [buffer commit];
    } @catch (NSException *exception) {
        MTLCommandBufferStatus status = buffer.status;
        if (status == MTLCommandBufferStatusNotEnqueued || status == MTLCommandBufferStatusEnqueued)
            [unit finish];
        [self recordFailure:MG_STATUS_BACKEND_ERROR
                      stage:MG_ERROR_STAGE_COMMIT
                       node:stageNode
                    message:@"failed to commit raw command buffer"
                    backend:exception.reason];
        [_tracker seal];
        return;
    }
    if (_exec->test_raw_failure == 2) {
        _exec->test_raw_failure = 0;
        [self recordFailure:MG_STATUS_BACKEND_ERROR
                      stage:MG_ERROR_STAGE_COMMIT
                       node:stageNode
                    message:@"injected failure after raw commit"
                    backend:nil];
    }
    [_tracker seal];
}
- (void)advanceSafely {
    @try {
        [self advance];
    } @catch (NSException *exception) {
        mg_node_id_t node = _index < _exec->node_count ? mg_exec_node_id(&_exec->nodes[_index])
                                                       : MG_NODE_ID_INVALID;
        [self recordFailure:MG_STATUS_BACKEND_ERROR
                      stage:MG_ERROR_STAGE_ENCODE
                       node:node
                    message:@"unexpected deferred encoding failure"
                    backend:exception.reason];
        if (_stageOpen)
            [_tracker seal];
        else
            [self finishJob];
    }
}
- (void)failBeforeStart:(NSException *)exception {
    [self recordFailure:MG_STATUS_OUT_OF_MEMORY
                  stage:MG_ERROR_STAGE_ENCODE
                   node:MG_NODE_ID_INVALID
                message:@"failed to enqueue accepted job"
                backend:exception.reason];
    [self finishJob];
}
- (void)startWithCompletion:(dispatch_block_t)done onQueue:(dispatch_queue_t)queue {
    @try {
        _done = [done copy];
    } @catch (NSException *exception) {
        [self failBeforeStart:exception];
        done();
        return;
    }
    _schedulerQueue = queue;
    [self advanceSafely];
}
@end

/* Snapshot original graph resources for the lifetime of the returned launch handle.
 * A terminal exec can be patched while an older unsynchronized handle is still live. */
static mg_status_t mg_snapshot_launch_resources(mg_graph_exec_t *exec, mg_launch_t *launch,
                                                mg_error_t **outError) {
    size_t buffers = 0, events = 0;
    for (size_t i = 0; i < exec->node_count; ++i) {
        mg_exec_node_t *node = &exec->nodes[i];
        size_t add = 0;
        switch (node->kind) {
        case MG_NODE_DISPATCH:
            add = node->as.dispatch.buffer_count;
            break;
        case MG_NODE_COPY:
            add = 2;
            break;
        case MG_NODE_FILL:
            add = 1;
            break;
        case MG_NODE_EVENT_WAIT:
        case MG_NODE_EVENT_SIGNAL:
            if (events == SIZE_MAX)
                return mg_set_oom(outError, MG_ERROR_STAGE_ENCODE);
            ++events;
            break;
        case MG_NODE_MPSGRAPH:
            add = (size_t)node->as.mpsgraph.feed_count + (size_t)node->as.mpsgraph.target_count;
            break;
        default:
            if ((int)node->kind == MG_NODE_INTERNAL_WORKSPACE_FILL)
                add = 1;
            break;
        }
        if (add > SIZE_MAX - buffers)
            return mg_set_oom(outError, MG_ERROR_STAGE_ENCODE);
        buffers += add;
    }
    if (buffers > SIZE_MAX / sizeof(*launch->retained_buffers) ||
        events > SIZE_MAX / sizeof(*launch->retained_events))
        return mg_set_oom(outError, MG_ERROR_STAGE_ENCODE);
    if (buffers && !(launch->retained_buffers =
                         (mg_buffer_t **)calloc(buffers, sizeof(*launch->retained_buffers))))
        return mg_set_oom(outError, MG_ERROR_STAGE_ENCODE);
    if (events && !(launch->retained_events =
                        (mg_event_t **)calloc(events, sizeof(*launch->retained_events))))
        return mg_set_oom(outError, MG_ERROR_STAGE_ENCODE);
#define MG_SNAPSHOT_BUFFER(value)                                                                  \
    do {                                                                                           \
        mg_buffer_t *b = (value);                                                                  \
        mg_buffer_retain(b);                                                                       \
        launch->retained_buffers[launch->retained_buffer_count++] = b;                             \
    } while (0)
    for (size_t i = 0; i < exec->node_count; ++i) {
        mg_exec_node_t *node = &exec->nodes[i];
        switch (node->kind) {
        case MG_NODE_DISPATCH:
            for (uint32_t j = 0; j < node->as.dispatch.buffer_count; ++j)
                MG_SNAPSHOT_BUFFER(node->as.dispatch.buffers[j].buffer);
            break;
        case MG_NODE_COPY:
            MG_SNAPSHOT_BUFFER(node->as.copy.src);
            MG_SNAPSHOT_BUFFER(node->as.copy.dst);
            break;
        case MG_NODE_FILL:
            MG_SNAPSHOT_BUFFER(node->as.fill.dst);
            break;
        case MG_NODE_EVENT_WAIT:
        case MG_NODE_EVENT_SIGNAL:
            mg_event_retain(node->as.event.event);
            launch->retained_events[launch->retained_event_count++] = node->as.event.event;
            break;
        case MG_NODE_MPSGRAPH:
            for (uint32_t j = 0; j < node->as.mpsgraph.feed_count; ++j)
                MG_SNAPSHOT_BUFFER(node->as.mpsgraph.feeds[j].buffer);
            for (uint32_t j = 0; j < node->as.mpsgraph.target_count; ++j)
                MG_SNAPSHOT_BUFFER(node->as.mpsgraph.targets[j].buffer);
            break;
        default:
            if ((int)node->kind == MG_NODE_INTERNAL_WORKSPACE_FILL)
                MG_SNAPSHOT_BUFFER(node->as.workspace_fill.dst);
            break;
        }
    }
#undef MG_SNAPSHOT_BUFFER
    return MG_STATUS_OK;
}

mg_status_t mgGraphLaunch(mg_graph_exec_t *exec, mg_stream_t *stream, mg_launch_t **out_launch,
                          mg_error_t **out_error) {
    mg_clear_error(out_error);
    if (!exec || !stream || !stream->impl || !stream->scheduler_impl || !out_launch)
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_ENCODE,
                            MG_NODE_ID_INVALID, "exec, stream, and out_launch are required", NULL);
    *out_launch = NULL;
    if (__atomic_load_n(&exec->ref_count, __ATOMIC_ACQUIRE) == UINT32_MAX)
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_ENCODE,
                            MG_NODE_ID_INVALID, "exec launch ownership limit reached", NULL);
    uint32_t expected = 0;
    if (!__atomic_compare_exchange_n(&exec->in_flight_count, &expected, 1, false, __ATOMIC_ACQ_REL,
                                     __ATOMIC_ACQUIRE))
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_ENCODE,
                            MG_NODE_ID_INVALID, "exec has an in-flight launch", NULL);
    mg_launch_t *launch = (mg_launch_t *)calloc(1, sizeof(*launch));
    if (!launch) {
        __atomic_store_n(&exec->in_flight_count, 0, __ATOMIC_RELEASE);
        return mg_set_oom(out_error, MG_ERROR_STAGE_ENCODE);
    }
    mg_status_t snapshotStatus = mg_snapshot_launch_resources(exec, launch, out_error);
    if (snapshotStatus != MG_STATUS_OK) {
        mg_backend_launch_destroy(launch);
        free(launch->retained_buffers);
        free(launch->retained_events);
        free(launch);
        __atomic_store_n(&exec->in_flight_count, 0, __ATOMIC_RELEASE);
        return snapshotStatus;
    }
    id<MTLCommandQueue> queue = (__bridge id<MTLCommandQueue>)stream->impl;
    size_t manualPasses = 0;
    bool manualHazards = false;
    BOOL metadataOK = YES;
    @try {
        if (exec->test_preflight_failure == 1) {
            exec->test_preflight_failure = 0;
            @throw [NSException exceptionWithName:@"MGInjectedMetadata"
                                           reason:@"synthetic native metadata failure"
                                         userInfo:nil];
        }
        manualHazards = mg_exec_manual_hazards(exec, &manualPasses);
    } @catch (NSException *exception) {
        (void)exception;
        metadataOK = NO;
    }
    if (!metadataOK) {
        __atomic_store_n(&exec->in_flight_count, 0, __ATOMIC_RELEASE);
        mg_backend_launch_destroy(launch);
        free(launch->retained_buffers);
        free(launch->retained_events);
        free(launch);
        return mg_set_error(out_error, MG_STATUS_BACKEND_ERROR, MG_ERROR_STAGE_ENCODE,
                            MG_NODE_ID_INVALID, "failed to inspect resource hazard metadata", NULL);
    }
    id<MTLFence> passFence = nil;
    if (manualHazards && manualPasses > 1) {
        @try {
            if (!exec->test_fence_failure)
                passFence = [queue.device newFence];
        } @catch (NSException *exception) {
            (void)exception;
        }
        exec->test_fence_failure = 0;
        if (!passFence) {
            __atomic_store_n(&exec->in_flight_count, 0, __ATOMIC_RELEASE);
            mg_backend_launch_destroy(launch);
            free(launch->retained_buffers);
            free(launch->retained_events);
            free(launch);
            return mg_set_error(out_error, MG_STATUS_BACKEND_ERROR, MG_ERROR_STAGE_ENCODE,
                                MG_NODE_ID_INVALID, "failed to create manual hazard fence", NULL);
        }
    }
    MGLaunchCompletionTracker *tracker = nil;
    MGAsyncJob *job = nil;
    @try {
        tracker = [[MGLaunchCompletionTracker alloc] initWithExec:exec queue:queue];
        job = tracker ? [[MGAsyncJob alloc] initWithExec:exec tracker:tracker queue:queue] : nil;
    } @catch (NSException *exception) {
        (void)exception;
        job = nil;
    }
    if (!tracker || !job) {
        __atomic_store_n(&exec->in_flight_count, 0, __ATOMIC_RELEASE);
        mg_backend_launch_destroy(launch);
        free(launch->retained_buffers);
        free(launch->retained_events);
        free(launch);
        return mg_set_oom(out_error, MG_ERROR_STAGE_ENCODE);
    }
    job.manualHazards = manualHazards;
    job.passFence = passFence;
    [tracker activateJob];
    launch->exec = exec;
    launch->tracker_impl = (__bridge_retained void *)tracker;
    launch->async_job = true;
    /* These immutable diagnostics describe ordering requested by the accepted graph. */
    for (size_t i = 0; i < exec->node_count; ++i) {
        if (exec->nodes[i].kind == MG_NODE_EVENT_WAIT) {
            launch->event_wait_count++;
            launch->sync_mode_flags |= MG_SYNC_MODE_EVENT_WAIT;
        } else if (exec->nodes[i].kind == MG_NODE_EVENT_SIGNAL) {
            launch->event_signal_count++;
            launch->sync_mode_flags |= MG_SYNC_MODE_EVENT_SIGNAL;
        }
    }
    MGStreamScheduler *scheduler = (__bridge MGStreamScheduler *)stream->scheduler_impl;
    MGHazardDomain *queueDomain = nil;
    @try {
        queueDomain = mg_hazard_domain(queue);
    } @catch (NSException *exception) {
        (void)exception;
    }
    if (!queueDomain) {
        [job failBeforeStart:nil];
        mgLaunchDestroy(launch);
        return mg_set_oom(out_error, MG_ERROR_STAGE_ENCODE);
    }
    MGQueueGuard queueGuard;
    BOOL gateAcquired = NO;
    @try {
        if (exec->test_preflight_failure == 2) {
            exec->test_preflight_failure = 0;
            @throw [NSException exceptionWithName:@"MGInjectedGate"
                                           reason:@"synthetic queue gate failure"
                                         userInfo:nil];
        }
        queueGuard.acquire(queueDomain.gate);
        gateAcquired = YES;
    } @catch (NSException *exception) {
        (void)exception;
    }
    if (!gateAcquired) {
        [job failBeforeStart:nil];
        mgLaunchDestroy(launch);
        return mg_set_error(out_error, MG_STATUS_BACKEND_ERROR, MG_ERROR_STAGE_ENCODE,
                            MG_NODE_ID_INVALID, "failed to acquire queue admission gate", NULL);
    }
    bool conflict = false;
    MGHazardSnapshot *hazards = nil;
    @autoreleasepool {
        hazards = mg_hazard_admit(exec, queue, scheduler, &conflict);
    }
    if (!hazards || conflict) {
        queueGuard.release();
        [job failBeforeStart:nil];
        mgLaunchDestroy(launch);
        return mg_set_error(
            out_error, conflict ? MG_STATUS_INVALID_ARGUMENT : MG_STATUS_BACKEND_ERROR,
            MG_ERROR_STAGE_ENCODE, MG_NODE_ID_INVALID,
            conflict ? "overlapping active writer requires ordering" : "hazard admission failed",
            NULL);
    }
    [tracker setHazards:hazards];
    @try {
        [scheduler enqueue:job];
    } @catch (NSException *exception) {
        /* No scheduler block was accepted if enqueue itself throws. */
        queueGuard.release();
        [job failBeforeStart:exception];
        mgLaunchDestroy(launch);
        return mg_set_error(out_error, MG_STATUS_BACKEND_ERROR, MG_ERROR_STAGE_ENCODE,
                            MG_NODE_ID_INVALID, "failed to enqueue launch", NULL);
    }
    if (exec->icb.groups_planned > 0) {
        if (!(exec->icb.enabled_flags & MG_OPTIMIZATION_ICB)) {
            __atomic_store_n(&exec->icb.groups_used, 0, __ATOMIC_RELEASE);
            __atomic_store_n(&exec->icb.groups_fallback, exec->icb.groups_planned,
                             __ATOMIC_RELEASE);
            __atomic_store_n(&exec->icb.last_fallback_reason, MG_ICB_FALLBACK_DISABLED,
                             __ATOMIC_RELEASE);
        } else if (exec->icb.backend_impl && manualHazards) {
            __atomic_store_n(&exec->icb.groups_used, 0, __ATOMIC_RELEASE);
            __atomic_store_n(&exec->icb.groups_fallback, exec->icb.groups_planned,
                             __ATOMIC_RELEASE);
            __atomic_store_n(&exec->icb.last_fallback_reason, MG_ICB_FALLBACK_MANUAL_HAZARDS,
                             __ATOMIC_RELEASE);
        } else if (exec->icb.backend_impl) {
            __atomic_store_n(&exec->icb.groups_used, exec->icb.groups_planned, __ATOMIC_RELEASE);
            __atomic_store_n(&exec->icb.groups_fallback, 0, __ATOMIC_RELEASE);
            __atomic_store_n(&exec->icb.last_fallback_reason, MG_ICB_FALLBACK_NONE,
                             __ATOMIC_RELEASE);
        } else {
            __atomic_store_n(&exec->icb.groups_used, 0, __ATOMIC_RELEASE);
            __atomic_store_n(&exec->icb.groups_fallback, exec->icb.groups_planned,
                             __ATOMIC_RELEASE);
        }
    }
    queueGuard.release();
    *out_launch = launch;
    return MG_STATUS_OK;
}

mg_status_t mgLaunchSynchronize(mg_launch_t *launch, mg_error_t **out_error) {
    mg_clear_error(out_error);
    if (!launch || (launch->impl_count == 0 && !launch->exec)) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_SYNC,
                            MG_NODE_ID_INVALID, "launch is required", NULL);
    }

    launch->synchronize_count++;
    launch->sync_mode_flags |= MG_SYNC_MODE_LAUNCH_SYNCHRONIZE;
    if (launch->async_job) {
        MGLaunchCompletionTracker *tracker =
            (__bridge MGLaunchCompletionTracker *)launch->tracker_impl;
        if ([tracker waitForTerminal])
            launch->completed = true;
        return [tracker copyFailure:out_error];
    }

    mg_status_t status = MG_STATUS_OK;
    for (size_t i = 0; i < launch->impl_count; ++i) {
        id<MTLCommandBuffer> commandBuffer = (__bridge id<MTLCommandBuffer>)launch->impls[i];
        [commandBuffer waitUntilCompleted];
        if (commandBuffer.status == MTLCommandBufferStatusError && status == MG_STATUS_OK) {
            status = mg_set_error(out_error, MG_STATUS_BACKEND_ERROR, MG_ERROR_STAGE_COMPLETE,
                                  MG_NODE_ID_INVALID, "Metal command buffer failed",
                                  mg_ns_error_message(commandBuffer.error));
        }
    }
    if (!launch->completed) {
        if (launch->tracker_impl) {
            MGLaunchCompletionTracker *tracker =
                (__bridge MGLaunchCompletionTracker *)launch->tracker_impl;
            [tracker acknowledge];
        } else if (launch->exec &&
                   __atomic_load_n(&launch->exec->in_flight_count, __ATOMIC_ACQUIRE) > 0) {
            __atomic_fetch_sub(&launch->exec->in_flight_count, 1, __ATOMIC_ACQ_REL);
        }
        launch->completed = true;
    }
    return status;
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

    for (size_t i = 0; launch->impls && i < launch->impl_count; ++i) {
        id commandBuffer = (__bridge_transfer id)launch->impls[i];
        (void)commandBuffer;
    }
    launch->impl = NULL;
    launch->impl_count = 0;
    if (launch->retained_workspace_impl) {
        id workspace = (__bridge_transfer id)launch->retained_workspace_impl;
        (void)workspace;
        launch->retained_workspace_impl = NULL;
    }
}

/* Only raw Metal command buffers have a fully tracked completion boundary here. */
static bool mg_launch_is_completed_raw(const mg_launch_t *launch) {
    if (!launch->exec || (launch->impl_count && !launch->impls))
        return false;
    for (size_t i = 0; i < launch->exec->node_count; ++i)
        if (launch->exec->nodes[i].kind == MG_NODE_MPSGRAPH)
            return false;
    for (size_t i = 0; i < launch->impl_count; ++i) {
        id<MTLCommandBuffer> commandBuffer = (__bridge id<MTLCommandBuffer>)launch->impls[i];
        if (!commandBuffer || commandBuffer.status != MTLCommandBufferStatusCompleted)
            return false;
    }
    return true;
}

void mgLaunchDestroy(mg_launch_t *launch) {
    if (!launch) {
        return;
    }
    mg_graph_exec_t *exec = launch->exec;
    MGLaunchCompletionTracker *tracker =
        (__bridge_transfer MGLaunchCompletionTracker *)launch->tracker_impl;
    launch->tracker_impl = NULL;
    if (launch->async_job) {
        mg_backend_launch_destroy(launch);
        free(launch->retained_buffers);
        free(launch->retained_events);
        free(launch);
        return;
    }
    if (tracker) {
        [tracker seal];
        if (mg_launch_is_completed_raw(launch))
            [tracker acknowledge];
        else
            [tracker acknowledgeIfUnsubmitted];
    } else if (exec && !launch->completed && mg_launch_is_completed_raw(launch)) {
        if (__atomic_load_n(&exec->in_flight_count, __ATOMIC_ACQUIRE) > 0)
            __atomic_fetch_sub(&exec->in_flight_count, 1, __ATOMIC_ACQ_REL);
        launch->completed = true;
    }
    mg_backend_launch_destroy(launch);
    free(launch->impls);
    free(launch->retained_buffers);
    free(launch->retained_events);
    free(launch);
    if (!tracker)
        mg_exec_release(exec);
}
