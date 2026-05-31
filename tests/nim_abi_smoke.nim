import std/math

const
  OKY_ANTIALIAS* = 1 shl 0
  OKY_SPARSE_STRIP* = 1 shl 2
  OKY_ROUND* = 1
  OKY_BEVEL* = 2
  OKY_CW* = 2

type
  OKYcontext {.importc: "OKYcontext", header: "okys.h", incompleteStruct.} = object

  OKYtransform = array[6, cfloat]

  OKYcolor {.importc: "OKYcolor", header: "okys.h", bycopy, union.} = object
    rgba {.importc: "rgba".}: array[4, cfloat]

  OKYpaint {.importc: "OKYpaint", header: "okys.h", bycopy.} = object
    xform: array[6, cfloat]
    extent: array[2, cfloat]
    radius: cfloat
    feather: cfloat
    inner_color: OKYcolor
    outer_color: OKYcolor
    image: cint

proc okyAbiVersion(): cuint {.importc, header: "okys.h".}
proc okyVersionString(): cstring {.importc, header: "okys.h".}

proc okyCreate(flags: cint): ptr OKYcontext {.importc, header: "okys.h".}
proc okyDelete(ctx: ptr OKYcontext) {.importc, header: "okys.h".}

proc okyBeginFrame(ctx: ptr OKYcontext; w, h, dpr: cfloat) {.importc, header: "okys.h".}
proc okyEndFrame(ctx: ptr OKYcontext) {.importc, header: "okys.h".}
proc okyCancelFrame(ctx: ptr OKYcontext) {.importc, header: "okys.h".}

proc okySave(ctx: ptr OKYcontext) {.importc, header: "okys.h".}
proc okyRestore(ctx: ptr OKYcontext) {.importc, header: "okys.h".}
proc okyReset(ctx: ptr OKYcontext) {.importc, header: "okys.h".}

proc okyStrokeWidth(ctx: ptr OKYcontext; width: cfloat) {.importc, header: "okys.h".}
proc okyMiterLimit(ctx: ptr OKYcontext; limit: cfloat) {.importc, header: "okys.h".}
proc okyLineCap(ctx: ptr OKYcontext; cap: cint) {.importc, header: "okys.h".}
proc okyLineJoin(ctx: ptr OKYcontext; join: cint) {.importc, header: "okys.h".}
proc okyLineDash(ctx: ptr OKYcontext; pattern: ptr cfloat; count: cint) {.importc, header: "okys.h".}
proc okyLineDashOffset(ctx: ptr OKYcontext; offset: cfloat) {.importc, header: "okys.h".}
proc okyGlobalAlpha(ctx: ptr OKYcontext; alpha: cfloat) {.importc, header: "okys.h".}

proc okyResetTransform(ctx: ptr OKYcontext) {.importc, header: "okys.h".}
proc okyTransform(ctx: ptr OKYcontext; a, b, c, d, e, f: cfloat) {.importc, header: "okys.h".}
proc okyTranslate(ctx: ptr OKYcontext; x, y: cfloat) {.importc, header: "okys.h".}
proc okyRotate(ctx: ptr OKYcontext; angle: cfloat) {.importc, header: "okys.h".}
proc okyScale(ctx: ptr OKYcontext; x, y: cfloat) {.importc, header: "okys.h".}
proc okySkewX(ctx: ptr OKYcontext; angle: cfloat) {.importc, header: "okys.h".}
proc okySkewY(ctx: ptr OKYcontext; angle: cfloat) {.importc, header: "okys.h".}
proc okyCurrentTransform(ctx: ptr OKYcontext; xform: ptr cfloat) {.importc, header: "okys.h".}

proc okyRGBA(r, g, b, a: uint8): OKYcolor {.importc, header: "okys.h".}
proc okyRGBAf(r, g, b, a: cfloat): OKYcolor {.importc, header: "okys.h".}

