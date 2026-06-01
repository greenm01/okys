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

Desktop is the target. Downstream libraries should consume Okys through the C
ABI rather than binding WebGPU themselves. The current WebGPU bridge accepts a
host-provided `WGPUDevice` and current texture view. The first Okys-owned
platform host slice accepts Linux Wayland handles and creates the Vulkan
device/swapchain behind `okys.h`, so Koi/Gridmonger do not need a separate
WebGPU package for that path.

Native Vulkan remains available for the current Linux host path, diagnostics,
and benchmarks. GL remains useful for local smoke/golden fixtures.

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
and sparse GPU fine path are in place. Caller-owned graphics contexts use
`okySetupGraphics` or the GL/WebGPU/Vulkan convenience wrappers. Linux Wayland
consumers can use `okyPlatformHostCreateWayland` plus the platform-frame API to
let Okys own device/swapchain setup. See `examples/c_glfw_minimal.c` for the GL
call order.

## License

BSD 3-Clause.
