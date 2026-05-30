@vs vs
layout(binding=0) uniform vs_params {
    vec2 view_size;
};

in vec2 position;
in vec2 uv;

out vec2 frag_uv;

void main() {
    vec2 clip = (position / view_size) * 2.0 - 1.0;
    gl_Position = vec4(clip.x, -clip.y, 0.0, 1.0);
    frag_uv = uv;
}
@end

@fs fs
in vec2 frag_uv;

out vec4 frag_color;

void main() {
    frag_color = vec4(frag_uv, 0.0, 1.0);
}
@end

@program path vs fs
