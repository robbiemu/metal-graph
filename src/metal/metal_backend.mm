#include "../core/internal.h"
#include "metal_graph/metal_graph_metal.h"

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#if MG_ENABLE_MPSGRAPH
#import <MetalPerformanceShadersGraph/MetalPerformanceShadersGraph.h>
#endif

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

static mg_status_t mg_mpsgraph_encode_node(mg_exec_mpsgraph_t *mpsgraph,
                                           id<MTLCommandBuffer> commandBuffer,
                                           mg_error_t **out_error) {
#if MG_ENABLE_MPSGRAPH
    if (!mpsgraph->executable_impl) {
        return mg_set_error(out_error, MG_STATUS_BACKEND_ERROR, MG_ERROR_STAGE_ENCODE, mpsgraph->id,
                            "MPSGraph executable is not loaded", NULL);
    }

    NSMutableArray<MPSGraphTensorData *> *inputs =
        [NSMutableArray arrayWithCapacity:mpsgraph->feed_count];
    NSMutableArray<MPSGraphTensorData *> *results =
        [NSMutableArray arrayWithCapacity:mpsgraph->target_count];
    for (uint32_t i = 0; i < mpsgraph->feed_count; ++i) {
        MPSGraphTensorData *data = mg_mpsgraph_tensor_data(&mpsgraph->feeds[i]);
        if (!data) {
            return mg_set_error(out_error, MG_STATUS_BACKEND_ERROR, MG_ERROR_STAGE_ENCODE,
                                mpsgraph->id, "failed to create MPSGraph feed tensor data", NULL);
        }
        [inputs addObject:data];
    }
    for (uint32_t i = 0; i < mpsgraph->target_count; ++i) {
        MPSGraphTensorData *data = mg_mpsgraph_tensor_data(&mpsgraph->targets[i]);
        if (!data) {
            return mg_set_error(out_error, MG_STATUS_BACKEND_ERROR, MG_ERROR_STAGE_ENCODE,
                                mpsgraph->id, "failed to create MPSGraph target tensor data", NULL);
        }
        [results addObject:data];
    }

    MPSCommandBuffer *mpsCommandBuffer =
        [MPSCommandBuffer commandBufferWithCommandBuffer:commandBuffer];
    MPSGraphExecutable *executable = (__bridge MPSGraphExecutable *)mpsgraph->executable_impl;
    @try {
        [executable encodeToCommandBuffer:mpsCommandBuffer
                              inputsArray:inputs
                             resultsArray:results
                      executionDescriptor:nil];
    } @catch (NSException *exception) {
        return mg_set_error(out_error, MG_STATUS_BACKEND_ERROR, MG_ERROR_STAGE_ENCODE, mpsgraph->id,
                            "failed to encode MPSGraph executable",
                            [[exception reason] UTF8String]);
    }
    return MG_STATUS_OK;
#else
    (void)mpsgraph;
    (void)commandBuffer;
    return mg_set_error(out_error, MG_STATUS_UNSUPPORTED, MG_ERROR_STAGE_ENCODE,
                        mpsgraph ? mpsgraph->id : MG_NODE_ID_INVALID,
                        "MPSGraph support is not enabled in this build", NULL);
#endif
}

