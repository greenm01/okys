@block common
struct GpuCall {
    vec4 paint_mat0;
    vec4 paint_mat1;
    vec4 paint_mat2;
    vec4 scissor_mat0;
    vec4 scissor_mat1;
    vec4 scissor_mat2;
    vec4 inner_color;
    vec4 outer_color;
    vec4 scissor_extent_scale;
    vec4 extent_radius_feather;
    vec4 params;
    vec4 bounds;
    uint segment_start;
    uint segment_count;
    uint task_start;
    uint task_count;
    uint flags;
    uint fill_rule;
    uint image_id;
    uint clip_start;
    uint clip_count;
    uint _pad1;
};

struct GpuClip {
    vec4 bounds;
    uint segment_start;
    uint segment_count;
    uint fill_rule;
    uint _pad0;
};

struct GpuClipIndex {
    uint value;
};

struct Segment {
    float slope;
    float intercept;
    float min_y;
    float max_y;
    float sign;
    float _pad0;
    uint _pad1;
    uint _pad2;
};

struct GpuFineTask {
    uint xy;
    uint call_index;
    uint segment_start;
    uint segment_count_kind;
};

struct GpuSegmentIndex {
    uint value;
};

const uint task_kind_alpha_mask = 0x80000000u;

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
    if (seg.sign == 0.0) {
        return 0.0;
    }

    float y0 = max(seg.min_y, py);
    float y1 = min(seg.max_y, py + 1.0);
    if (y0 >= y1) {
        return 0.0;
    }

    float intercept = seg.intercept - px;
    float x0 = seg.slope * y0 + intercept;
    float x1 = seg.slope * y1 + intercept;
    if (x0 <= 0.0 && x1 <= 0.0) {
        return 0.0;
    }
    if (x0 >= 1.0 && x1 >= 1.0) {
        return seg.sign * (y1 - y0);
    }
    return seg.sign * integrate_clamped_linear(seg.slope, intercept, y0, y1);
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

mat3 paint_mat(GpuCall call) {
    return mat3(call.paint_mat0.xyz, call.paint_mat1.xyz, call.paint_mat2.xyz);
}

mat3 scissor_mat(GpuCall call) {
    return mat3(call.scissor_mat0.xyz, call.scissor_mat1.xyz, call.scissor_mat2.xyz);
}

float sdroundrect(vec2 pt, vec2 ext, float rad) {
    vec2 ext2 = ext - vec2(rad, rad);
    vec2 d = abs(pt) - ext2;
    return min(max(d.x, d.y), 0.0) + length(max(d, 0.0)) - rad;
}

float scissor_mask(GpuCall call, vec2 p) {
    vec2 sc = abs((scissor_mat(call) * vec3(p, 1.0)).xy) - call.scissor_extent_scale.xy;
    sc = vec2(0.5, 0.5) - sc * call.scissor_extent_scale.zw;
    return clamp(sc.x, 0.0, 1.0) * clamp(sc.y, 0.0, 1.0);
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

layout(binding=2) readonly buffer clips_buf {
    GpuClip clips[];
};

layout(binding=3) readonly buffer tasks_buf {
    GpuFineTask tasks[];
};

layout(binding=6) readonly buffer clip_indices_buf {
    GpuClipIndex clip_indices[];
};

layout(binding=7) readonly buffer segment_indices_buf {
    GpuSegmentIndex segment_indices[];
};

layout(binding=4, rgba8) uniform image2D fine_surface_img;
layout(binding=5) uniform texture2D image_tex;
layout(binding=0) uniform sampler image_smp;

layout(local_size_x=8, local_size_y=4, local_size_z=1) in;

float coverage_for_range(uint fill_rule, uint segment_start, uint segment_count, uint x, uint y) {
    float area = 0.0;
    for (uint i = 0u; i < segment_count; i += 1u) {
        area += segment_area(float(x), float(y), segments[segment_start + i]);
    }
    return area_to_alpha(fill_rule, area);
}

float coverage_for_task(uint fill_rule, GpuFineTask task, uint x, uint y) {
    float area = 0.0;
    uint segment_count = task.segment_count_kind & ~task_kind_alpha_mask;
    for (uint i = 0u; i < segment_count; i += 1u) {
        uint segment_index = segment_indices[task.segment_start + i].value;
        area += segment_area(float(x), float(y), segments[segment_index]);
    }
    return area_to_alpha(fill_rule, area);
}

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
    uint x = (task.xy & 0xffffu) + local_x;
    uint y = (task.xy >> 16) + local_y;
    if (x >= uint(surface_width) || y >= uint(surface_height)) {
        return;
    }

    float alpha = 1.0;
    if ((task.segment_count_kind & task_kind_alpha_mask) != 0u) {
        alpha = coverage_for_task(call.fill_rule, task, x, y);
    }
    if (alpha <= 0.0) {
        return;
    }

    vec2 sample_pos = vec2(float(x) + 0.5, float(y) + 0.5);
    if (call.params.x > 0.5) {
        alpha *= scissor_mask(call, sample_pos);
        if (alpha <= 0.0) {
            return;
        }
    }

    for (uint i = 0u; i < call.clip_count; i += 1u) {
        GpuClip clip = clips[clip_indices[call.clip_start + i].value];
        if (clip.segment_count == 0u) {
            return;
        }
        alpha *= coverage_for_range(clip.fill_rule, clip.segment_start, clip.segment_count, x, y);
        if (alpha <= 0.0) {
            return;
        }
    }

    vec2 pt = (paint_mat(call) * vec3(sample_pos, 1.0)).xy;
    vec4 paint;
    if (call.params.y > 0.5) {
        vec2 image_extent = max(abs(call.extent_radius_feather.xy), vec2(0.0001));
        vec4 sample_color = texture(sampler2D(image_tex, image_smp), pt / image_extent);
        float sample_alpha = sample_color.a * call.inner_color.a;
        paint = vec4(sample_color.rgb * call.inner_color.rgb * sample_color.a, sample_alpha);
    } else {
        float feather = max(call.extent_radius_feather.w, 0.0001);
        float d = clamp((sdroundrect(pt, call.extent_radius_feather.xy, call.extent_radius_feather.z) + feather * 0.5) / feather, 0.0, 1.0);
        paint = mix(call.inner_color, call.outer_color, d);
    }

    vec4 src = vec4(paint.rgb * alpha, paint.a * alpha);
    vec4 dst = imageLoad(fine_surface_img, ivec2(int(x), int(y)));
    imageStore(fine_surface_img, ivec2(int(x), int(y)), over(src, dst));
}
@end
@program sparse_fine sparse_fine
