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
    okyBeginPath(ctx);
    okyRect(ctx, 10.0f, 10.0f, 100.0f, 100.0f);
    okyMoveTo(ctx, 0.0f, 0.0f);
    okyLineTo(ctx, 50.0f, 50.0f);
    okyBezierTo(ctx, 10.0f, 10.0f, 20.0f, 20.0f, 30.0f, 30.0f);
    okyClosePath(ctx);
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
