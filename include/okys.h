#ifndef OKYS_H
#define OKYS_H

#include <stdint.h>

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
#define OKY_MAX_LINE_DASHES 16

/* Context creation flags. Mirror NanoVG's flag spirit. */
enum OKYcreateFlags {
    OKY_ANTIALIAS = 1 << 0,       /* geometric / analytic antialiasing  */
    OKY_STENCIL_STROKES = 1 << 1, /* stencil strokes (stencil-cover) */
    OKY_SPARSE_STRIP = 1 << 2,    /* sparse-strip backend */
};

enum OKYwebGPUTextureFormat {
    OKY_WEBGPU_TEXTURE_FORMAT_BGRA8_UNORM = 1,
    OKY_WEBGPU_TEXTURE_FORMAT_RGBA8_UNORM = 2,
};

enum OKYgraphicsBackend {
    OKY_GRAPHICS_BACKEND_GL = 1,
    OKY_GRAPHICS_BACKEND_METAL = 2,
    OKY_GRAPHICS_BACKEND_D3D11 = 3,
    OKY_GRAPHICS_BACKEND_VULKAN = 4,
    OKY_GRAPHICS_BACKEND_WEBGPU = 5,
};

enum OKYpixelFormat {
    OKY_PIXEL_FORMAT_NONE = 0,
    OKY_PIXEL_FORMAT_BGRA8 = 1,
    OKY_PIXEL_FORMAT_RGBA8 = 2,
    OKY_PIXEL_FORMAT_DEPTH_STENCIL = 3,
    OKY_PIXEL_FORMAT_DEPTH = 4,
};

enum OKYimageFlags {
    OKY_IMAGE_FLAGS_NONE = 0,
};