static mg_status_t mg_launch_retain_command_buffer(mg_launch_t *launch,
                                                   id<MTLCommandBuffer> commandBuffer,
                                                   mg_error_t **out_error) {
    if (launch->impl_count == launch->impl_capacity) {
        size_t next_capacity = launch->impl_capacity ? launch->impl_capacity * 2 : 4;
        void **impls = (void **)realloc(launch->impls, next_capacity * sizeof(*impls));
        if (!impls) {
            return mg_set_oom(out_error, MG_ERROR_STAGE_ENCODE);
        }
        launch->impls = impls;
        launch->impl_capacity = next_capacity;
    }

    void *retained = (__bridge_retained void *)commandBuffer;
    launch->impls[launch->impl_count++] = retained;
    if (!launch->impl) {
        launch->impl = retained;
    }
    return MG_STATUS_OK;
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
        case MG_NODE_MPSGRAPH:
            retainedCount += exec->nodes[i].as.mpsgraph.feed_count;
            retainedCount += exec->nodes[i].as.mpsgraph.target_count;
            break;
        default:
            if ((int)exec->nodes[i].kind == MG_NODE_INTERNAL_WORKSPACE_FILL) {
                retainedCount += 1;
            }
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

    if (exec->workspace.backend_impl) {
        id workspace = (__bridge id)exec->workspace.backend_impl;
        launch->retained_workspace_impl = (__bridge_retained void *)workspace;
    }

    bool useICB = exec->icb.backend_impl && (exec->icb.enabled_flags & MG_OPTIMIZATION_ICB);
    if (exec->icb.groups_planned > 0) {
        exec->icb.groups_used = 0;
        exec->icb.groups_fallback = 0;
        if (!(exec->icb.enabled_flags & MG_OPTIMIZATION_ICB)) {
            exec->icb.groups_fallback = exec->icb.groups_planned;
            exec->icb.last_fallback_reason = MG_ICB_FALLBACK_DISABLED;
        } else if (!exec->icb.backend_impl) {
            exec->icb.groups_fallback = exec->icb.groups_planned;
            if (exec->icb.last_fallback_reason == MG_ICB_FALLBACK_NONE) {
                exec->icb.last_fallback_reason = MG_ICB_FALLBACK_UNSUPPORTED;
            }
        }
    }

    if (useICB) {
        id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];
        if (!encoder) {
            mgLaunchDestroy(launch);
            return mg_set_error(out_error, MG_STATUS_BACKEND_ERROR, MG_ERROR_STAGE_ENCODE,
                                MG_NODE_ID_INVALID, "failed to create Metal ICB compute encoder",
                                NULL);
        }
        id<MTLIndirectCommandBuffer> icb =
            (__bridge id<MTLIndirectCommandBuffer>)exec->icb.backend_impl;
        [encoder executeCommandsInBuffer:icb withRange:NSMakeRange(0, exec->icb.command_count)];
        [encoder endEncoding];
        for (size_t i = 0; i < exec->node_count; ++i) {
            mg_exec_dispatch_t *dispatch = &exec->nodes[i].as.dispatch;
            for (uint32_t j = 0; j < dispatch->buffer_count; ++j) {
                mg_buffer_t *buffer = dispatch->buffers[j].buffer;
                mg_buffer_retain(buffer);
                launch->retained_buffers[launch->retained_buffer_count++] = buffer;
            }
        }
        exec->icb.groups_used = exec->icb.groups_planned;
        exec->icb.groups_fallback = 0;
        exec->icb.last_fallback_reason = MG_ICB_FALLBACK_NONE;
        [commandBuffer commit];
        mg_status_t retain_status =
            mg_launch_retain_command_buffer(launch, commandBuffer, out_error);
        if (retain_status != MG_STATUS_OK) {
            mgLaunchDestroy(launch);
            return retain_status;
        }
        exec->in_flight_count++;
        launch->exec = exec;
        *out_launch = launch;
        return MG_STATUS_OK;
    }

    bool commandBufferHasWork = exec->node_count == 0;
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
                            offset:mg_metal_buffer_offset(buffer, dispatch->buffers[j].offset)
                           atIndex:dispatch->buffers[j].index];
                mg_buffer_retain(buffer);
                launch->retained_buffers[launch->retained_buffer_count++] = buffer;
            }
            for (uint32_t j = 0; j < dispatch->scalar_count; ++j) {
                [encoder setBytes:dispatch->scalars[j].data
                           length:dispatch->scalars[j].byte_count
                          atIndex:dispatch->scalars[j].index];
            }

            MTLSize grid =
                MTLSizeMake(dispatch->grid_size[0], dispatch->grid_size[1], dispatch->grid_size[2]);
            MTLSize threads = MTLSizeMake(dispatch->threads_per_threadgroup[0],
                                          dispatch->threads_per_threadgroup[1],
                                          dispatch->threads_per_threadgroup[2]);
            [encoder dispatchThreads:grid threadsPerThreadgroup:threads];
            [encoder endEncoding];
            commandBufferHasWork = true;
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
                       sourceOffset:mg_metal_buffer_offset(node->as.copy.src,
                                                           node->as.copy.src_offset)
                           toBuffer:dst
                  destinationOffset:mg_metal_buffer_offset(node->as.copy.dst,
                                                           node->as.copy.dst_offset)
                               size:node->as.copy.byte_count];
            [encoder endEncoding];
            mg_buffer_retain(node->as.copy.src);
            launch->retained_buffers[launch->retained_buffer_count++] = node->as.copy.src;
            mg_buffer_retain(node->as.copy.dst);
            launch->retained_buffers[launch->retained_buffer_count++] = node->as.copy.dst;
            commandBufferHasWork = true;
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
            NSRange range =
                NSMakeRange(mg_metal_buffer_offset(node->as.fill.dst, node->as.fill.dst_offset),
                            node->as.fill.byte_count);
            [encoder fillBuffer:dst range:range value:node->as.fill.value];
            [encoder endEncoding];
            mg_buffer_retain(node->as.fill.dst);
            launch->retained_buffers[launch->retained_buffer_count++] = node->as.fill.dst;
            commandBufferHasWork = true;
            break;
        }
        case MG_NODE_EVENT_WAIT: {
            id<MTLSharedEvent> event = (__bridge id<MTLSharedEvent>)node->as.event.event->impl;
            [commandBuffer encodeWaitForEvent:event value:node->as.event.value];
            mg_event_retain(node->as.event.event);
            launch->retained_events[launch->retained_event_count++] = node->as.event.event;
            commandBufferHasWork = true;
            break;
        }
        case MG_NODE_EVENT_SIGNAL: {
            id<MTLSharedEvent> event = (__bridge id<MTLSharedEvent>)node->as.event.event->impl;
            [commandBuffer encodeSignalEvent:event value:node->as.event.value];
            mg_event_retain(node->as.event.event);
            launch->retained_events[launch->retained_event_count++] = node->as.event.event;
            commandBufferHasWork = true;
            break;
        }
        case MG_NODE_BARRIER:
            break;
        case MG_NODE_MPSGRAPH: {
            if (commandBufferHasWork) {
                [commandBuffer commit];
                mg_status_t retain_status =
                    mg_launch_retain_command_buffer(launch, commandBuffer, out_error);
                if (retain_status != MG_STATUS_OK) {
                    mgLaunchDestroy(launch);
                    return retain_status;
                }
                [commandBuffer waitUntilCompleted];
                if (commandBuffer.status == MTLCommandBufferStatusError) {
                    mgLaunchDestroy(launch);
                    return mg_set_error(out_error, MG_STATUS_BACKEND_ERROR, MG_ERROR_STAGE_COMPLETE,
                                        node->as.mpsgraph.id,
                                        "Metal command buffer failed before MPSGraph encode",
                                        mg_ns_error_message(commandBuffer.error));
                }
                commandBuffer = [queue commandBuffer];
                if (!commandBuffer) {
                    mgLaunchDestroy(launch);
                    return mg_set_error(out_error, MG_STATUS_BACKEND_ERROR, MG_ERROR_STAGE_ENCODE,
                                        node->as.mpsgraph.id,
                                        "failed to create Metal command buffer", NULL);
                }
                commandBufferHasWork = false;
            }
            mg_status_t status =
                mg_mpsgraph_encode_node(&node->as.mpsgraph, commandBuffer, out_error);
            if (status != MG_STATUS_OK) {
                mgLaunchDestroy(launch);
                return status;
            }
            for (uint32_t j = 0; j < node->as.mpsgraph.feed_count; ++j) {
                mg_buffer_t *buffer = node->as.mpsgraph.feeds[j].buffer;
                mg_buffer_retain(buffer);
                launch->retained_buffers[launch->retained_buffer_count++] = buffer;
            }
            for (uint32_t j = 0; j < node->as.mpsgraph.target_count; ++j) {
                mg_buffer_t *buffer = node->as.mpsgraph.targets[j].buffer;
                mg_buffer_retain(buffer);
                launch->retained_buffers[launch->retained_buffer_count++] = buffer;
            }
            [commandBuffer commit];
            mg_status_t retain_status =
                mg_launch_retain_command_buffer(launch, commandBuffer, out_error);
            if (retain_status != MG_STATUS_OK) {
                mgLaunchDestroy(launch);
                return retain_status;
            }
            commandBuffer = [queue commandBuffer];
            if (!commandBuffer) {
                mgLaunchDestroy(launch);
                return mg_set_error(out_error, MG_STATUS_BACKEND_ERROR, MG_ERROR_STAGE_ENCODE,
                                    node->as.mpsgraph.id, "failed to create Metal command buffer",
                                    NULL);
            }
            commandBufferHasWork = false;
            break;
        }
        default:
            if ((int)node->kind == MG_NODE_INTERNAL_WORKSPACE) {
                break;
            }
            if ((int)node->kind == MG_NODE_INTERNAL_WORKSPACE_FILL) {
                id<MTLBlitCommandEncoder> encoder = [commandBuffer blitCommandEncoder];
                if (!encoder) {
                    mgLaunchDestroy(launch);
                    return mg_set_error(out_error, MG_STATUS_BACKEND_ERROR, MG_ERROR_STAGE_ENCODE,
                                        node->as.workspace_fill.id,
                                        "failed to create Metal workspace blit encoder", NULL);
                }

                id<MTLBuffer> workspace = (__bridge id<MTLBuffer>)exec->workspace.backend_impl;
                id<MTLBuffer> dst = (__bridge id<MTLBuffer>)node->as.workspace_fill.dst->impl;
                NSRange range =
                    NSMakeRange(node->as.workspace_fill.offset, node->as.workspace_fill.size);
                [encoder fillBuffer:workspace range:range value:node->as.workspace_fill.value];
                [encoder copyFromBuffer:workspace
                           sourceOffset:node->as.workspace_fill.offset
                               toBuffer:dst
                      destinationOffset:mg_metal_buffer_offset(
                                            node->as.workspace_fill.dst,
                                            node->as.workspace_fill.dst_offset)
                                   size:node->as.workspace_fill.size];
                [encoder endEncoding];
                mg_buffer_retain(node->as.workspace_fill.dst);
                launch->retained_buffers[launch->retained_buffer_count++] =
                    node->as.workspace_fill.dst;
                commandBufferHasWork = true;
                break;
            }
            mgLaunchDestroy(launch);
            return mg_set_error(out_error, MG_STATUS_INTERNAL_ERROR, MG_ERROR_STAGE_ENCODE,
                                MG_NODE_ID_INVALID, "unknown executable node kind", NULL);
        }
    }

    if (commandBufferHasWork) {
        [commandBuffer commit];
        mg_status_t retain_status =
            mg_launch_retain_command_buffer(launch, commandBuffer, out_error);
        if (retain_status != MG_STATUS_OK) {
            mgLaunchDestroy(launch);
            return retain_status;
        }
    }
    exec->in_flight_count++;
    launch->exec = exec;
    *out_launch = launch;
    return MG_STATUS_OK;
}

mg_status_t mgLaunchSynchronize(mg_launch_t *launch, mg_error_t **out_error) {
    mg_clear_error(out_error);
    if (!launch || launch->impl_count == 0) {
        return mg_set_error(out_error, MG_STATUS_INVALID_ARGUMENT, MG_ERROR_STAGE_SYNC,
                            MG_NODE_ID_INVALID, "launch is required", NULL);
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
        if (launch->exec && launch->exec->in_flight_count > 0) {
            launch->exec->in_flight_count--;
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

    for (size_t i = 0; i < launch->impl_count; ++i) {
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

void mgLaunchDestroy(mg_launch_t *launch) {
    if (!launch) {
        return;
    }

    mg_backend_launch_destroy(launch);
    free(launch->impls);
    free(launch->retained_buffers);
    free(launch->retained_events);
    free(launch);
}
