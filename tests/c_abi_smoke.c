/* C ABI smoke test: exercise the header against the linked static library.
 * Proves the hand-written okys.h matches the exported Zig symbols, that POD
 * crosses the boundary by value, and that a context round-trips. */

#include "okys.h"

#include <assert.h>
#include <stdio.h>

int main(void) {
    assert(okyAbiVersion() == OKY_ABI_VERSION);
    assert(okyVersionString() != NULL);

    /* POD by value across the boundary. */
    OKYcolor red = okyRGBA(255, 0, 0, 255);
    assert(red.r > 0.99f && red.g < 0.01f && red.a > 0.99f);

    OKYcontext *ctx = okyCreate(OKY_ANTIALIAS);
    assert(ctx != NULL);
    OKYcontext *sparse_ctx = okyCreate(OKY_SPARSE_STRIP);
    assert(sparse_ctx != NULL);
    OKYgraphicsDesc graphics_desc = {0};
    graphics_desc.backend = OKY_GRAPHICS_BACKEND_GL;
    graphics_desc.color_format = OKY_PIXEL_FORMAT_RGBA8;
    graphics_desc.depth_format = OKY_PIXEL_FORMAT_DEPTH_STENCIL;
    graphics_desc.sample_count = 1;
    assert(okySetupGraphics(NULL, &graphics_desc) == 0);
    assert(okySetupGraphics(sparse_ctx, NULL) == 0);
    assert(okySetRenderTarget(NULL, NULL) == 0);
    assert(okySetupGL(NULL, 1) == 0);
    okySetupWebGPU(NULL, NULL, OKY_WEBGPU_TEXTURE_FORMAT_BGRA8_UNORM);
    okySetWebGPURenderTarget(NULL, NULL, 0, 0);
    okySetupWebGPU(sparse_ctx, NULL, OKY_WEBGPU_TEXTURE_FORMAT_BGRA8_UNORM);
    okySetWebGPURenderTarget(sparse_ctx, NULL, 0, 0);
    OKYreadPixelsDesc read_desc = {0};
    unsigned char readback_pixels[16] = {0};
    read_desc.w = 1;
    read_desc.h = 1;
    read_desc.format = OKY_PIXEL_FORMAT_RGBA8;
    read_desc.dst_stride_bytes = 4;
    read_desc.dst = readback_pixels;
    assert(okyReadPixels(NULL, &read_desc) == OKY_READ_PIXELS_NO_GRAPHICS_RUNTIME);
    assert(okyReadPixels(sparse_ctx, NULL) == OKY_READ_PIXELS_INVALID_ARGUMENT);
    assert(okyReadPixels(sparse_ctx, &read_desc) == OKY_READ_PIXELS_NO_GRAPHICS_RUNTIME);
    okyDelete(sparse_ctx);

    okyBeginFrame(ctx, 800.0f, 600.0f, 1.0f);

    okySave(ctx);
    okyStrokeWidth(ctx, 2.0f);
    okyMiterLimit(ctx, 4.0f);
    okyLineCap(ctx, OKY_ROUND);
    okyLineJoin(ctx, OKY_BEVEL);
    float dash[2] = {6.0f, 3.0f};
    okyLineDash(ctx, dash, 2);
    okyLineDashOffset(ctx, 1.5f);
    okyGlobalAlpha(ctx, 0.75f);

    okyTranslate(ctx, 10.0f, 20.0f);
    okyRotate(ctx, 0.1f);
    okyScale(ctx, 2.0f, 2.0f);
    okySkewX(ctx, 0.05f);
    okySkewY(ctx, -0.02f);
    okyTransform(ctx, 1.0f, 0.0f, 0.0f, 1.0f, 3.0f, 4.0f);
    OKYtransform current;
    okyCurrentTransform(ctx, current);
    okyResetTransform(ctx);

    OKYpaint lg = okyLinearGradient(ctx, 0.0f, 0.0f, 100.0f, 0.0f, red,
                                    okyRGBAf(0.0f, 0.0f, 1.0f, 1.0f));
    OKYpaint rg = okyRadialGradient(ctx, 50.0f, 50.0f, 5.0f, 20.0f, red, red);
    OKYpaint bg =
        okyBoxGradient(ctx, 0.0f, 0.0f, 100.0f, 80.0f, 5.0f, 10.0f, red, red);
    OKYpaint ip =
        okyImagePattern(ctx, 0.0f, 0.0f, 32.0f, 32.0f, 0.0f, 7, 0.5f);
    assert(lg.feather >= 1.0f && rg.radius > 0.0f && bg.extent[0] > 0.0f);
    assert(ip.image == 7);
    okyFillPaint(ctx, lg);
    okyStrokePaint(ctx, rg);

    unsigned char pixels[16] = {
        255, 0,   0,   255,
        0,   255, 0,   255,
        0,   0,   255, 255,
        255, 255, 255, 255,
    };
    int image = okyCreateImageRGBA(ctx, 2, 2, pixels);
    assert(image == 0);
    unsigned char bad_image[] = {'n', 'o', 'p', 'e'};
    assert(okyCreateImageMem(ctx, bad_image, (int)sizeof(bad_image)) == 0);
    assert(okyCreateImageMem(ctx, NULL, 0) == 0);
    assert(okyCreateImage(ctx, "/path/to/no/such/okys-image.qoi") == 0);
    assert(okyCreateImage(ctx, NULL) == 0);
    int image_w = 123;
    int image_h = 456;
    okyImageSize(ctx, image, &image_w, &image_h);
    assert(image_w == 0 && image_h == 0);
    okyUpdateImage(ctx, image, pixels);
    okyDeleteImage(ctx, image);

    okyScissor(ctx, 0.0f, 0.0f, 200.0f, 200.0f);
    okyIntersectScissor(ctx, 50.0f, 50.0f, 100.0f, 100.0f);
    okyResetScissor(ctx);

    okyBeginPath(ctx);
    okyRect(ctx, 10.0f, 10.0f, 100.0f, 100.0f);
    okyMoveTo(ctx, 0.0f, 0.0f);
    okyLineTo(ctx, 50.0f, 50.0f);
    okyBezierTo(ctx, 10.0f, 10.0f, 20.0f, 20.0f, 30.0f, 30.0f);
    okyQuadTo(ctx, 40.0f, 40.0f, 50.0f, 20.0f);
    okyArcTo(ctx, 60.0f, 20.0f, 80.0f, 40.0f, 5.0f);
    okyArc(ctx, 80.0f, 80.0f, 10.0f, 0.0f, 3.14159265f, OKY_CW);
    okyPathWinding(ctx, OKY_CW);
    okyClosePath(ctx);
    okyRoundedRect(ctx, 10.0f, 10.0f, 60.0f, 40.0f, 4.0f);
    okyRoundedRectVarying(ctx, 10.0f, 10.0f, 60.0f, 40.0f, 1.0f, 2.0f,
                          3.0f, 4.0f);
    okyEllipse(ctx, 30.0f, 30.0f, 10.0f, 20.0f);
    okyCircle(ctx, 30.0f, 30.0f, 10.0f);
    okyFillColor(ctx, okyRGBAf(0.2f, 0.4f, 0.8f, 1.0f));
    okyStrokeColor(ctx, red);
    okyFill(ctx);
    okyStroke(ctx);

    const char *sample = "one two three";
    assert(okyCreateFont(ctx, NULL, NULL) == 0);
    assert(okyCreateFontMem(ctx, "bad", NULL, 0, 0) == 0);
    int sans = okyCreateFont(ctx, "sans", "/usr/share/fonts/TTF/DejaVuSans.ttf");
    if (sans > 0) {
        assert(okyFindFont(ctx, "sans") == sans);
        okyFontFaceId(ctx, sans);
        okyFontSize(ctx, 18.0f);
    }
    okyTextAlign(ctx, OKY_ALIGN_LEFT | OKY_ALIGN_BASELINE);
    okyTextLetterSpacing(ctx, 0.0f);
    okyTextLineHeight(ctx, 1.0f);
    okyFontFaceId(ctx, 0);
    okyFontSize(ctx, 16.0f);

    float tx = okyText(ctx, 10.0f, 20.0f, sample, sample + 3);
    assert(tx > 33.9f && tx < 34.1f);
    float text_bounds[4] = {0.0f, 0.0f, 0.0f, 0.0f};
    float measured = okyTextBounds(ctx, 10.0f, 20.0f, sample, sample + 3,
                                   text_bounds);
    assert(measured > 23.9f && measured < 24.1f);
    assert(text_bounds[0] > 9.9f && text_bounds[0] < 10.1f);
    assert(text_bounds[1] > 7.1f && text_bounds[1] < 7.3f);
    assert(text_bounds[2] > 33.9f && text_bounds[2] < 34.1f);
    assert(text_bounds[3] > 23.1f && text_bounds[3] < 23.3f);
    assert(okyTextBounds(ctx, 0.0f, 0.0f, sample, sample + 3, NULL) > 23.9f);
    okyTextBox(ctx, 0.0f, 0.0f, 56.0f, sample, NULL);

    float ascender = 0.0f;
    float descender = 0.0f;
    float lineh = 0.0f;
    okyTextMetrics(ctx, &ascender, &descender, &lineh);
    assert(ascender > 12.7f && descender < -3.1f && lineh > 22.3f);

    OKYglyphPosition positions[8];
    int position_count =
        okyTextGlyphPositions(ctx, 5.0f, 6.0f, sample, sample + 3, positions, 8);
    assert(position_count == 3);
    assert(positions[0].str == sample && positions[1].str == sample + 1);
    assert(positions[2].maxx > 28.9f && positions[2].maxx < 29.1f);

    OKYtextRow rows[4];
    int row_count = okyTextBreakLines(ctx, sample, NULL, 56.0f, rows, 4);
    assert(row_count == 2);
    assert(rows[0].start == sample && rows[0].end == sample + 7);
    assert(rows[0].next == sample + 8);
    okyRestore(ctx);

    okyEndFrame(ctx);
    okyDelete(ctx);

    printf("okys c abi smoke ok\n");
    return 0;
}
