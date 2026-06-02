@block common
struct DirectStrip {
    uint xy;
    uint width_flags;
    uint alpha_start;
    uint alpha_count;
    uint paint_index;
    uint call_index;
    uint order;
    uint _pad0;
};

struct SolidPaint {
    vec4 rgba;
};

struct AlphaWord {
    uint packed;
};

const uint strip_kind_alpha = 1u;
const uint tile_size = 4u;
const uint tile_area = 16u;

uint strip_x(DirectStrip strip) {
    return strip.xy & 0xffffu;
}

uint strip_y(DirectStrip strip) {
    return strip.xy >> 16;
}

uint strip_width(DirectStrip strip) {
    return strip.width_flags & 0xffffu;
}

uint strip_flags(DirectStrip strip) {
    return strip.width_flags >> 16;
}

@end

@vs vs
@include_block common

layout(binding=0) uniform vs_params {
    vec2 view_size;
};

layout(binding=0) readonly buffer strips_buf {
    DirectStrip strips[];
};

layout(binding=1) readonly buffer paints_buf {
    SolidPaint paints[];
};

in vec2 corner;

flat out uint frag_strip_index;
flat out uint frag_alpha_start;
flat out uint frag_alpha_count;
flat out uint frag_paint_index;
flat out uint frag_flags;
flat out uint frag_origin_x;
flat out uint frag_origin_y;
out vec2 frag_pos;

void main() {
    uint instance_index = uint(gl_InstanceIndex);
    DirectStrip strip = strips[instance_index];
    uint x = strip_x(strip);
    uint y = strip_y(strip);
    uint width = strip_width(strip);

    vec2 pos = vec2(float(x) + corner.x * float(width), float(y) + corner.y * float(tile_size));
    vec2 clip = (pos / view_size) * 2.0 - 1.0;
    gl_Position = vec4(clip.x, -clip.y, 0.0, 1.0);

    frag_strip_index = instance_index;
    frag_alpha_start = strip.alpha_start;
    frag_alpha_count = strip.alpha_count;
    frag_paint_index = strip.paint_index;
    frag_flags = strip_flags(strip);
    frag_origin_x = x;
    frag_origin_y = y;
    frag_pos = pos;
}
@end

@fs fs
@include_block common

layout(binding=1) readonly buffer paints_buf {
    SolidPaint paints[];
};

layout(binding=2) readonly buffer alpha_words_buf {
    AlphaWord alpha_words[];
};

flat in uint frag_strip_index;
flat in uint frag_alpha_start;
flat in uint frag_alpha_count;
flat in uint frag_paint_index;
flat in uint frag_flags;
flat in uint frag_origin_x;
flat in uint frag_origin_y;
in vec2 frag_pos;

out vec4 frag_color;

float alpha_at(uint byte_index) {
    uint word = alpha_words[byte_index >> 2u].packed;
    uint shift = (byte_index & 3u) * 8u;
    return float((word >> shift) & 0xffu) / 255.0;
}

void main() {
    uint pixel_x = uint(floor(frag_pos.x));
    uint pixel_y = uint(floor(frag_pos.y));
    uint local_x = pixel_x - frag_origin_x;
    uint local_y = pixel_y - frag_origin_y;
    if (local_y >= tile_size) {
        discard;
    }

    float coverage = 1.0;
    if ((frag_flags & strip_kind_alpha) != 0u) {
        uint tile_index = local_x >> 2u;
        uint tile_x = local_x & 3u;
        uint alpha_offset = frag_alpha_start + tile_index * tile_area + local_y * tile_size + tile_x;
        if (alpha_offset >= frag_alpha_start + frag_alpha_count) {
            discard;
        }
        coverage = alpha_at(alpha_offset);
        if (coverage <= 0.0) {
            discard;
        }
    }

    vec4 paint = paints[frag_paint_index].rgba;
    frag_color = vec4(paint.rgb * coverage, paint.a * coverage);
}
@end

@program direct_strip vs fs
