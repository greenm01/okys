@vs vs
layout(binding=0) uniform vs_params {
    vec2 view_size;
};

in vec2 position;
in vec2 uv;

out vec2 frag_uv;
out vec2 frag_pos;

void main() {
    vec2 clip = (position / view_size) * 2.0 - 1.0;
    gl_Position = vec4(clip.x, -clip.y, 0.0, 1.0);
    frag_uv = uv;
    frag_pos = position;
}
@end

@fs fs_stencil
in vec2 frag_uv;
in vec2 frag_pos;

out vec4 frag_color;

void main() {
    frag_color = vec4(1.0);
}
@end

@fs fs_cover
layout(binding=1) uniform fs_params {
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
};
layout(binding=0) uniform texture2D image_tex;
layout(binding=0) uniform sampler image_smp;

in vec2 frag_uv;
in vec2 frag_pos;

out vec4 frag_color;

mat3 paintMat() {
    return mat3(paint_mat0.xyz, paint_mat1.xyz, paint_mat2.xyz);
}

mat3 scissorMat() {
    return mat3(scissor_mat0.xyz, scissor_mat1.xyz, scissor_mat2.xyz);
}

float sdroundrect(vec2 pt, vec2 ext, float rad) {
    vec2 ext2 = ext - vec2(rad, rad);
    vec2 d = abs(pt) - ext2;
    return min(max(d.x, d.y), 0.0) + length(max(d, 0.0)) - rad;
}

float scissorMask(vec2 p) {
    vec2 sc = abs((scissorMat() * vec3(p, 1.0)).xy) - scissor_extent_scale.xy;
    sc = vec2(0.5, 0.5) - sc * scissor_extent_scale.zw;
    return clamp(sc.x, 0.0, 1.0) * clamp(sc.y, 0.0, 1.0);
}

float edgeMask(vec2 uv) {
    if (params.x <= 0.0) {
        return 1.0;
    }
    float alpha = 1.0 - abs(uv.x * 2.0 - 1.0);
    return clamp(alpha * params.x, 0.0, 1.0) * clamp(uv.y, 0.0, 1.0);
}

void main() {
    float scissor = scissorMask(frag_pos);
    float edge = edgeMask(frag_uv);
    vec2 pt = (paintMat() * vec3(frag_pos, 1.0)).xy;
    if (params.y > 0.5) {
        vec2 image_extent = max(abs(extent_radius_feather.xy), vec2(0.0001));
        vec4 sample_color = texture(sampler2D(image_tex, image_smp), pt / image_extent);
        float alpha = sample_color.a * inner_color.a;
        frag_color = vec4(sample_color.rgb * inner_color.rgb * sample_color.a, alpha) * scissor * edge;
        return;
    }

    float feather = max(extent_radius_feather.w, 0.0001);
    float d = clamp((sdroundrect(pt, extent_radius_feather.xy, extent_radius_feather.z) + feather * 0.5) / feather, 0.0, 1.0);
    frag_color = mix(inner_color, outer_color, d) * scissor * edge;
}
@end

@program path_stencil vs fs_stencil
@program path_cover vs fs_cover