proc okyFillColor(ctx: ptr OKYcontext; color: OKYcolor) {.importc, header: "okys.h".}
proc okyStrokeColor(ctx: ptr OKYcontext; color: OKYcolor) {.importc, header: "okys.h".}
proc okyFillPaint(ctx: ptr OKYcontext; paint: OKYpaint) {.importc, header: "okys.h".}
proc okyStrokePaint(ctx: ptr OKYcontext; paint: OKYpaint) {.importc, header: "okys.h".}
proc okyLinearGradient(ctx: ptr OKYcontext; sx, sy, ex, ey: cfloat; inner, outer: OKYcolor): OKYpaint {.importc, header: "okys.h".}
proc okyRadialGradient(ctx: ptr OKYcontext; cx, cy, innerRadius, outerRadius: cfloat; inner, outer: OKYcolor): OKYpaint {.importc, header: "okys.h".}
proc okyBoxGradient(ctx: ptr OKYcontext; x, y, w, h, radius, feather: cfloat; inner, outer: OKYcolor): OKYpaint {.importc, header: "okys.h".}
proc okyImagePattern(ctx: ptr OKYcontext; ox, oy, ex, ey, angle: cfloat; image: cint; alpha: cfloat): OKYpaint {.importc, header: "okys.h".}

proc okyCreateImageRGBA(ctx: ptr OKYcontext; w, h: cint; data: ptr uint8): cint {.importc, header: "okys.h".}
proc okyUpdateImage(ctx: ptr OKYcontext; image: cint; data: ptr uint8) {.importc, header: "okys.h".}
proc okyImageSize(ctx: ptr OKYcontext; image: cint; w, h: ptr cint) {.importc, header: "okys.h".}
proc okyDeleteImage(ctx: ptr OKYcontext; image: cint) {.importc, header: "okys.h".}

proc okyScissor(ctx: ptr OKYcontext; x, y, w, h: cfloat) {.importc, header: "okys.h".}
proc okyIntersectScissor(ctx: ptr OKYcontext; x, y, w, h: cfloat) {.importc, header: "okys.h".}
proc okyResetScissor(ctx: ptr OKYcontext) {.importc, header: "okys.h".}

proc okyBeginPath(ctx: ptr OKYcontext) {.importc, header: "okys.h".}
proc okyMoveTo(ctx: ptr OKYcontext; x, y: cfloat) {.importc, header: "okys.h".}
proc okyLineTo(ctx: ptr OKYcontext; x, y: cfloat) {.importc, header: "okys.h".}
proc okyBezierTo(ctx: ptr OKYcontext; c1x, c1y, c2x, c2y, x, y: cfloat) {.importc, header: "okys.h".}
proc okyQuadTo(ctx: ptr OKYcontext; cx, cy, x, y: cfloat) {.importc, header: "okys.h".}
proc okyArcTo(ctx: ptr OKYcontext; x1, y1, x2, y2, radius: cfloat) {.importc, header: "okys.h".}
proc okyClosePath(ctx: ptr OKYcontext) {.importc, header: "okys.h".}
proc okyPathWinding(ctx: ptr OKYcontext; dir: cint) {.importc, header: "okys.h".}
proc okyArc(ctx: ptr OKYcontext; cx, cy, r, a0, a1: cfloat; dir: cint) {.importc, header: "okys.h".}
proc okyRect(ctx: ptr OKYcontext; x, y, w, h: cfloat) {.importc, header: "okys.h".}
proc okyRoundedRect(ctx: ptr OKYcontext; x, y, w, h, radius: cfloat) {.importc, header: "okys.h".}
proc okyRoundedRectVarying(ctx: ptr OKYcontext; x, y, w, h, rtl, rtr, rbr, rbl: cfloat) {.importc, header: "okys.h".}
proc okyEllipse(ctx: ptr OKYcontext; cx, cy, rx, ry: cfloat) {.importc, header: "okys.h".}
proc okyCircle(ctx: ptr OKYcontext; cx, cy, r: cfloat) {.importc, header: "okys.h".}

proc okyFill(ctx: ptr OKYcontext) {.importc, header: "okys.h".}
proc okyStroke(ctx: ptr OKYcontext) {.importc, header: "okys.h".}

proc near(a, b: cfloat): bool =
  abs(float(a - b)) < 0.001

doAssert okyAbiVersion() == 0'u32
doAssert okyVersionString() != nil
doAssert sizeof(OKYcolor) == 16
doAssert sizeof(OKYpaint) == 76

let red = okyRGBA(255'u8, 0'u8, 0'u8, 255'u8)
doAssert near(red.rgba[0], 1.0)
doAssert near(red.rgba[1], 0.0)
doAssert near(red.rgba[3], 1.0)

