#include "ActiveStrokeRenderer.h"
#include "PathRenderer.h"
#include <algorithm>
#include <cmath>
#include <include/core/SkImageInfo.h>

namespace nativedrawing {

ActiveStrokeRenderer::ActiveStrokeRenderer(int width, int height, PathRenderer* pathRenderer)
    : pathRenderer_(pathRenderer)
    , logicalWidth_(width)
    , logicalHeight_(height)
    , lastRenderedInputIndex_(0)
    , hasLastEdge_(false) {

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
}

void ActiveStrokeRenderer::reset() {
    if (activeStrokeSurface_) {
        activeStrokeSurface_->getCanvas()->clear(SK_ColorTRANSPARENT);
    }
    resetIncrementalState();
}

void ActiveStrokeRenderer::ensureViewportAlignment(const ActiveStrokeViewport& viewport) {
    const float requestedScale =
        std::clamp(viewport.scale, kMinimumRenderScale, kMaximumRenderScale);

    // The surface is fixed at logical dimensions, so the covered region at
    // `scale` magnification is logical/scale. Cap the scale at the highest
    // magnification whose viewport still fits; inconsistent viewport data
    // (e.g. a consumer that sets renderScale without viewport ratios)
    // degrades to the identity mapping instead of an anchored surface that
    // misses where the user is drawing.
    const float viewWidth = viewport.width > 0.0f
        ? viewport.width
        : static_cast<float>(logicalWidth_);
    const float viewHeight = viewport.height > 0.0f
        ? viewport.height
        : static_cast<float>(logicalHeight_);
    const float fitScale = std::min(
        static_cast<float>(logicalWidth_) / std::max(1.0f, viewWidth),
        static_cast<float>(logicalHeight_) / std::max(1.0f, viewHeight)
    );
    const float nextScale = std::max(kMinimumRenderScale, std::min(requestedScale, fitScale));

    float nextOriginX = 0.0f;
    float nextOriginY = 0.0f;
    if (nextScale > kIdentityRenderScaleThreshold) {
        const float coveredWidth = static_cast<float>(logicalWidth_) / nextScale;
        const float coveredHeight = static_cast<float>(logicalHeight_) / nextScale;
        nextOriginX = std::clamp(
            viewport.left, 0.0f, static_cast<float>(logicalWidth_) - coveredWidth);
        nextOriginY = std::clamp(
            viewport.top, 0.0f, static_cast<float>(logicalHeight_) - coveredHeight);
    }

    if (activeStrokeSurface_
        && std::fabs(nextScale - viewportScale_) < 0.01f
        && std::fabs(nextOriginX - viewportOriginX_) < 0.5f
        && std::fabs(nextOriginY - viewportOriginY_) < 0.5f) {
        return;
    }

    viewportScale_ = nextScale;
    viewportOriginX_ = nextOriginX;
    viewportOriginY_ = nextOriginY;

    if (!activeStrokeSurface_) {
        SkImageInfo info = SkImageInfo::MakeN32Premul(logicalWidth_, logicalHeight_);
        activeStrokeSurface_ = SkSurfaces::Raster(info);
    }
    if (activeStrokeSurface_) {
        activeStrokeSurface_->getCanvas()->clear(SK_ColorTRANSPARENT);
    }
    // Anchoring changed mid-stroke: drop incremental progress so the next
    // renderIncremental call re-renders every point into the fresh surface.
    resetIncrementalState();
}

void ActiveStrokeRenderer::applySurfaceTransform(SkCanvas* surfaceCanvas) const {
    surfaceCanvas->scale(viewportScale_, viewportScale_);
    surfaceCanvas->translate(-viewportOriginX_, -viewportOriginY_);
}

void ActiveStrokeRenderer::renderIncremental(
    SkCanvas* canvas,
    const std::vector<Point>& points,
    const SkPaint& paint,
    const std::string& toolType,
    const ActiveStrokeViewport& viewport
) {
    ensureViewportAlignment(viewport);
    if (!activeStrokeSurface_ || points.size() < 2) return;

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
            {
                SkAutoCanvasRestore acr(surfaceCanvas, true);
                applySurfaceTransform(surfaceCanvas);
                if (toolType == "crayon") {
                    result = pathRenderer_->drawCrayonPathIncremental(
                        surfaceCanvas, segment, paint,
                        lastLeftEdge_, lastRightEdge_, isFirstSegment);
                    // Draw start cap on first segment
                    if (isFirstSegment) {
                        pathRenderer_->drawCrayonStartCap(surfaceCanvas, segment, paint);
                    }
                } else {
                    result = pathRenderer_->drawVariableWidthPathIncremental(
                        surfaceCanvas, segment, paint,
                        lastLeftEdge_, lastRightEdge_, isFirstSegment);
                    // Draw start cap on first segment
                    if (isFirstSegment) {
                        pathRenderer_->drawVariableWidthStartCap(surfaceCanvas, segment, paint);
                    }
                }
            }

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
            if (toolType == "crayon") {
                // drawCrayonPathTail already draws end cap
                pathRenderer_->drawCrayonPathTail(canvas, tail, paint,
                    lastLeftEdge_, lastRightEdge_, hasLastEdge_);
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

    {
        SkAutoCanvasRestore acr(surfaceCanvas, true);
        applySurfaceTransform(surfaceCanvas);
        if (toolType == "crayon") {
            pathRenderer_->drawCrayonPathIncremental(
                surfaceCanvas, finalTail, paint,
                lastLeftEdge_, lastRightEdge_, !hasLastEdge_);
            // Only draw end cap - start cap was already drawn during incremental rendering
            pathRenderer_->drawCrayonEndCap(surfaceCanvas, points, paint);
        } else if (toolType == "calligraphy") {
            // Calligraphy renders the whole stroke here (its live preview is a
            // direct full redraw), so there is no carried half-width; -1 selects
            // the default baseWidth/2. Tapered ends, no caps needed.
            pathRenderer_->drawCalligraphyPathIncremental(
                surfaceCanvas, finalTail, paint,
                lastLeftEdge_, lastRightEdge_, !hasLastEdge_,
                -1.0f);
        } else {
            pathRenderer_->drawVariableWidthPathIncremental(
                surfaceCanvas, finalTail, paint,
                lastLeftEdge_, lastRightEdge_, !hasLastEdge_);
            // Only draw end cap - start cap was already drawn during incremental rendering
            pathRenderer_->drawVariableWidthEndCap(surfaceCanvas, points, paint);
        }
    }

    cachedActiveSnapshot_ = activeStrokeSurface_->makeImageSnapshot();
}

void ActiveStrokeRenderer::drawSnapshot(SkCanvas* canvas) const {
    if (!canvas || !cachedActiveSnapshot_) {
        return;
    }

    if (viewportScale_ <= kIdentityRenderScaleThreshold) {
        canvas->drawImage(cachedActiveSnapshot_, 0, 0);
        return;
    }

    const SkRect dst = SkRect::MakeXYWH(
        viewportOriginX_,
        viewportOriginY_,
        static_cast<float>(logicalWidth_) / viewportScale_,
        static_cast<float>(logicalHeight_) / viewportScale_
    );
    canvas->drawImageRect(
        cachedActiveSnapshot_,
        dst,
        SkSamplingOptions(SkFilterMode::kLinear)
    );
}

} // namespace nativedrawing
