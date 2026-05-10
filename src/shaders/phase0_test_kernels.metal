#include <metal_stdlib>

using namespace metal;

kernel void mg_phase0_add_one(device uint *values [[buffer(0)]],
                              uint gid [[thread_position_in_grid]])
{
    values[gid] += 1;
}

kernel void mg_phase3_add_scalar(device uint *values [[buffer(0)]],
                                 constant uint &delta [[buffer(1)]],
                                 uint gid [[thread_position_in_grid]])
{
    values[gid] += delta;
}

kernel void mg_phase5_add_one_float(device float *values [[buffer(0)]],
                                    uint gid [[thread_position_in_grid]])
{
    values[gid] += 1.0f;
}
