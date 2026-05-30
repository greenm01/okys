//! Plan A backend: stencil-then-cover fill + geometric fringe AA, on sokol_gfx.
//! The proven fallback. Implements the RenderInterface vtable: triangle-fan +
//! stencil/cover for fills, expanded-outline + fringe for strokes. Not
//! implemented yet.
