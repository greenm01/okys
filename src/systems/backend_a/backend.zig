//! Plan A backend: stencil-then-cover fill + geometric fringe AA, on sokol_gfx.
//! The proven fallback; ships first (spec §5). Implements the RenderInterface
//! vtable: triangle-fan + stencil/cover for fills, expanded-outline + fringe
//! for strokes. TODO (Milestone 1). See AGENTS/okys/architecture.md, "Plan A
//! internals".
