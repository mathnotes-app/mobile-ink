#import <CoreGraphics/CoreGraphics.h>
#include "BackgroundRenderer.h"
#include "DrawingSerialization.h"
#include "SkiaDrawingEngine.h"

#include <algorithm>
#include <cmath>
#include <include/core/SkColorSpace.h>
#include <include/core/SkData.h>
#include <include/core/SkPixmap.h>
#include <include/core/SkRRect.h>
#include <include/core/SkSurface.h>
#include <include/utils/SkNoDrawCanvas.h>

namespace {

using nativedrawing::Stroke;

CGMutablePathRef quartzPath(const SkPath& path) {
    CGMutablePathRef output = CGPathCreateMutable();
    SkPath::Iter iterator(path, false);
    SkPoint point[4];
    for (;;) {
        switch (iterator.next(point)) {
            case SkPath::kMove_Verb:
                CGPathMoveToPoint(output, nullptr, point[0].x(), point[0].y());
                break;
            case SkPath::kLine_Verb:
                CGPathAddLineToPoint(output, nullptr, point[1].x(), point[1].y());
                break;
            case SkPath::kQuad_Verb:
                CGPathAddQuadCurveToPoint(output, nullptr, point[1].x(), point[1].y(), point[2].x(), point[2].y());
                break;
            case SkPath::kConic_Verb: {
                // PDF supports quadratic curves. Approximate rational arcs
                // with eight quadratics, preserving geometry at deep zoom.
                SkPoint quads[17];
                const int count = SkPath::ConvertConicToQuads(point[0], point[1], point[2], iterator.conicWeight(), quads, 3);
                for (int index = 0; index < count; ++index) {
                    const auto& control = quads[2 * index + 1];
                    const auto& end = quads[2 * index + 2];
                    CGPathAddQuadCurveToPoint(output, nullptr, control.x(), control.y(), end.x(), end.y());
                }
                break;
            }
            case SkPath::kCubic_Verb:
                CGPathAddCurveToPoint(output, nullptr, point[1].x(), point[1].y(),
                    point[2].x(), point[2].y(), point[3].x(), point[3].y());
                break;
            case SkPath::kClose_Verb:
                CGPathCloseSubpath(output);
                break;
            case SkPath::kDone_Verb:
                return output;
        }
    }
}

class QuartzInkCanvas final : public SkNoDrawCanvas {
public:
    QuartzInkCanvas(CGContextRef context, int width, int height)
        : SkNoDrawCanvas(width, height), context_(context),
          page_(SkRect::MakeWH(width, height)) {}

    bool supports(const Stroke& stroke) const {
        if (stroke.erasedBy.empty()) return true;
        stroke.ensureEraserCacheValid();
        if (stroke.cachedEraserPath.isEmpty()) return true;
        SkPath clip;
        return Op(SkPath::Rect(page_), stroke.cachedEraserPath, kDifference_SkPathOp, &clip);
    }

private:
    void willSave() override { CGContextSaveGState(context_); }
    void willRestore() override { CGContextRestoreGState(context_); }

    void onClipRect(const SkRect& rect, SkClipOp op, ClipEdgeStyle edge) override {
        onClipPath(SkPath::Rect(rect), op, edge);
    }

    void onClipRRect(const SkRRect& rect, SkClipOp op, ClipEdgeStyle edge) override {
        onClipPath(SkPath::RRect(rect), op, edge);
    }

    void onClipPath(const SkPath& path, SkClipOp op, ClipEdgeStyle) override {
        SkPath region = path;
        if (op == SkClipOp::kDifference) {
            if (!Op(SkPath::Rect(page_), path, kDifference_SkPathOp, &region)) return;
        }
        CGPathRef clip = quartzPath(region);
        CGContextAddPath(context_, clip);
        if (region.getFillType() == SkPathFillType::kEvenOdd) CGContextEOClip(context_);
        else CGContextClip(context_);
        CGPathRelease(clip);
    }

    void onDrawPoints(PointMode mode, size_t count, const SkPoint points[], const SkPaint& paint) override {
        if (mode == kPoints_PointMode || count < 2) return;
        SkPath path;
        path.moveTo(points[0]);
        for (size_t i = 1; i < count; ++i) {
            if (mode == kLines_PointMode && i % 2 == 0) path.moveTo(points[i]);
            else path.lineTo(points[i]);
        }
        SkPaint stroke = paint;
        stroke.setStyle(SkPaint::kStroke_Style);
        onDrawPath(path, stroke);
    }

    void onDrawOval(const SkRect& rect, const SkPaint& paint) override {
        SkPath path;
        path.addOval(rect);
        onDrawPath(path, paint);
    }

