#pragma once

#include <vector>
#include <include/core/SkSurface.h>
#include <include/core/SkCanvas.h>
#include <include/core/SkPaint.h>
#include <include/core/SkPoint.h>
#include <include/core/SkImage.h>
#include "DrawingTypes.h"
#include <string>

namespace nativedrawing {

class PathRenderer;

/**
 * Viewport the active stroke is being drawn in, in logical (document)
 * coordinates. When scale > 1 the preview surface is anchored to this
 * region so the magnified stroke stays crisp without growing the surface.
 */
struct ActiveStrokeViewport {
    float scale = 1.0f;
    float left = 0.0f;
    float top = 0.0f;
    float width = 0.0f;   // <= 0 means the full canvas is visible
    float height = 0.0f;  // <= 0 means the full canvas is visible
};

/**
 * ActiveStrokeRenderer - Handles incremental O(1) rendering of active strokes
 *
 * Extracted from SkiaDrawingEngine for maintainability.
 * Implements surface caching and incremental rendering to maintain 60-120fps
 * during stroke input, regardless of stroke complexity.
 *
 * The surface is always allocated at the engine's logical dimensions. When
 * the viewport is zoomed, the surface covers only the visible region at
 * magnification instead of the whole canvas, keeping memory constant.
 */
class ActiveStrokeRenderer {
public:
    explicit ActiveStrokeRenderer(int width, int height, PathRenderer* pathRenderer);

    /**
     * Reset state for a new stroke
     */
    void reset();

    /**
     * Render the active stroke incrementally to the output canvas
     *
     * @param canvas Output canvas to draw to (already scaled to the viewport)
     * @param points Current stroke points
     * @param paint Paint to use for rendering
     * @param toolType Current tool type (pen, crayon, etc.)
     * @param viewport Visible region and zoom the stroke is drawn in
     */
    void renderIncremental(
        SkCanvas* canvas,
        const std::vector<Point>& points,
        const SkPaint& paint,
        const std::string& toolType,
        const ActiveStrokeViewport& viewport
    );

    /**
     * Render remaining tail points to the active stroke surface
     * Called at stroke completion to finalize the stroke
     */
    void renderFinalTail(
        const std::vector<Point>& points,
        const SkPaint& paint,
        const std::string& toolType
    );

    /**
     * Draw the cached active stroke onto a canvas in logical coordinates.
     */
    void drawSnapshot(SkCanvas* canvas) const;

    /**
     * Effective magnification the preview surface is currently anchored at.
     * 1.0 means the surface maps 1:1 onto the full canvas.
     */
    float viewportScale() const { return viewportScale_; }

    /**
     * Get the last rendered input index
     */
    size_t getLastRenderedIndex() const { return lastRenderedInputIndex_; }

private:
    PathRenderer* pathRenderer_;
    int logicalWidth_;
    int logicalHeight_;
    float viewportScale_ = 1.0f;
    float viewportOriginX_ = 0.0f;
    float viewportOriginY_ = 0.0f;

    // Active stroke surface for incremental rendering
    sk_sp<SkSurface> activeStrokeSurface_;
    sk_sp<SkImage> cachedActiveSnapshot_;

    // Incremental rendering state
    size_t lastRenderedInputIndex_;
    std::vector<Point> overlapBuffer_;
    SkPoint lastLeftEdge_, lastRightEdge_;
    bool hasLastEdge_;
    float lastHalfWidth_;  // For calligraphy width continuity

    void ensureViewportAlignment(const ActiveStrokeViewport& viewport);
    void applySurfaceTransform(SkCanvas* surfaceCanvas) const;
    void resetIncrementalState();

    static constexpr size_t OVERLAP = 2;  // Spline overlap for Catmull-Rom
};

} // namespace nativedrawing
