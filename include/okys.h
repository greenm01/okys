#ifndef OKYS_H
#define OKYS_H

/*
 * okys - a 2D vector graphics library with a NanoVG-style canvas API.
 *
 * SPDX-License-Identifier: BSD-3-Clause
 * Copyright (c) 2026, Mason Austin Green
 *
 * This header is the canonical ABI contract. It is maintained by hand; the Zig
 * `export fn` signatures must match it exactly.
 */

#ifdef __cplusplus
extern "C" {
#endif

#define OKY_ABI_VERSION 0u

/* Context creation flags. Mirror NanoVG's flag spirit. */
enum OKYcreateFlags {
    OKY_ANTIALIAS = 1 << 0,       /* geometric / analytic antialiasing  */
    OKY_STENCIL_STROKES = 1 << 1, /* stencil strokes (Plan A)           */
};

/* Opaque context handle. Created with okyCreate, destroyed with okyDelete. */
typedef struct OKYcontext OKYcontext;

/* RGBA color, components in 0..1. POD, passed by value. */
typedef union OKYcolor {
    float rgba[4];
    struct {
        float r, g, b, a;
    };
} OKYcolor;

/* Paint descriptor. Resolved in the shader; no CPU-side gradient baking. */
typedef struct OKYpaint {
    float xform[6];
    float extent[2];
    float radius;
    float feather;
    OKYcolor inner_color;
    OKYcolor outer_color;
    int image;
} OKYpaint;

/* --- version / abi ----------------------------------------------------- */
unsigned int okyAbiVersion(void);
const char *okyVersionString(void);

/* --- lifecycle --------------------------------------------------------- */
OKYcontext *okyCreate(int flags);
void okyDelete(OKYcontext *ctx);

/* --- frame ------------------------------------------------------------- */
void okyBeginFrame(OKYcontext *ctx, float window_width, float window_height,
                   float device_pixel_ratio);
void okyEndFrame(OKYcontext *ctx);
void okyCancelFrame(OKYcontext *ctx);

/* --- state stack ------------------------------------------------------- */
void okySave(OKYcontext *ctx);
void okyRestore(OKYcontext *ctx);
void okyReset(OKYcontext *ctx);

/* --- color helpers (pure) ---------------------------------------------- */
OKYcolor okyRGBA(unsigned char r, unsigned char g, unsigned char b,
                 unsigned char a);
OKYcolor okyRGBAf(float r, float g, float b, float a);

/* --- paints ------------------------------------------------------------ */
void okyFillColor(OKYcontext *ctx, OKYcolor color);
void okyStrokeColor(OKYcontext *ctx, OKYcolor color);

/* --- path building ----------------------------------------------------- */
void okyBeginPath(OKYcontext *ctx);
void okyMoveTo(OKYcontext *ctx, float x, float y);
void okyLineTo(OKYcontext *ctx, float x, float y);
void okyBezierTo(OKYcontext *ctx, float c1x, float c1y, float c2x, float c2y,
                 float x, float y);
void okyClosePath(OKYcontext *ctx);
void okyRect(OKYcontext *ctx, float x, float y, float w, float h);

/* --- render ------------------------------------------------------------ */
void okyFill(OKYcontext *ctx);
void okyStroke(OKYcontext *ctx);

#ifdef __cplusplus
}
#endif

#endif /* OKYS_H */
