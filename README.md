# okys

A 2D vector graphics library: a NanoVG-style canvas API in Zig, behind a C ABI,
rendering on sokol_gfx. Usable from Nim or any language with a C FFI.

## Goal

A tiled rasterizer in the spirit of vello. Path segments are sorted into screen
tiles and coverage is computed analytically per pixel, so antialiasing comes out
of the coverage math instead of extra fringe geometry. It handles arbitrary
input — self-intersecting, holed, and overlapping paths — which a general-purpose
drawing library can't avoid.

The stencil-then-cover backend (NanoVG's approach) comes first. It's there to
get the rest of the library working — ABI, bindings, paint shaders, scissor,
transforms, buffer management — before the tiled rasterizer goes in, and it
stays as a fallback for targets without compute shaders.

The front-end is NanoVG's API, reimplemented in Zig rather than ported. The C
header is hand-written and is the source of truth for the ABI.

## Platforms

Desktop is the target. `-Dbackend=native` lets sokol pick the platform default:
Metal on macOS, D3D11 on Windows, and GLCORE on Linux. Linux callers can opt into
Vulkan with `-Dbackend=vulkan`. WebGPU is an explicit bridge for hosts that
already own a WebGPU device and current texture view.

## Build

```sh
zig build                  # static library + C header -> zig-out/
zig build -Dbackend=gl     # force GL-flavored sokol_clib
zig build -Dbackend=vulkan # force Vulkan-flavored sokol_clib
zig build -Dbackend=wgpu   # force WebGPU-flavored sokol_clib
zig build test             # unit tests + C ABI smoke test
```

Artifacts: `zig-out/lib/libokys.a` and `zig-out/include/okys.h`.

## Status

The C ABI, NanoVG-style front-end, stencil-cover fallback, sparse-strip CPU proof,
and sparse GPU fine path are in place. Native hosts must install a graphics
runtime after creating their device or context. GL callers use `okySetupGL`;
WebGPU callers use `okySetupWebGPU` plus `okySetWebGPURenderTarget` each frame.
See `examples/c_glfw_minimal.c` for the GL call order.

## License

BSD 3-Clause.
