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
stays as a fallback for targets without compute shaders, such as WebGL2.

The front-end is NanoVG's API, reimplemented in Zig rather than ported. The C
header is hand-written and is the source of truth for the ABI.

## Build

```sh
zig build         # static library + C header -> zig-out/
zig build test    # unit tests + C ABI smoke test
```

Artifacts: `zig-out/lib/libokys.a` and `zig-out/include/okys.h`.

## Status

Early. The C ABI, front-end state, command recording, and the render-interface
seam exist, with comptime layout assertions on the ABI structs. No backend is
implemented yet: fills and strokes record geometry but don't draw.

## License

BSD 3-Clause.
