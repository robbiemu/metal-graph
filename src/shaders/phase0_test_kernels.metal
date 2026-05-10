#include <metal_stdlib>

using namespace metal;

kernel void mg_phase0_add_one(device uint *values [[buffer(0)]],
                              uint gid [[thread_position_in_grid]])
{
    values[gid] += 1;
}
