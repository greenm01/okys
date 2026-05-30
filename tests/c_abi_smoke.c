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

    okyBeginFrame(ctx, 800.0f, 600.0f, 1.0f);

    okySave(ctx);
    okyStrokeWidth(ctx, 2.0f);
    okyMiterLimit(ctx, 4.0f);
    okyLineCap(ctx, OKY_ROUND);
    okyLineJoin(ctx, OKY_BEVEL);
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
    okyRestore(ctx);

    okyEndFrame(ctx);
    okyDelete(ctx);

    printf("okys c abi smoke ok\n");
    return 0;
}
