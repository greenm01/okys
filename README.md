# okys

A 2D vector graphics library: a NanoVG-style canvas API, written in Zig behind
a C ABI, rendering through sokol_gfx. Built to be called from Nim and anything
else that speaks C.

## Build

```sh
zig build         # static library + C header -> zig-out/
zig build test    # unit tests + the C ABI smoke test
```

`zig-out/lib/libokys.a` and `zig-out/include/okys.h` are the artifacts.

## Status

Early. The C ABI skeleton, the front-end state and command stream, and the
render-interface seam are in place; the layout assertions guard the ABI. The
stencil backend and the tiled backend are not implemented yet.

## License

BSD 3-Clause. See [LICENSE](LICENSE).