let blue = okyRGBAf(0.0, 0.0, 1.0, 1.0)
let ctx = okyCreate(OKY_ANTIALIAS)
doAssert ctx != nil
let sparseCtx = okyCreate(OKY_SPARSE_STRIP)
doAssert sparseCtx != nil
okyDelete(sparseCtx)

okyBeginFrame(ctx, 800.0, 600.0, 1.0)

okySave(ctx)
okyStrokeWidth(ctx, 2.0)
okyMiterLimit(ctx, 4.0)
okyLineCap(ctx, OKY_ROUND)
okyLineJoin(ctx, OKY_BEVEL)
var dash = [6.0.cfloat, 3.0.cfloat]
okyLineDash(ctx, addr dash[0], 2)
okyLineDashOffset(ctx, 1.5)
okyGlobalAlpha(ctx, 0.75)

okyTranslate(ctx, 10.0, 20.0)
okyRotate(ctx, 0.1)
okyScale(ctx, 2.0, 2.0)
okySkewX(ctx, 0.05)
okySkewY(ctx, -0.02)
okyTransform(ctx, 1.0, 0.0, 0.0, 1.0, 3.0, 4.0)
var current: OKYtransform
okyCurrentTransform(ctx, addr current[0])
okyResetTransform(ctx)

let lg = okyLinearGradient(ctx, 0.0, 0.0, 100.0, 0.0, red, blue)
let rg = okyRadialGradient(ctx, 50.0, 50.0, 5.0, 20.0, red, blue)
let bg = okyBoxGradient(ctx, 0.0, 0.0, 100.0, 80.0, 5.0, 10.0, red, blue)
let ip = okyImagePattern(ctx, 0.0, 0.0, 32.0, 32.0, 0.0, 7, 0.5)
doAssert lg.feather >= 1.0
doAssert rg.radius > 0.0
doAssert bg.extent[0] > 0.0
doAssert ip.image == 7
okyFillPaint(ctx, lg)
okyStrokePaint(ctx, rg)

var pixels = [
  255'u8, 0'u8, 0'u8, 255'u8,
  0'u8, 255'u8, 0'u8, 255'u8,
  0'u8, 0'u8, 255'u8, 255'u8,
  255'u8, 255'u8, 255'u8, 255'u8,
]
let image = okyCreateImageRGBA(ctx, 2, 2, addr pixels[0])
doAssert image == 0
var imageW: cint = 123
var imageH: cint = 456
okyImageSize(ctx, image, addr imageW, addr imageH)
doAssert imageW == 0 and imageH == 0
okyUpdateImage(ctx, image, addr pixels[0])
okyDeleteImage(ctx, image)

okyScissor(ctx, 0.0, 0.0, 200.0, 200.0)
okyIntersectScissor(ctx, 50.0, 50.0, 100.0, 100.0)
okyResetScissor(ctx)

okyBeginPath(ctx)
okyRect(ctx, 10.0, 10.0, 100.0, 100.0)
okyMoveTo(ctx, 0.0, 0.0)
okyLineTo(ctx, 50.0, 50.0)
okyBezierTo(ctx, 10.0, 10.0, 20.0, 20.0, 30.0, 30.0)
okyQuadTo(ctx, 40.0, 40.0, 50.0, 20.0)
okyArcTo(ctx, 60.0, 20.0, 80.0, 40.0, 5.0)
okyArc(ctx, 80.0, 80.0, 10.0, 0.0, PI, OKY_CW)
okyPathWinding(ctx, OKY_CW)
okyClosePath(ctx)
okyRoundedRect(ctx, 10.0, 10.0, 60.0, 40.0, 4.0)
okyRoundedRectVarying(ctx, 10.0, 10.0, 60.0, 40.0, 1.0, 2.0, 3.0, 4.0)
okyEllipse(ctx, 30.0, 30.0, 10.0, 20.0)
okyCircle(ctx, 30.0, 30.0, 10.0)
okyFillColor(ctx, okyRGBAf(0.2, 0.4, 0.8, 1.0))
okyStrokeColor(ctx, red)
okyFill(ctx)
okyStroke(ctx)
okyRestore(ctx)

okyEndFrame(ctx)
okyCancelFrame(ctx)
okyReset(ctx)
okyDelete(ctx)

echo "okys nim abi smoke ok"
