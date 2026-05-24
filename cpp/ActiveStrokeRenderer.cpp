#include "ActiveStrokeRenderer.h"
#include "PathRenderer.h"
#include <algorithm>
#include <cmath>
#include <include/core/SkImageInfo.h>
#include <include/core/SkPath.h>

namespace nativedrawing {

namespace {

void drawCenterlinePreview(
    SkCanvas* canvas,
    const std::vector<Point>& points,
    const SkPaint& basePaint
) {
    if (!canvas || points.size() < 2) {
        return;
    }

    SkPath path;
    path.moveTo(points[0].x, points[0].y);
    for (size_t i = 1; i < points.size(); ++i) {
        path.lineTo(points[i].x, points[i].y);
    }

    float width = 0.0f;
    for (const auto& point : points) {
        width += point.calculatedWidth;
    }
    width /= static_cast<float>(points.size());

    SkPaint paint = basePaint;
    paint.setStyle(SkPaint::kStroke_Style);
    paint.setStrokeWidth(width);
    paint.setStrokeCap(SkPaint::kRound_Cap);
    paint.setStrokeJoin(SkPaint::kRound_Join);
    paint.setAntiAlias(true);
    paint.setBlendMode(SkBlendMode::kSrcOver);
    canvas->drawPath(path, paint);
}

}  // namespace

ActiveStrokeRenderer::ActiveStrokeRenderer(int width, int height, PathRenderer* pathRenderer)
    : pathRenderer_(pathRenderer)
    , logicalWidth_(width)
    , logicalHeight_(height)
    , lastRenderedInputIndex_(0)
    , hasLastEdge_(false)
    , lastHalfWidth_(-1.0f) {

    SkImageInfo info = SkImageInfo::MakeN32Premul(width, height);
    activeStrokeSurface_ = SkSurfaces::Raster(info);
    if (activeStrokeSurface_) {
        activeStrokeSurface_->getCanvas()->clear(SK_ColorTRANSPARENT);
    }
}

void ActiveStrokeRenderer::resetIncrementalState() {
    cachedActiveSnapshot_ = nullptr;
    lastRenderedInputIndex_ = 0;
    overlapBuffer_.clear();
    hasLastEdge_ = false;
    lastLeftEdge_ = SkPoint::Make(0, 0);
    lastRightEdge_ = SkPoint::Make(0, 0);
    lastHalfWidth_ = -1.0f;  // Will use default baseWidth/2
}

void ActiveStrokeRenderer::reset() {
    if (activeStrokeSurface_) {
        activeStrokeSurface_->getCanvas()->clear(SK_ColorTRANSPARENT);
    }
    resetIncrementalState();
}

void ActiveStrokeRenderer::ensureSurfaceScale(float surfaceScale) {
    const float nextScale = std::max(1.0f, std::min(5.0f, surfaceScale));
    if (activeStrokeSurface_ && std::fabs(nextScale - surfaceScale_) < 0.01f) {
        return;
    }

    surfaceScale_ = nextScale;
    const int scaledWidth = std::max(1, static_cast<int>(std::ceil(logicalWidth_ * surfaceScale_)));
    const int scaledHeight = std::max(1, static_cast<int>(std::ceil(logicalHeight_ * surfaceScale_)));
    SkImageInfo info = SkImageInfo::MakeN32Premul(scaledWidth, scaledHeight);
    activeStrokeSurface_ = SkSurfaces::Raster(info);
    if (activeStrokeSurface_) {
        activeStrokeSurface_->getCanvas()->clear(SK_ColorTRANSPARENT);
    }
    resetIncrementalState();
}

void ActiveStrokeRenderer::renderIncremental(
    SkCanvas* canvas,
    const std::vector<Point>& points,
    const SkPaint& paint,
    const std::string& toolType,
    float surfaceScale
) {
    ensureSurfaceScale(surfaceScale);
    if (!activeStrokeSurface_ || points.size() < 2) return;

    const bool isTranslucentCenterlineTool = toolType == "highlighter" || toolType == "marker";

    // Calligraphy: full redraw each frame for clean rendering
    // The incremental approach causes overlap artifacts on thin strokes
    if (toolType == "calligraphy") {
        pathRenderer_->drawCalligraphyPath(canvas, points, paint, true);
        return;
    }

    // Spline overlap: Catmull-Rom needs p[i-1], p[i], p[i+1], p[i+2]
    // We can only "finalize" points up to points.size() - 2
    size_t renderableUpTo = (points.size() > OVERLAP) ? points.size() - OVERLAP : 0;

    // Render new points to the cached surface
    if (renderableUpTo > lastRenderedInputIndex_ && renderableUpTo >= 2) {
        std::vector<Point> segment;
        segment.reserve(overlapBuffer_.size() + (renderableUpTo - lastRenderedInputIndex_));

        // Add overlap from previous render (for spline continuity)
        for (const auto& pt : overlapBuffer_) {
            segment.push_back(pt);
        }

        // Add new points
        size_t startIdx = (lastRenderedInputIndex_ > 0) ? lastRenderedInputIndex_ : 0;
        for (size_t i = startIdx; i < renderableUpTo; ++i) {
            segment.push_back(points[i]);
        }

        if (segment.size() >= 2) {
            SkCanvas* surfaceCanvas = activeStrokeSurface_->getCanvas();
            bool isFirstSegment = !hasLastEdge_;

            IncrementalResult result;
            surfaceCanvas->save();
            surfaceCanvas->scale(surfaceScale_, surfaceScale_);
            if (isTranslucentCenterlineTool) {
                drawCenterlinePreview(surfaceCanvas, segment, paint);
                result.lastLeftEdge = SkPoint::Make(segment.back().x, segment.back().y);
                result.lastRightEdge = result.lastLeftEdge;
            } else if (toolType == "crayon") {
                result = pathRenderer_->drawCrayonPathIncremental(
                    surfaceCanvas, segment, paint,
                    lastLeftEdge_, lastRightEdge_, isFirstSegment);
                // Draw start cap on first segment
                if (isFirstSegment) {
                    pathRenderer_->drawCrayonStartCap(surfaceCanvas, segment, paint);
                }
            } else if (toolType == "calligraphy") {
                result = pathRenderer_->drawCalligraphyPathIncremental(
                    surfaceCanvas, segment, paint,
                    lastLeftEdge_, lastRightEdge_, isFirstSegment,
                    lastHalfWidth_);
                lastHalfWidth_ = result.lastHalfWidth;
                // Calligraphy has tapered ends, no caps needed
            } else {
                result = pathRenderer_->drawVariableWidthPathIncremental(
                    surfaceCanvas, segment, paint,
                    lastLeftEdge_, lastRightEdge_, isFirstSegment);
                // Draw start cap on first segment
                if (isFirstSegment) {
                    pathRenderer_->drawVariableWidthStartCap(surfaceCanvas, segment, paint);
                }
            }
            surfaceCanvas->restore();

            lastLeftEdge_ = result.lastLeftEdge;
            lastRightEdge_ = result.lastRightEdge;
            hasLastEdge_ = true;

            // Update overlap buffer
            overlapBuffer_.clear();
            size_t overlapStart = (renderableUpTo >= OVERLAP) ? renderableUpTo - OVERLAP : 0;
            for (size_t i = overlapStart; i < renderableUpTo; ++i) {
                overlapBuffer_.push_back(points[i]);
            }

            lastRenderedInputIndex_ = renderableUpTo;
            cachedActiveSnapshot_ = activeStrokeSurface_->makeImageSnapshot();
        }
    }

    // Draw cached portion to output canvas
    drawSnapshot(canvas);

    // Draw "tail" - recent points not yet finalized
    if (points.size() > lastRenderedInputIndex_) {
        std::vector<Point> tail;
        tail.reserve(overlapBuffer_.size() + (points.size() - lastRenderedInputIndex_));

        for (const auto& pt : overlapBuffer_) {
            tail.push_back(pt);
        }
        for (size_t i = lastRenderedInputIndex_; i < points.size(); ++i) {
            tail.push_back(points[i]);
        }

        if (tail.size() >= 2) {
            if (isTranslucentCenterlineTool) {
                drawCenterlinePreview(canvas, tail, paint);
            } else if (toolType == "crayon") {
                // drawCrayonPathTail already draws end cap
                pathRenderer_->drawCrayonPathTail(canvas, tail, paint,
                    lastLeftEdge_, lastRightEdge_, hasLastEdge_);
            } else if (toolType == "calligraphy") {
                // Calligraphy has tapered ends, no caps needed
                pathRenderer_->drawCalligraphyPathTail(canvas, tail, paint,
                    lastLeftEdge_, lastRightEdge_, hasLastEdge_, lastHalfWidth_);
            } else {
                pathRenderer_->drawVariableWidthPathTail(canvas, tail, paint,
                    lastLeftEdge_, lastRightEdge_, hasLastEdge_);
                // Draw end cap at current tip
                pathRenderer_->drawVariableWidthEndCap(canvas, tail, paint);
            }
        }
    }
}

void ActiveStrokeRenderer::renderFinalTail(
    const std::vector<Point>& points,
    const SkPaint& paint,
    const std::string& toolType
) {
    if (!activeStrokeSurface_ || points.size() < 2) return;

    std::vector<Point> finalTail;
    finalTail.reserve(overlapBuffer_.size() + (points.size() - lastRenderedInputIndex_));

    for (const auto& pt : overlapBuffer_) {
        finalTail.push_back(pt);
    }
    for (size_t i = lastRenderedInputIndex_; i < points.size(); ++i) {
        finalTail.push_back(points[i]);
    }

    if (finalTail.size() < 2) return;

    SkCanvas* surfaceCanvas = activeStrokeSurface_->getCanvas();

    if (toolType == "highlighter" || toolType == "marker") {
        surfaceCanvas->save();
        surfaceCanvas->scale(surfaceScale_, surfaceScale_);
        drawCenterlinePreview(surfaceCanvas, finalTail, paint);
        surfaceCanvas->restore();
    } else if (toolType == "crayon") {
        surfaceCanvas->save();
        surfaceCanvas->scale(surfaceScale_, surfaceScale_);
        pathRenderer_->drawCrayonPathIncremental(
            surfaceCanvas, finalTail, paint,
            lastLeftEdge_, lastRightEdge_, !hasLastEdge_);
        // Only draw end cap - start cap was already drawn during incremental rendering
        pathRenderer_->drawCrayonEndCap(surfaceCanvas, points, paint);
        surfaceCanvas->restore();
    } else if (toolType == "calligraphy") {
        surfaceCanvas->save();
        surfaceCanvas->scale(surfaceScale_, surfaceScale_);
        pathRenderer_->drawCalligraphyPathIncremental(
            surfaceCanvas, finalTail, paint,
            lastLeftEdge_, lastRightEdge_, !hasLastEdge_,
            lastHalfWidth_);
        // Calligraphy has tapered ends, no caps needed
        surfaceCanvas->restore();
    } else {
        surfaceCanvas->save();
        surfaceCanvas->scale(surfaceScale_, surfaceScale_);
        pathRenderer_->drawVariableWidthPathIncremental(
            surfaceCanvas, finalTail, paint,
            lastLeftEdge_, lastRightEdge_, !hasLastEdge_);
        // Only draw end cap - start cap was already drawn during incremental rendering
        pathRenderer_->drawVariableWidthEndCap(surfaceCanvas, points, paint);
        surfaceCanvas->restore();
    }

    cachedActiveSnapshot_ = activeStrokeSurface_->makeImageSnapshot();
}

void ActiveStrokeRenderer::drawSnapshot(SkCanvas* canvas) const {
    if (!canvas || !cachedActiveSnapshot_) {
        return;
    }

    if (std::fabs(surfaceScale_ - 1.0f) < 0.01f) {
        canvas->drawImage(cachedActiveSnapshot_, 0, 0);
        return;
    }

    const SkRect dst = SkRect::MakeWH(
        static_cast<float>(logicalWidth_),
        static_cast<float>(logicalHeight_)
    );
    canvas->drawImageRect(cachedActiveSnapshot_, dst, SkSamplingOptions());
}

} // namespace nativedrawing
