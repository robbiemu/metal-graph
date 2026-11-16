#include "../../src/core/internal.h"
#include "metal_graph/metal_graph.h"
#include "metal_graph/metal_graph_metal.h"
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
extern void mg_test_fail_next_fence(mg_graph_exec_t *exec);
extern int mg_test_hazard_admission_only(mg_graph_exec_t *exec, mg_stream_t *stream);

static void ok(mg_status_t result, mg_error_t **error, const char *where) {
    if (result != MG_STATUS_OK) {
        fprintf(stderr, "%s status=%d error=%s\n", where, result,
                *error ? mgErrorMessage(*error) : "none");
        exit(2);
    }
    mgErrorDestroy(*error);
    *error = NULL;
}
int main() {
    @autoreleasepool {
        mg_error_t *error = NULL;
        mg_device_t *device = NULL;
        mg_stream_t *stream = NULL;
        mg_status_t status = mgDeviceCreateSystemDefault(&device, &error);
        if (status == MG_STATUS_UNSUPPORTED) {
            fprintf(stderr, "SKIP no Metal device\n");
            return 77;
        }
        ok(status, &error, "device");
        ok(mgStreamCreate(device, &stream, &error), &error, "stream");
        id<MTLDevice> nativeDevice = (__bridge id<MTLDevice>)device->impl;
        id<MTLBuffer> native =
            [nativeDevice newBufferWithLength:64
                                      options:MTLResourceStorageModeShared |
                                              MTLResourceHazardTrackingModeUntracked];
        if (!native || native.hazardTrackingMode != MTLHazardTrackingModeUntracked)
            return 77;
        mg_metal_buffer_wrap_desc_t wd = {};
        wd.size = sizeof(wd);
        wd.buffer = native;
        wd.byte_length = 64;
        wd.access = MG_METAL_BUFFER_ACCESS_READ_WRITE;
        wd.flags = MG_METAL_BUFFER_WRAP_RETAIN_BUFFER | MG_METAL_BUFFER_WRAP_HOST_VISIBLE |
                   MG_METAL_BUFFER_WRAP_MUTABLE;
        mg_buffer_t *input = NULL, *output = NULL;
        ok(mgMetalBufferWrap(device, &wd, &input, &error), &error, "wrap");
        ok(mgBufferCreateShared(device, 64, &output, &error), &error, "output");
        { /* Valid binding at buffer end: admission-only, never dispatch out of bounds. */
            mg_graph_t *g = NULL;
            mg_graph_exec_t *x = NULL;
            mg_node_t *n = NULL;
            mg_buffer_binding_t b = {};
            b.index = 0;
            b.buffer = input;
            b.offset = 64;
            mg_dispatch_resource_desc_t r = {};
            r.size = sizeof(r);
            r.index = 0;
            r.access = MG_RESOURCE_ACCESS_UNKNOWN;
            r.byte_count = 0;
            r.alignment = 4;
            mg_dispatch_desc_t d = {};
            d.size = sizeof(d);
            d.metallib_path = TEST_METALLIB_PATH;
            d.kernel_name = "mg_phase0_add_one";
            d.grid_size[0] = d.grid_size[1] = d.grid_size[2] = 1;
            d.threads_per_threadgroup[0] = d.threads_per_threadgroup[1] =
                d.threads_per_threadgroup[2] = 1;
            d.buffers = &b;
            d.buffer_count = 1;
            d.resources = &r;
            d.resource_count = 1;
            ok(mgGraphCreate(&g, &error), &error, "zero graph");
            ok(mgGraphAddDispatchNode(g, &d, &n, &error), &error, "zero dispatch");
            ok(mgGraphInstantiate(g, device, &x, &error), &error, "zero instantiate");
            if (!mg_test_hazard_admission_only(x, stream)) {
                fprintf(stderr, "empty range admission failed\n");
                return 12;
            }
            mgGraphExecDestroy(x);
            mgGraphDestroy(g);
        }
        for (unsigned round = 1; round <= 8; ++round) {
            memset(native.contents, 0xA5, 64);
            memset(mgBufferContents(output), 0x5A, 64);
            mg_graph_t *graph = NULL;
            mg_graph_exec_t *exec = NULL;
            mg_launch_t *launch = NULL;
            mg_node_t *fillNode = NULL, *dispatchNode = NULL, *copyNode = NULL;
            mg_fill_desc_t fill = {};
            fill.size = sizeof(fill);
            fill.dst = input;
            fill.byte_count = 16;
            fill.value = (uint8_t)round;
            mg_buffer_binding_t binding = {};
            binding.index = 0;
            binding.buffer = input;
            mg_dispatch_resource_desc_t resource = {};
            resource.size = sizeof(resource);
            resource.index = 0;
            resource.access = MG_RESOURCE_ACCESS_READ_WRITE;
            resource.byte_count = 16;
            resource.alignment = 4;
            mg_dispatch_desc_t dispatch = {};
            dispatch.size = sizeof(dispatch);
            dispatch.metallib_path = TEST_METALLIB_PATH;
            dispatch.kernel_name = "mg_phase0_add_one";
            dispatch.grid_size[0] = 4;
            dispatch.grid_size[1] = 1;
            dispatch.grid_size[2] = 1;
            dispatch.threads_per_threadgroup[0] = 1;
            dispatch.threads_per_threadgroup[1] = 1;
            dispatch.threads_per_threadgroup[2] = 1;
            dispatch.buffers = &binding;
            dispatch.buffer_count = 1;
            dispatch.resources = &resource;
            dispatch.resource_count = 1;
            mg_copy_desc_t copy = {};
            copy.size = sizeof(copy);
            copy.src = input;
            copy.dst = output;
            copy.dst_offset = 16;
            copy.byte_count = 16;
            ok(mgGraphCreate(&graph, &error), &error, "graph");
            ok(mgGraphAddFillNode(graph, &fill, &fillNode, &error), &error, "fill");
            ok(mgGraphAddDispatchNode(graph, &dispatch, &dispatchNode, &error), &error, "dispatch");
            ok(mgGraphAddCopyNode(graph, &copy, &copyNode, &error), &error, "copy");
            ok(mgGraphAddDependency(graph, fillNode, dispatchNode, &error), &error,
               "fill-dispatch");
            ok(mgGraphAddDependency(graph, dispatchNode, copyNode, &error), &error,
               "dispatch-copy");
            ok(mgGraphInstantiate(graph, device, &exec, &error), &error, "instantiate");
            if (round == 1) {
                mg_test_fail_next_fence(exec);
                status = mgGraphLaunch(exec, stream, &launch, &error);
                if (status != MG_STATUS_BACKEND_ERROR || launch || !error ||
                    mgErrorStage(error) != MG_ERROR_STAGE_ENCODE ||
                    ((uint8_t *)native.contents)[0] != 0xA5) {
                    fprintf(stderr, "fence failure not atomic\n");
                    return 3;
                }
                mgErrorDestroy(error);
                error = NULL;
            }
            ok(mgGraphLaunch(exec, stream, &launch, &error), &error, "launch");
            ok(mgLaunchSynchronize(launch, &error), &error, "sync");
            uint8_t *bytes = (uint8_t *)mgBufferContents(output);
            uint32_t expected = round * 0x01010101u + 1;
            for (int i = 0; i < 4; i++)
                if (((uint32_t *)(bytes + 16))[i] != expected) {
                    fprintf(stderr, "output mismatch round=%u index=%d\n", round, i);
                    return 4;
                }
            for (int i = 0; i < 64; i++)
                if ((i < 16 || i >= 32) && bytes[i] != 0x5A) {
                    fprintf(stderr, "output guard mismatch\n");
                    return 5;
                }
            for (int i = 16; i < 64; i++)
                if (((uint8_t *)native.contents)[i] != 0xA5) {
                    fprintf(stderr, "input guard mismatch\n");
                    return 6;
                }
            mgLaunchDestroy(launch);
            mgGraphExecDestroy(exec);
            mgGraphDestroy(graph);
        }
        { /* An eligible single-dispatch ICB must fall back for manual hazards. */
            uint32_t *v = (uint32_t *)native.contents;
            for (int i = 0; i < 4; i++)
                v[i] = (uint32_t)i;
            mg_graph_t *g = NULL;
            mg_graph_exec_t *x = NULL;
            mg_launch_t *l = NULL;
            mg_node_t *n = NULL;
            mg_buffer_binding_t b = {};
            b.index = 0;
            b.buffer = input;
            mg_dispatch_resource_desc_t r = {};
            r.size = sizeof(r);
            r.index = 0;
            r.access = MG_RESOURCE_ACCESS_READ_WRITE;
            r.byte_count = 16;
            r.alignment = 4;
            mg_dispatch_desc_t d = {};
            d.size = sizeof(d);
            d.metallib_path = TEST_METALLIB_PATH;
            d.kernel_name = "mg_phase0_add_one";
            d.grid_size[0] = 4;
            d.grid_size[1] = d.grid_size[2] = 1;
            d.threads_per_threadgroup[0] = d.threads_per_threadgroup[1] =
                d.threads_per_threadgroup[2] = 1;
            d.buffers = &b;
            d.buffer_count = 1;
            d.resources = &r;
            d.resource_count = 1;
            ok(mgGraphCreate(&g, &error), &error, "ICB graph");
            ok(mgGraphAddDispatchNode(g, &d, &n, &error), &error, "ICB dispatch");
            ok(mgGraphInstantiate(g, device, &x, &error), &error, "ICB instantiate");
            if (!x->icb.backend_impl) {
                fprintf(stderr, "SKIP eligible ICB unavailable\n");
                return 77;
            }
            ok(mgGraphLaunch(x, stream, &l, &error), &error, "ICB fallback launch");
            ok(mgLaunchSynchronize(l, &error), &error, "ICB fallback sync");
            mg_graph_exec_diagnostics_t diagnostic = {};
            diagnostic.size = sizeof(diagnostic);
            ok(mgGraphExecGetDiagnostics(x, &diagnostic, &error), &error, "ICB diagnostics");
            if (diagnostic.icb_last_fallback_reason != MG_ICB_FALLBACK_MANUAL_HAZARDS) {
                fprintf(stderr, "ICB fallback diagnostic mismatch\n");
                return 14;
            }
            for (int i = 0; i < 4; i++)
                if (v[i] != (uint32_t)i + 1)
                    return 15;
            mgLaunchDestroy(l);
            mgGraphExecDestroy(x);
            mgGraphDestroy(g);
        }
        { /* Internal workspace fill/copy are separate fenced blit passes. */
            memset(native.contents, 0xA5, 64);
            memset(mgBufferContents(output), 0x5A, 64);
            mg_arena_desc_t ad = {};
            ad.size = sizeof(ad);
            ad.byte_count = 64;
            ad.alignment = 16;
            mg_arena_t *arena = NULL;
            mg_graph_t *g = NULL;
            mg_graph_exec_t *x = NULL;
            mg_launch_t *l = NULL;
            mg_node_t *workspace = NULL, *copyNode = NULL;
            mg_workspace_desc_t ws = {};
            ws.size = sizeof(ws);
            ws.byte_count = 16;
            ws.alignment = 16;
            mg_copy_desc_t cp = {};
            cp.size = sizeof(cp);
            cp.src = input;
            cp.dst = output;
            cp.dst_offset = 16;
            cp.byte_count = 16;
            ok(mgArenaCreate(device, &ad, &arena, &error), &error, "workspace arena");
            ok(mgGraphCreate(&g, &error), &error, "workspace graph");
            ok(mgGraphSetArena(g, arena, &error), &error, "workspace arena set");
            ok(mg_internal_graph_add_workspace_fill_node(g, &ws, 0x6C, input, 0, &workspace,
                                                         &error),
               &error, "workspace fill");
            ok(mgGraphAddCopyNode(g, &cp, &copyNode, &error), &error, "workspace copy");
            ok(mgGraphAddDependency(g, workspace, copyNode, &error), &error,
               "workspace dependency");
            ok(mgGraphInstantiate(g, device, &x, &error), &error, "workspace instantiate");
            ok(mgGraphLaunch(x, stream, &l, &error), &error, "workspace launch");
            ok(mgLaunchSynchronize(l, &error), &error, "workspace sync");
            uint8_t *v = (uint8_t *)mgBufferContents(output);
            for (int i = 0; i < 64; i++)
                if (v[i] != (i >= 16 && i < 32 ? 0x6C : 0x5A)) {
                    fprintf(stderr, "workspace output mismatch\n");
                    return 13;
                }
            mgLaunchDestroy(l);
            mgGraphExecDestroy(x);
            mgGraphDestroy(g);
            mgArenaDestroy(arena);
        }
        mgBufferDestroy(input);
        mgBufferDestroy(output);
        mgStreamDestroy(stream);
        mgDeviceDestroy(device);
        fprintf(stderr, "FENCE_PROTOTYPE rounds=8 exact=1 guards=1 forced-allocation-failure=1 "
                        "empty-binding-admission=1 workspace=1 icb-fallback=1\n");
        return 0;
    }
}
