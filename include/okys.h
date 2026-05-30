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
    OKY_STENCIL_STROKES = 1 << 1, /* stencil strokes (stencil-cover) */
};

enum OKYlineCap {
    OKY_BUTT = 0,
    OKY_ROUND = 1,
    OKY_SQUARE = 2,
};

enum OKYlineJoin {
    OKY_MITER = 0,
    OKY_ROUND_JOIN = 1,
    OKY_BEVEL = 2,
};

enum OKYwinding {
    OKY_CCW = 1,
    OKY_CW = 2,
};

/* Opaque context handle. Created with okyCreate, destroyed with okyDelete. */
typedef struct OKYcontext OKYcontext;

typedef float OKYtransform[6];

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

/* --- style ------------------------------------------------------------- */
void okyStrokeWidth(OKYcontext *ctx, float width);
void okyMiterLimit(OKYcontext *ctx, float limit);
void okyLineCap(OKYcontext *ctx, int cap);
void okyLineJoin(OKYcontext *ctx, int join);
void okyGlobalAlpha(OKYcontext *ctx, float alpha);

/* --- transforms -------------------------------------------------------- */
void okyResetTransform(OKYcontext *ctx);
void okyTransform(OKYcontext *ctx, float a, float b, float c, float d, float e,
                  float f);
void okyTranslate(OKYcontext *ctx, float x, float y);
void okyRotate(OKYcontext *ctx, float angle);
void okyScale(OKYcontext *ctx, float x, float y);
void okySkewX(OKYcontext *ctx, float angle);
void okySkewY(OKYcontext *ctx, float angle);
void okyCurrentTransform(OKYcontext *ctx, OKYtransform xform);

/* --- color helpers (pure) ---------------------------------------------- */
OKYcolor okyRGBA(unsigned char r, unsigned char g, unsigned char b,
                 unsigned char a);
OKYcolor okyRGBAf(float r, float g, float b, float a);

/* --- paints ------------------------------------------------------------ */
void okyFillColor(OKYcontext *ctx, OKYcolor color);
void okyStrokeColor(OKYcontext *ctx, OKYcolor color);
void okyFillPaint(OKYcontext *ctx, OKYpaint paint);
void okyStrokePaint(OKYcontext *ctx, OKYpaint paint);
OKYpaint okyLinearGradient(OKYcontext *ctx, float sx, float sy, float ex,
                           float ey, OKYcolor inner_color,
                           OKYcolor outer_color);
OKYpaint okyRadialGradient(OKYcontext *ctx, float cx, float cy,
                           float inner_radius, float outer_radius,
                           OKYcolor inner_color, OKYcolor outer_color);
OKYpaint okyBoxGradient(OKYcontext *ctx, float x, float y, float w, float h,
                        float radius, float feather, OKYcolor inner_color,
                        OKYcolor outer_color);
OKYpaint okyImagePattern(OKYcontext *ctx, float ox, float oy, float ex,
                         float ey, float angle, int image, float alpha);

/* --- images ------------------------------------------------------------ */
int okyCreateImageRGBA(OKYcontext *ctx, int w, int h,
                       const unsigned char *data);
void okyUpdateImage(OKYcontext *ctx, int image, const unsigned char *data);
void okyImageSize(OKYcontext *ctx, int image, int *w, int *h);
void okyDeleteImage(OKYcontext *ctx, int image);

/* --- scissor ----------------------------------------------------------- */
void okyScissor(OKYcontext *ctx, float x, float y, float w, float h);
void okyIntersectScissor(OKYcontext *ctx, float x, float y, float w, float h);
void okyResetScissor(OKYcontext *ctx);

/* --- path building ----------------------------------------------------- */
void okyBeginPath(OKYcontext *ctx);
void okyMoveTo(OKYcontext *ctx, float x, float y);
void okyLineTo(OKYcontext *ctx, float x, float y);
void okyBezierTo(OKYcontext *ctx, float c1x, float c1y, float c2x, float c2y,
                 float x, float y);
void okyQuadTo(OKYcontext *ctx, float cx, float cy, float x, float y);
void okyArcTo(OKYcontext *ctx, float x1, float y1, float x2, float y2,
              float radius);
void okyClosePath(OKYcontext *ctx);
void okyPathWinding(OKYcontext *ctx, int dir);
void okyArc(OKYcontext *ctx, float cx, float cy, float r, float a0, float a1,
            int dir);
void okyRect(OKYcontext *ctx, float x, float y, float w, float h);
void okyRoundedRect(OKYcontext *ctx, float x, float y, float w, float h,
                    float radius);
void okyRoundedRectVarying(OKYcontext *ctx, float x, float y, float w, float h,
                           float radius_top_left, float radius_top_right,
                           float radius_bottom_right,
                           float radius_bottom_left);
void okyEllipse(OKYcontext *ctx, float cx, float cy, float rx, float ry);
void okyCircle(OKYcontext *ctx, float cx, float cy, float r);

/* --- render ------------------------------------------------------------ */
void okyFill(OKYcontext *ctx);
void okyStroke(OKYcontext *ctx);

#ifdef __cplusplus
}
#endif

#endif /* OKYS_H */
