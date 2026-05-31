@block common
struct GpuCall {
    vec4 color;
    vec4 bounds;
    uint segment_start;
    uint segment_count;
    uint task_start;
    uint task_count;
    uint flags;
    uint fill_rule;
    uint _pad0;
    uint _pad1;
};

struct Segment {
    float x0;
    float y0;
    float x1;
    float y1;
    uint call_index;
    uint path_index;
    int winding;
    uint flags;
};

struct GpuFineTask {
    uint x;
    uint y;
    uint call_index;
    uint kind;
    uint segment_start;
    uint segment_count;
    uint strip_index;
    uint _pad0;
};

struct GpuStripIndex {
    uint value;
};

float integrate_clamped_linear(float slope, float intercept, float y0, float y1) {
    if (slope == 0.0) {
        return (y1 - y0) * clamp(intercept, 0.0, 1.0);
    }

    float stops[4];
    stops[0] = y0;
    stops[1] = y1;
    int count = 2;
    float a = (0.0 - intercept) / slope;
    if (a > y0 && a < y1) {
        stops[count] = a;
        count += 1;
    }
    float b = (1.0 - intercept) / slope;
    if (b > y0 && b < y1) {
        stops[count] = b;
        count += 1;
    }

    for (int i = 1; i < count; i += 1) {
        float v = stops[i];
        int j = i - 1;
        while (j >= 0 && stops[j] > v) {
            stops[j + 1] = stops[j];
            j -= 1;
        }
        stops[j + 1] = v;
    }

    float area = 0.0;
    for (int i = 0; i + 1 < count; i += 1) {
        float lo = stops[i];
        float hi = stops[i + 1];
        if (lo == hi) {
            continue;
        }
        float mid = (lo + hi) * 0.5;
        float mid_value = slope * mid + intercept;
        if (mid_value <= 0.0) {
            continue;
        }
        if (mid_value >= 1.0) {
            area += hi - lo;
            continue;
        }
        float lo_value = slope * lo + intercept;
        float hi_value = slope * hi + intercept;
        area += (lo_value + hi_value) * 0.5 * (hi - lo);
    }
    return clamp(area, 0.0, y1 - y0);
}

float segment_area(float px, float py, Segment seg) {
    float dy = seg.y1 - seg.y0;
    if (dy == 0.0) {
        return 0.0;
    }

    float y0 = max(min(seg.y0, seg.y1), py);
    float y1 = min(max(seg.y0, seg.y1), py + 1.0);
    if (y0 >= y1) {
        return 0.0;
    }

    float slope = (seg.x1 - seg.x0) / dy;
    float intercept = seg.x0 - slope * seg.y0 - px;
    float sign = dy > 0.0 ? 1.0 : -1.0;
    return sign * integrate_clamped_linear(slope, intercept, y0, y1);
}

float area_to_alpha(uint fill_rule, float area) {
    if (fill_rule == 0u) {
        return min(abs(area), 1.0);
    }
    float folded = area - 2.0 * floor(area * 0.5 + 0.5);
    return min(abs(folded), 1.0);
}

vec4 over(vec4 src, vec4 dst) {
    float inv_a = 1.0 - src.a;
    return vec4(src.rgb + dst.rgb * inv_a, src.a + dst.a * inv_a);
}
@end

@cs sparse_clear
@include_block common

layout(binding=0) uniform clear_params {
    int surface_width;
    int surface_height;
};

layout(binding=0, rgba8) uniform image2D clear_surface_img;

layout(local_size_x=8, local_size_y=8, local_size_z=1) in;

void main() {
    int x = int(gl_GlobalInvocationID.x);
    int y = int(gl_GlobalInvocationID.y);
    if (x >= surface_width || y >= surface_height) {
        return;
    }
    imageStore(clear_surface_img, ivec2(x, y), vec4(0.0));
}
@end
@program sparse_clear sparse_clear

@cs sparse_fine
@include_block common

layout(binding=0) uniform fine_params {
    int surface_width;
    int surface_height;
    int task_start;
    int task_count;
};

layout(binding=0) readonly buffer calls_buf {
    GpuCall calls[];
};

layout(binding=1) readonly buffer segments_buf {
    Segment segments[];
};

layout(binding=2) readonly buffer strip_indices_buf {
    GpuStripIndex strip_indices[];
};

layout(binding=3) readonly buffer tasks_buf {
    GpuFineTask tasks[];
};

layout(binding=4, rgba8) uniform image2D fine_surface_img;

layout(local_size_x=8, local_size_y=4, local_size_z=1) in;

void main() {
    uint local_x = gl_LocalInvocationID.x;
    uint local_y = gl_LocalInvocationID.y;
    if (local_x >= 4u) {
        return;
    }
    int task_offset = int(gl_WorkGroupID.x);
    if (task_offset >= task_count) {
        return;
    }

    GpuFineTask task = tasks[uint(task_start + task_offset)];
    GpuCall call = calls[task.call_index];
    uint x = task.x + local_x;
    uint y = task.y + local_y;
    if (x >= uint(surface_width) || y >= uint(surface_height)) {
        return;
    }

    float alpha = 1.0;
    if (task.kind == 1u) {
        float area = 0.0;
        for (uint i = 0u; i < task.segment_count; i += 1u) {
            uint segment_index = strip_indices[task.segment_start + i].value;
            area += segment_area(float(x), float(y), segments[segment_index]);
        }
        alpha = area_to_alpha(call.fill_rule, area);
    }
    if (alpha <= 0.0) {
        return;
    }

    vec4 src = vec4(call.color.rgb * alpha, call.color.a * alpha);
    vec4 dst = imageLoad(fine_surface_img, ivec2(int(x), int(y)));
    imageStore(fine_surface_img, ivec2(int(x), int(y)), over(src, dst));
}
@end
@program sparse_fine sparse_fine