enum OKYreadPixelsStatus {
    OKY_READ_PIXELS_OK = 1,
    OKY_READ_PIXELS_INVALID_ARGUMENT = -1,
    OKY_READ_PIXELS_UNSUPPORTED_BACKEND = -2,
    OKY_READ_PIXELS_NO_GRAPHICS_RUNTIME = -3,
    OKY_READ_PIXELS_BACKEND_FAILURE = -4,
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

enum OKYalign {
    OKY_ALIGN_LEFT = 1 << 0,
    OKY_ALIGN_CENTER = 1 << 1,
    OKY_ALIGN_RIGHT = 1 << 2,
    OKY_ALIGN_TOP = 1 << 3,
    OKY_ALIGN_MIDDLE = 1 << 4,
    OKY_ALIGN_BOTTOM = 1 << 5,
    OKY_ALIGN_BASELINE = 1 << 6,
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

typedef struct OKYglyphPosition {
    const char *str;
    float x;
    float minx;
    float maxx;
} OKYglyphPosition;

typedef struct OKYtextRow {
    const char *start;
    const char *end;
    const char *next;
    float width;
    float minx;
    float maxx;
} OKYtextRow;

typedef struct OKYgraphicsDesc {
    int backend;
    int color_format;
    int depth_format;
    int sample_count;

    const void *metal_device;

    const void *d3d11_device;
    const void *d3d11_device_context;

    const void *vulkan_instance;
    const void *vulkan_physical_device;
    const void *vulkan_device;
    const void *vulkan_queue;
    uint32_t vulkan_queue_family_index;

    const void *webgpu_device;
} OKYgraphicsDesc;

typedef struct OKYrenderTarget {
    int backend;
    int width_px;
    int height_px;
    int color_format;
    int depth_format;
    int sample_count;

    uint32_t gl_framebuffer;

    const void *metal_current_drawable;
    const void *metal_depth_stencil_texture;
    const void *metal_msaa_color_texture;

    const void *d3d11_render_view;
    const void *d3d11_resolve_view;
    const void *d3d11_depth_stencil_view;

    const void *vulkan_render_image;
    const void *vulkan_render_view;
    const void *vulkan_resolve_image;
    const void *vulkan_resolve_view;
    const void *vulkan_depth_stencil_image;
    const void *vulkan_depth_stencil_view;
    const void *vulkan_render_finished_semaphore;
    const void *vulkan_present_complete_semaphore;

    const void *webgpu_render_view;
    const void *webgpu_resolve_view;
    const void *webgpu_depth_stencil_view;
} OKYrenderTarget;

typedef struct OKYreadPixelsDesc {
    int x;
    int y;
    int w;
    int h;
    int format;
    int dst_stride_bytes;
    unsigned char *dst;
} OKYreadPixelsDesc;

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

/* --- WebGPU bridge ----------------------------------------------------- */
int okySetupGraphics(OKYcontext *ctx, const OKYgraphicsDesc *desc);
int okySetRenderTarget(OKYcontext *ctx, const OKYrenderTarget *target);
int okyReadPixels(OKYcontext *ctx, const OKYreadPixelsDesc *desc);
int okySetupGL(OKYcontext *ctx, int sample_count);
void okySetupWebGPU(OKYcontext *ctx, const void *wgpu_device,
                    int color_format);
void okySetupWebGPUWithDepth(OKYcontext *ctx, const void *wgpu_device,
                             int color_format, int depth_format);
void okySetWebGPURenderTarget(OKYcontext *ctx, const void *color_texture_view,
                              int width_px, int height_px);
void okySetWebGPURenderTargetWithDepth(OKYcontext *ctx,
                                       const void *color_texture_view,
                                       const void *depth_stencil_texture_view,
                                       int width_px, int height_px);

/* --- state stack ------------------------------------------------------- */
void okySave(OKYcontext *ctx);
void okyRestore(OKYcontext *ctx);
void okyReset(OKYcontext *ctx);

/* --- style ------------------------------------------------------------- */
void okyStrokeWidth(OKYcontext *ctx, float width);
void okyMiterLimit(OKYcontext *ctx, float limit);
void okyLineCap(OKYcontext *ctx, int cap);
void okyLineJoin(OKYcontext *ctx, int join);
void okyLineDash(OKYcontext *ctx, const float *pattern, int count);
void okyLineDashOffset(OKYcontext *ctx, float offset);
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
int okyCreateImageRGBAEx(OKYcontext *ctx, int w, int h,
                         const unsigned char *data, int stride_bytes,
                         int flags);
void okyUpdateImage(OKYcontext *ctx, int image, const unsigned char *data);
void okyDrawImage(OKYcontext *ctx, float x, float y, float w, float h,
                  int image, float alpha);
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

/* --- text --------------------------------------------------------------- */
int okyCreateFont(OKYcontext *ctx, const char *name, const char *filename);
int okyCreateFontMem(OKYcontext *ctx, const char *name, unsigned char *data,
                     int ndata, int free_data);
int okyFindFont(OKYcontext *ctx, const char *name);
void okyFontSize(OKYcontext *ctx, float size);
void okyFontFaceId(OKYcontext *ctx, int font);
void okyFontFace(OKYcontext *ctx, const char *font);
void okyTextAlign(OKYcontext *ctx, int align);
void okyTextLetterSpacing(OKYcontext *ctx, float spacing);
void okyTextLineHeight(OKYcontext *ctx, float line_height);
float okyText(OKYcontext *ctx, float x, float y, const char *string,
              const char *end);
void okyTextBox(OKYcontext *ctx, float x, float y, float break_row_width,
                const char *string, const char *end);
float okyTextBounds(OKYcontext *ctx, float x, float y, const char *string,
                    const char *end, float *bounds);
int okyTextGlyphPositions(OKYcontext *ctx, float x, float y,
                          const char *string, const char *end,
                          OKYglyphPosition *positions, int max_positions);
void okyTextMetrics(OKYcontext *ctx, float *ascender, float *descender,
                    float *lineh);
int okyTextBreakLines(OKYcontext *ctx, const char *string, const char *end,
                      float break_row_width, OKYtextRow *rows, int max_rows);

/* --- render ------------------------------------------------------------ */
void okyFill(OKYcontext *ctx);
void okyStroke(OKYcontext *ctx);

#ifdef __cplusplus
}
#endif

#endif /* OKYS_H */