    void onDrawPath(const SkPath& path, const SkPaint& paint) override {
        if (path.isEmpty()) return;
        CGContextSetBlendMode(context_,
            paint.asBlendMode() == SkBlendMode::kMultiply ? kCGBlendModeMultiply : kCGBlendModeNormal);
        const SkColor color = paint.getColor();
        constexpr CGFloat unit = 1.0 / 255.0;
        const CGFloat red = SkColorGetR(color) * unit;
        const CGFloat green = SkColorGetG(color) * unit;
        const CGFloat blue = SkColorGetB(color) * unit;
        const CGFloat alpha = SkColorGetA(color) * unit;
        CGContextSetRGBFillColor(context_, red, green, blue, alpha);
        CGContextSetRGBStrokeColor(context_, red, green, blue, alpha);
        CGContextSetLineWidth(context_, paint.getStrokeWidth());
        CGContextSetMiterLimit(context_, paint.getStrokeMiter());
        CGContextSetLineCap(context_, static_cast<CGLineCap>(paint.getStrokeCap()));
        CGContextSetLineJoin(context_, static_cast<CGLineJoin>(paint.getStrokeJoin()));
        CGPathRef shape = quartzPath(path);
        CGContextAddPath(context_, shape);
        CGPathRelease(shape);
        const bool evenOdd = path.getFillType() == SkPathFillType::kEvenOdd;
        switch (paint.getStyle()) {
            case SkPaint::kFill_Style:
                CGContextDrawPath(context_, evenOdd ? kCGPathEOFill : kCGPathFill);
                break;
            case SkPaint::kStroke_Style:
                CGContextStrokePath(context_);
                break;
            case SkPaint::kStrokeAndFill_Style:
                CGContextDrawPath(context_, evenOdd ? kCGPathEOFillStroke : kCGPathFillStroke);
                break;
        }
    }

    CGContextRef context_;
    SkRect page_;
};

bool drawRasterRange(CGContextRef context, nativedrawing::SkiaDrawingEngine& engine,
                     const std::vector<Stroke>& strokes, size_t start, size_t stop,
                     int width, int height, float density) {
    const float scale = std::min(density, std::sqrt(16000000.0f / (float(width) * height)));
    const int pixelsWide = std::max(1, static_cast<int>(std::ceil(width * scale)));
    const int pixelsHigh = std::max(1, static_cast<int>(std::ceil(height * scale)));
    const auto info = SkImageInfo::Make(pixelsWide, pixelsHigh, kRGBA_8888_SkColorType,
        kPremul_SkAlphaType, SkColorSpace::MakeSRGB());
    auto surface = SkSurfaces::Raster(info);
    if (!surface) return false;
    SkCanvas* canvas = surface->getCanvas();
    canvas->clear(SK_ColorTRANSPARENT);
    canvas->scale(float(pixelsWide) / width, float(pixelsHigh) / height);
    for (size_t n = start; n < stop; ++n) engine.renderExportStroke(canvas, strokes[n]);
    SkPixmap pixels;
    if (!surface->peekPixels(&pixels)) return false;
    CFDataRef data = CFDataCreate(kCFAllocatorDefault, static_cast<const UInt8*>(pixels.addr()), pixels.computeByteSize());
    if (!data) return false;
    CGDataProviderRef provider = CGDataProviderCreateWithCFData(data);
    CFRelease(data);
    if (!provider) return false;
    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGImageRef image = CGImageCreate(pixelsWide, pixelsHigh, 8, 32, pixels.rowBytes(), colorSpace,
        static_cast<CGBitmapInfo>(kCGBitmapByteOrder32Big) | static_cast<CGBitmapInfo>(kCGImageAlphaPremultipliedLast),
        provider, nullptr, true, kCGRenderingIntentDefault);
    CGColorSpaceRelease(colorSpace);
    CGDataProviderRelease(provider);
    if (!image) return false;
    CGContextSaveGState(context);
    CGContextSetBlendMode(context, kCGBlendModeNormal);
    CGContextTranslateCTM(context, 0, height);
    CGContextScaleCTM(context, 1, -1);
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
    CGContextRestoreGState(context);
    CGImageRelease(image);
    return true;
}

} // namespace

extern "C" void mobileInkDrawPdfPaper(const char* background, CGContextRef context,
                                      int32_t width, int32_t height, int32_t pageIndex) {
    QuartzInkCanvas canvas(context, width, height);
    nativedrawing::BackgroundRenderer().drawBackground(&canvas, background, width, height, nullptr,
        std::max(0, pageIndex) * float(height));
}

extern "C" bool mobileInkDrawPdfInk(const uint8_t* bytes, int32_t count, CGContextRef context,
                                   int32_t width, int32_t height, float density) {
    if (!bytes || count <= 0 || !context || width <= 0 || height <= 0 ||
        !std::isfinite(density) || density <= 0) return false;
    std::vector<Stroke> strokes;
    if (!nativedrawing::DrawingSerialization().deserialize({bytes, bytes + count}, strokes)) return false;
    nativedrawing::SkiaDrawingEngine engine(width, height, true);
    QuartzInkCanvas canvas(context, width, height);

    // Pre-mask notebooks store an eraser as an ordered destination-out
    // operation. Keep its whole ink layer together so the original PDF stays
    // visible through the erased areas.
    for (const auto& stroke : strokes) {
        const auto blend = stroke.paint.asBlendMode();
        if (stroke.isEraser || (blend != SkBlendMode::kSrcOver && blend != SkBlendMode::kMultiply) ||
            !canvas.supports(stroke)) {
            return drawRasterRange(context, engine, strokes, 0, strokes.size(), width, height, density);
        }
    }

    CGContextSaveGState(context);
    CGContextBeginTransparencyLayer(context, nullptr);
    bool success = true;
    for (size_t n = 0; n < strokes.size() && success;) {
        if (strokes[n].toolType != "crayon") {
            engine.renderExportStroke(&canvas, strokes[n++]);
            continue;
        }
        size_t end = n + 1;
        while (end < strokes.size() && strokes[end].toolType == "crayon") ++end;
        success = drawRasterRange(context, engine, strokes, n, end, width, height, density);
        n = end;
    }
    CGContextEndTransparencyLayer(context);
    CGContextRestoreGState(context);
    return success;
}
