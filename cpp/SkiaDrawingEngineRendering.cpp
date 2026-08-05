#include "SkiaDrawingEngine.h"

#include "ActiveStrokeRenderer.h"
#include "BackgroundRenderer.h"
#include "BatchExporter.h"
#include "DrawingSelection.h"
#include "PathRenderer.h"
#include "ShapeRecognition.h"

#include <algorithm>
#include <cstdio>
#include <utility>

#include <include/core/SkData.h>
#include <include/core/SkImageInfo.h>
#include <include/encode/SkPngEncoder.h>

namespace nativedrawing {

namespace {

constexpr int kStrokeTileSize = 512;
constexpr size_t kMaxStrokeTileCacheBytes = 96 * 1024 * 1024;

SkColor swapRedBlueChannels(SkColor color) {
    return SkColorSetARGB(
        SkColorGetA(color),
        SkColorGetB(color),
        SkColorGetG(color),
        SkColorGetR(color)
    );
}

void normalizeStrokeColorsForRasterExport(std::vector<Stroke>& strokes) {
    for (auto& stroke : strokes) {
        if (stroke.isEraser) {
            continue;
        }

        stroke.paint.setColor(swapRedBlueChannels(stroke.paint.getColor()));
    }
}

int renderScaleBucket(float scale) {
    const float clamped = std::max(kMinimumRenderScale, std::min(kMaximumRenderScale, scale));
    const float buckets[] = {1.0f, 1.5f, 2.0f, 2.5f, 3.0f, 4.0f, 5.0f};
    float bestBucket = buckets[0];
    float bestDistance = std::fabs(clamped - bestBucket);
    for (float bucket : buckets) {
        const float distance = std::fabs(clamped - bucket);
        if (distance < bestDistance) {
            bestBucket = bucket;
            bestDistance = distance;
        }
    }
    return static_cast<int>(std::round(bestBucket * 100.0f));
}

}  // namespace

void SkiaDrawingEngine::setRenderViewport(
    float renderScale,
    float visibleLeft,
    float visibleTop,
    float visibleWidth,
    float visibleHeight
) {
    std::lock_guard<std::recursive_mutex> lock(stateMutex_);

    const float clampedScale = std::max(kMinimumRenderScale, std::min(kMaximumRenderScale, renderScale));
    renderScale_ = static_cast<float>(renderScaleBucket(clampedScale)) / 100.0f;
    visibleLeft_ = std::max(0.0f, std::min(static_cast<float>(width_), visibleLeft));
    visibleTop_ = std::max(0.0f, std::min(static_cast<float>(height_), visibleTop));
    visibleWidth_ = std::max(1.0f, std::min(static_cast<float>(width_) - visibleLeft_, visibleWidth));
    visibleHeight_ = std::max(1.0f, std::min(static_cast<float>(height_) - visibleTop_, visibleHeight));
}

void SkiaDrawingEngine::markStrokeCachesDirty() {
    needsStrokeRedraw_ = true;
    strokeTileEpoch_++;
    if (strokeTileEpoch_ == 0) {
        strokeTileEpoch_ = 1;
        strokeTileCache_.clear();
        strokeTileCacheBytes_ = 0;
    }
}

void SkiaDrawingEngine::invalidateStrokeTilesForRect(const SkRect& bounds) {
    if (strokeTileCache_.empty() || bounds.isEmpty()) {
        return;
    }

    const float expandedLeft = std::max(0.0f, bounds.left());
    const float expandedTop = std::max(0.0f, bounds.top());
    const float expandedRight = std::min(static_cast<float>(width_), bounds.right());
    const float expandedBottom = std::min(static_cast<float>(height_), bounds.bottom());
    if (expandedRight <= expandedLeft || expandedBottom <= expandedTop) {
        return;
    }

    for (auto it = strokeTileCache_.begin(); it != strokeTileCache_.end();) {
        const StrokeTileKey& key = it->first;
        if (key.epoch != strokeTileEpoch_) {
            strokeTileCacheBytes_ -= std::min(strokeTileCacheBytes_, it->second.bytes);
            it = strokeTileCache_.erase(it);
            continue;
        }

        const float scale = key.scaleBucket / 100.0f;
        const float tileLeft = static_cast<float>(key.tileX * kStrokeTileSize) / scale;
        const float tileTop = static_cast<float>(key.tileY * kStrokeTileSize) / scale;
        const float tileRight = static_cast<float>((key.tileX + 1) * kStrokeTileSize) / scale;
        const float tileBottom = static_cast<float>((key.tileY + 1) * kStrokeTileSize) / scale;
        const bool intersects = tileRight >= expandedLeft
            && tileLeft <= expandedRight
            && tileBottom >= expandedTop
            && tileTop <= expandedBottom;

        if (intersects) {
            strokeTileCacheBytes_ -= std::min(strokeTileCacheBytes_, it->second.bytes);
            it = strokeTileCache_.erase(it);
        } else {
            ++it;
        }
    }
}

void SkiaDrawingEngine::setBackgroundType(const char* backgroundType) {
    std::lock_guard<std::recursive_mutex> lock(stateMutex_);

    backgroundType_ = backgroundType ? backgroundType : "plain";
}

std::string SkiaDrawingEngine::getBackgroundType() const {
    std::lock_guard<std::recursive_mutex> lock(stateMutex_);
    return backgroundType_;
}

void SkiaDrawingEngine::setPdfBackgroundImage(sk_sp<SkImage> image) {
    std::lock_guard<std::recursive_mutex> lock(stateMutex_);

    pdfBackgroundImage_ = image;
}

void SkiaDrawingEngine::renderStrokeGeometry(SkCanvas* canvas, const Stroke& stroke, const SkPaint& paint) {
    if (!canvas) {
        return;
    }

    if (isRecognizedShapeToolType(stroke.toolType)) {
        SkPath shapePath = stroke.path;
        if (shapePath.isEmpty()) {
            buildRecognizedShapePath(stroke.toolType, stroke.points, shapePath);
        }

        if (shapePath.isEmpty()) {
            return;
        }

        SkPaint shapePaint = paint;
        shapePaint.setStyle(SkPaint::kStroke_Style);
        shapePaint.setStrokeWidth(averageCalculatedWidth(stroke.points));
        shapePaint.setStrokeJoin(stroke.toolType == "shape-line"
            ? SkPaint::kRound_Join
            : SkPaint::kMiter_Join);
        shapePaint.setStrokeCap(stroke.toolType == "shape-line"
            ? SkPaint::kRound_Cap
            : SkPaint::kButt_Cap);
        canvas->drawPath(shapePath, shapePaint);
        return;
    }

    if (isCenterlineStrokedToolType(stroke.toolType)) {
        drawCenterlineStrokePath(canvas, stroke.points, stroke.path, paint);
        return;
    }

    if (stroke.toolType == "crayon") {
        pathRenderer_->drawCrayonPath(canvas, stroke.points, paint, false);
    } else if (stroke.toolType == "calligraphy") {
        pathRenderer_->drawCalligraphyPath(canvas, stroke.points, paint, false);
    } else {
        pathRenderer_->drawVariableWidthPath(canvas, stroke.points, paint, false);
    }
}

void SkiaDrawingEngine::redrawStrokes() {
    if (!needsStrokeRedraw_) return;

    SkCanvas* canvas = strokeSurface_->getCanvas();
    canvas->clear(SK_ColorTRANSPARENT);

    // Helper to render a single stroke with per-stroke eraser clipping
    auto renderStroke = [&](size_t i) {
        const auto& stroke = strokes_[i];
        SkPaint strokePaint = stroke.paint;

        if (!stroke.isEraser) {
            uint8_t baseAlpha = stroke.paint.getAlpha();
            strokePaint.setAlpha(static_cast<uint8_t>(baseAlpha * stroke.originalAlphaMod));
        }

        if (pendingDeleteIndices_.count(i) > 0) {
            strokePaint.setAlpha(strokePaint.getAlpha() * 0.3);
        }

        // Apply per-stroke eraser clipping if this stroke has been erased
        bool needsClipRestore = false;
        if (!stroke.erasedBy.empty()) {
            // Ensure cache is up-to-date (builds smooth capsule shapes between circles)
            stroke.ensureEraserCacheValid();
            if (!stroke.cachedEraserPath.isEmpty()) {
                // Clip out the erased regions (kDifference = draw everywhere EXCEPT cached path)
                canvas->save();
                canvas->clipPath(stroke.cachedEraserPath, SkClipOp::kDifference);
                needsClipRestore = true;
            }
        }

        // Render stroke (curves unchanged - clipping handles pixel-perfect erasure)
        renderStrokeGeometry(canvas, stroke, strokePaint);

        if (needsClipRestore) {
            canvas->restore();
        }
    };

    // Render all strokes - eraser effect applied via per-stroke clipping
    for (size_t strokeIdx = 0; strokeIdx < strokes_.size(); ++strokeIdx) {
        renderStroke(strokeIdx);
    }

    // All strokes are now in strokeSurface_
    maxAffectedStrokeIndex_ = strokes_.size();

    // Cache snapshot for fast rendering (avoid makeImageSnapshot every frame)
    cachedStrokeSnapshot_ = strokeSurface_->makeImageSnapshot();

    needsStrokeRedraw_ = false;
}

sk_sp<SkImage> SkiaDrawingEngine::renderStrokeTile(
    const StrokeTileKey& key,
    int tileWidth,
    int tileHeight,
    float scale
) {
    SkImageInfo info = SkImageInfo::MakeN32Premul(tileWidth, tileHeight);
    sk_sp<SkSurface> tileSurface = SkSurfaces::Raster(info);
    if (!tileSurface) {
        return nullptr;
    }

    SkCanvas* tileCanvas = tileSurface->getCanvas();
    tileCanvas->clear(SK_ColorTRANSPARENT);
    tileCanvas->translate(
        static_cast<float>(-key.tileX * kStrokeTileSize),
        static_cast<float>(-key.tileY * kStrokeTileSize)
    );
    tileCanvas->scale(scale, scale);

    const float tileLeft = static_cast<float>(key.tileX * kStrokeTileSize) / scale;
    const float tileTop = static_cast<float>(key.tileY * kStrokeTileSize) / scale;
    const float tileRight = static_cast<float>(key.tileX * kStrokeTileSize + tileWidth) / scale;
    const float tileBottom = static_cast<float>(key.tileY * kStrokeTileSize + tileHeight) / scale;
    SkRect tileBounds = SkRect::MakeLTRB(tileLeft, tileTop, tileRight, tileBottom);

    for (size_t i = 0; i < strokes_.size(); ++i) {
        const auto& stroke = strokes_[i];
        if (stroke.isEraser) {
            continue;
        }

        SkRect strokeBounds = stroke.path.getBounds();
        const float outset = std::max(8.0f, stroke.paint.getStrokeWidth() * 2.0f);
        strokeBounds.outset(outset, outset);
        if (!strokeBounds.intersects(tileBounds)) {
            continue;
        }

        SkPaint strokePaint = stroke.paint;
        uint8_t baseAlpha = stroke.paint.getAlpha();
        strokePaint.setAlpha(static_cast<uint8_t>(baseAlpha * stroke.originalAlphaMod));

        bool needsClipRestore = false;
        if (!stroke.erasedBy.empty()) {
            stroke.ensureEraserCacheValid();
            if (!stroke.cachedEraserPath.isEmpty()) {
                tileCanvas->save();
                tileCanvas->clipPath(stroke.cachedEraserPath, SkClipOp::kDifference);
                needsClipRestore = true;
            }
        }

        renderStrokeGeometry(tileCanvas, stroke, strokePaint);

        if (needsClipRestore) {
            tileCanvas->restore();
        }
    }

    return tileSurface->makeImageSnapshot();
}

void SkiaDrawingEngine::pruneStrokeTileCache() {
    while (strokeTileCacheBytes_ > kMaxStrokeTileCacheBytes && !strokeTileCache_.empty()) {
        auto oldest = strokeTileCache_.begin();
        for (auto it = strokeTileCache_.begin(); it != strokeTileCache_.end(); ++it) {
            if (it->second.lastUsed < oldest->second.lastUsed) {
                oldest = it;
            }
        }
        strokeTileCacheBytes_ -= std::min(strokeTileCacheBytes_, oldest->second.bytes);
        strokeTileCache_.erase(oldest);
    }
}

void SkiaDrawingEngine::renderScaleAwareStrokes(SkCanvas* canvas) {
    const float scale = std::max(kMinimumRenderScale, renderScale_);

    if (!selectedIndices_.empty() && isDraggingSelection_) {
        canvas->save();
        canvas->scale(scale, scale);
        if (nonSelectedSnapshot_) {
            canvas->drawImage(nonSelectedSnapshot_, 0, 0);
        } else if (cachedStrokeSnapshot_) {
            redrawStrokes();
            canvas->drawImage(cachedStrokeSnapshot_, 0, 0);
        }
        if (selectedSnapshot_) {
            canvas->drawImage(selectedSnapshot_, selectionOffsetX_, selectionOffsetY_);
        }
        canvas->restore();
        return;
    }

    if (!pendingDeleteIndices_.empty()) {
        canvas->save();
        canvas->scale(scale, scale);
        for (size_t i = 0; i < strokes_.size(); ++i) {
            const auto& stroke = strokes_[i];
            SkPaint strokePaint = stroke.paint;
            if (!stroke.isEraser) {
                uint8_t baseAlpha = stroke.paint.getAlpha();
                const float alphaMod = pendingDeleteIndices_.count(i) > 0
                    ? stroke.originalAlphaMod * 0.3f
                    : stroke.originalAlphaMod;
                strokePaint.setAlpha(static_cast<uint8_t>(baseAlpha * alphaMod));
            }

            bool needsClipRestore = false;
            if (!stroke.erasedBy.empty()) {
                stroke.ensureEraserCacheValid();
                if (!stroke.cachedEraserPath.isEmpty()) {
                    canvas->save();
                    canvas->clipPath(stroke.cachedEraserPath, SkClipOp::kDifference);
                    needsClipRestore = true;
                }
            }
            renderStrokeGeometry(canvas, stroke, strokePaint);
            if (needsClipRestore) {
                canvas->restore();
            }
        }
        canvas->restore();
        return;
    }

    const int bucket = renderScaleBucket(scale);
    const float bucketScale = bucket / 100.0f;
    const float targetWidth = static_cast<float>(width_) * bucketScale;
    const float targetHeight = static_cast<float>(height_) * bucketScale;
    const float overscan = (static_cast<float>(kStrokeTileSize) * 2.0f) / bucketScale;
    const float visibleLeft = std::max(0.0f, visibleLeft_ - overscan);
    const float visibleTop = std::max(0.0f, visibleTop_ - overscan);
    const float visibleRight = std::min(static_cast<float>(width_), visibleLeft_ + visibleWidth_ + overscan);
    const float visibleBottom = std::min(static_cast<float>(height_), visibleTop_ + visibleHeight_ + overscan);

    const int startTileX = std::max(0, static_cast<int>(std::floor((visibleLeft * bucketScale) / kStrokeTileSize)));
    const int startTileY = std::max(0, static_cast<int>(std::floor((visibleTop * bucketScale) / kStrokeTileSize)));
    const int endTileX = std::max(startTileX, static_cast<int>(std::ceil((visibleRight * bucketScale) / kStrokeTileSize)) - 1);
    const int endTileY = std::max(startTileY, static_cast<int>(std::ceil((visibleBottom * bucketScale) / kStrokeTileSize)) - 1);
    const int maxTileX = std::max(0, static_cast<int>(std::ceil(targetWidth / kStrokeTileSize)) - 1);
    const int maxTileY = std::max(0, static_cast<int>(std::ceil(targetHeight / kStrokeTileSize)) - 1);

    for (int tileY = std::min(startTileY, maxTileY); tileY <= std::min(endTileY, maxTileY); ++tileY) {
        for (int tileX = std::min(startTileX, maxTileX); tileX <= std::min(endTileX, maxTileX); ++tileX) {
            StrokeTileKey key{bucket, tileX, tileY, strokeTileEpoch_};
            const int tilePixelLeft = tileX * kStrokeTileSize;
            const int tilePixelTop = tileY * kStrokeTileSize;
            const int tileWidth = std::max(
                1,
                std::min(kStrokeTileSize, static_cast<int>(std::ceil(targetWidth)) - tilePixelLeft)
            );
            const int tileHeight = std::max(
                1,
                std::min(kStrokeTileSize, static_cast<int>(std::ceil(targetHeight)) - tilePixelTop)
            );

            auto it = strokeTileCache_.find(key);
            if (it == strokeTileCache_.end()) {
                sk_sp<SkImage> image = renderStrokeTile(key, tileWidth, tileHeight, bucketScale);
                if (!image) {
                    continue;
                }
                StrokeTileEntry entry;
                entry.image = std::move(image);
                entry.bytes = static_cast<size_t>(tileWidth) * static_cast<size_t>(tileHeight) * 4;
                entry.lastUsed = ++strokeTileUseCounter_;
                strokeTileCacheBytes_ += entry.bytes;
                auto inserted = strokeTileCache_.emplace(key, std::move(entry));
                it = inserted.first;
                pruneStrokeTileCache();
            } else {
                it->second.lastUsed = ++strokeTileUseCounter_;
            }

            if (it != strokeTileCache_.end() && it->second.image) {
                canvas->drawImage(
                    it->second.image,
                    static_cast<float>(tilePixelLeft),
                    static_cast<float>(tilePixelTop)
                );
            }
        }
    }
}

void SkiaDrawingEngine::drawCenterlineStrokePath(
    SkCanvas* canvas,
    const std::vector<Point>& points,
    const SkPath& cachedPath,
    const SkPaint& paint
) {
    SkPath centerPath = cachedPath;
    if (centerPath.isEmpty()) {
        smoothPath(points, centerPath);
    }
    if (centerPath.isEmpty()) {
        return;
    }

    SkPaint strokePaint = paint;
    strokePaint.setStyle(SkPaint::kStroke_Style);
    strokePaint.setStrokeWidth(averageCalculatedWidth(points));
    strokePaint.setStrokeCap(SkPaint::kRound_Cap);
    strokePaint.setStrokeJoin(SkPaint::kRound_Join);
    canvas->drawPath(centerPath, strokePaint);
}

void SkiaDrawingEngine::renderActiveContent(SkCanvas* canvas) {
    if (hasActiveShapePreview_ && !activeShapePreviewPoints_.empty()) {
        Stroke previewStroke;
        previewStroke.points = activeShapePreviewPoints_;
        previewStroke.paint = currentPaint_;
        previewStroke.path = activeShapePreviewPath_;
        previewStroke.toolType = activeShapePreviewToolType_;

        SkPaint previewPaint = currentPaint_;
        if (!isCenterlineStrokedToolType(currentTool_)) {
            const float pressureAlphaMod = 0.85f + (averagePressure(currentPoints_) * 0.15f);
            previewPaint.setAlpha(static_cast<uint8_t>(previewPaint.getAlpha() * pressureAlphaMod));
        }

        renderStrokeGeometry(canvas, previewStroke, previewPaint);
    } else if (currentPoints_.size() >= 2 && currentTool_ != "select" && currentTool_ != "eraser") {
        if (isCenterlineStrokedToolType(currentTool_)) {
            // Full redraw each frame. Multiply blend is neutralized for the
            // preview: the stroke is drawn over the composited canvas here,
            // whereas the finished stroke multiplies only against other
            // strokes on the transparent stroke layer.
            SkPaint previewPaint = currentPaint_;
            if (previewPaint.asBlendMode() == SkBlendMode::kMultiply) {
                previewPaint.setBlendMode(SkBlendMode::kSrcOver);
            }
            drawCenterlineStrokePath(canvas, currentPoints_, SkPath(), previewPaint);
        } else {
            ActiveStrokeViewport viewport;
            viewport.scale = renderScale_;
            viewport.left = visibleLeft_;
            viewport.top = visibleTop_;
            viewport.width = visibleWidth_;
            viewport.height = visibleHeight_;
            activeStrokeRenderer_->renderIncremental(
                canvas,
                currentPoints_,
                currentPaint_,
                currentTool_,
                viewport
            );
        }
    }
}

void SkiaDrawingEngine::redrawEraserMask() {
    if (!needsEraserMaskRedraw_) return;

    SkCanvas* canvas = eraserMaskSurface_->getCanvas();
    canvas->clear(SK_ColorWHITE);  // Full alpha (255) = visible

    if (!eraserCircles_.empty()) {
        SkPaint erasePaint;
        erasePaint.setBlendMode(SkBlendMode::kClear);  // Sets pixels to 0 alpha (transparent = erased)
        erasePaint.setAntiAlias(true);
        erasePaint.setStyle(SkPaint::kFill_Style);

        // Build path from all circles (or use cached if available)
        if (eraserCircles_.size() != cachedEraserCircleCount_) {
            cachedEraserPath_.reset();
            for (const auto& circle : eraserCircles_) {
                cachedEraserPath_.addCircle(circle.x, circle.y, circle.radius);
            }
            cachedEraserCircleCount_ = eraserCircles_.size();
        }

        canvas->drawPath(cachedEraserPath_, erasePaint);
    }

    needsEraserMaskRedraw_ = false;
}

void SkiaDrawingEngine::render(SkCanvas* canvas) {
    std::lock_guard<std::recursive_mutex> lock(stateMutex_);

    const bool useScaleAwarePath = renderScale_ > kIdentityRenderScaleThreshold;

    if (useScaleAwarePath) {
        if (backgroundType_ == "pdf") {
            if (pdfBackgroundImage_) {
                canvas->clear(SK_ColorWHITE);
            } else {
                canvas->clear(SK_ColorTRANSPARENT);
            }
        } else {
            canvas->clear(SK_ColorWHITE);
        }

        canvas->save();
        canvas->scale(renderScale_, renderScale_);
        if (backgroundType_ != "pdf" || pdfBackgroundImage_) {
            backgroundRenderer_->drawBackground(
                canvas,
                backgroundType_,
                width_,
                height_,
                pdfBackgroundImage_,
                backgroundOriginY_
            );
        }
        canvas->restore();

        // During a pixel-erase drag the stroke tiles are stale (metadata is
        // committed at pen-up), so clip the erased circles out of the stroke
        // layer; the background drawn above shows through, whatever its type.
        const bool livePixelErase = currentTool_ == "eraser"
            && eraserMode_ == "pixel"
            && !pendingPixelEraserPath_.isEmpty();
        if (livePixelErase) {
            SkPath deviceEraserPath = pendingPixelEraserPath_;
            deviceEraserPath.transform(SkMatrix::Scale(renderScale_, renderScale_));
            canvas->save();
            canvas->clipPath(deviceEraserPath, SkClipOp::kDifference, true);
        }
        renderScaleAwareStrokes(canvas);
        if (livePixelErase) {
            canvas->restore();
        }

        canvas->save();
        canvas->scale(renderScale_, renderScale_);
        renderActiveContent(canvas);

        if (showEraserCursor_ && eraserCursorRadius_ > 0) {
            SkPaint cursorPaint;
            cursorPaint.setStyle(SkPaint::kStroke_Style);
            cursorPaint.setColor(SkColorSetARGB(180, 128, 128, 128));
            cursorPaint.setStrokeWidth(2.0f);
            cursorPaint.setAntiAlias(true);
            canvas->drawCircle(eraserCursorX_, eraserCursorY_, eraserCursorRadius_, cursorPaint);
        }

        if (currentTool_ == "select") {
            selection_->renderLasso(canvas);
        }

        if (isDraggingSelection_ && selectionHighlightSnapshot_) {
            canvas->drawImage(selectionHighlightSnapshot_, selectionOffsetX_, selectionOffsetY_);
        } else {
            selection_->renderSelection(canvas, strokes_, selectedIndices_);
        }
        canvas->restore();
        return;
    }

    // OPTIMIZATION: When dragging selection, use all cached snapshots - pure O(1) per frame
    if (!selectedIndices_.empty() && isDraggingSelection_) {
        // Draw cached background - O(1)
        if (dragBackgroundSnapshot_) {
            canvas->drawImage(dragBackgroundSnapshot_, 0, 0);
        }

        // Draw cached non-selected strokes - O(1)
        if (nonSelectedSnapshot_) {
            canvas->drawImage(nonSelectedSnapshot_, 0, 0);
        }

        // Draw cached selected strokes with offset - O(1)
        if (selectedSnapshot_) {
            canvas->drawImage(selectedSnapshot_, selectionOffsetX_, selectionOffsetY_);
        }
    } else {
        // Normal path: draw background
        if (backgroundType_ == "pdf") {
            if (pdfBackgroundImage_) {
                canvas->clear(SK_ColorWHITE);
                backgroundRenderer_->drawBackground(
                    canvas,
                    backgroundType_,
                    width_,
                    height_,
                    pdfBackgroundImage_,
                    backgroundOriginY_
                );
            } else {
                canvas->clear(SK_ColorTRANSPARENT);
            }
        } else {
            canvas->clear(SK_ColorWHITE);
            backgroundRenderer_->drawBackground(
                canvas,
                backgroundType_,
                width_,
                height_,
                pdfBackgroundImage_,
                backgroundOriginY_
            );
        }

        // Draw strokes
        if (!selectedIndices_.empty() && !needsStrokeRedraw_) {
            // Selection exists but not actively dragging - render all strokes directly
            for (size_t i = 0; i < strokes_.size(); ++i) {
                const auto& stroke = strokes_[i];
                SkPaint strokePaint = stroke.paint;

                if (!stroke.isEraser) {
                    uint8_t baseAlpha = stroke.paint.getAlpha();
                    strokePaint.setAlpha(static_cast<uint8_t>(baseAlpha * stroke.originalAlphaMod));
                }

                bool needsClipRestore = false;
                if (!stroke.erasedBy.empty()) {
                    stroke.ensureEraserCacheValid();
                    if (!stroke.cachedEraserPath.isEmpty()) {
                        canvas->save();
                        canvas->clipPath(stroke.cachedEraserPath, SkClipOp::kDifference);
                        needsClipRestore = true;
                    }
                }

                renderStrokeGeometry(canvas, stroke, strokePaint);

                if (needsClipRestore) {
                    canvas->restore();
                }
            }
        } else {
            // Normal path: use cached surface
            redrawStrokes();

            // OPTIMIZATION: If object eraser is active, clip out pending-delete strokes
            if (!pendingDeleteIndices_.empty() && cachedStrokeSnapshot_) {
                SkPath excludePath;
                for (size_t idx : pendingDeleteIndices_) {
                    if (idx >= strokes_.size()) continue;
                    SkRect bounds = strokes_[idx].path.getBounds();
                    bounds.outset(strokes_[idx].paint.getStrokeWidth(), strokes_[idx].paint.getStrokeWidth());
                    excludePath.addRect(bounds);
                }

                canvas->save();
                canvas->clipPath(excludePath, SkClipOp::kDifference);
                canvas->drawImage(cachedStrokeSnapshot_, 0, 0);
                canvas->restore();

                for (size_t idx : pendingDeleteIndices_) {
                    if (idx >= strokes_.size()) continue;
                    const auto& stroke = strokes_[idx];

                    SkPaint dimPaint = stroke.paint;
                    uint8_t baseAlpha = stroke.paint.getAlpha();
                    dimPaint.setAlpha(static_cast<uint8_t>(baseAlpha * stroke.originalAlphaMod * 0.3f));

                    bool needsClipRestore = false;
                    if (!stroke.erasedBy.empty()) {
                        stroke.ensureEraserCacheValid();
                        if (!stroke.cachedEraserPath.isEmpty()) {
                            canvas->save();
                            canvas->clipPath(stroke.cachedEraserPath, SkClipOp::kDifference);
                            needsClipRestore = true;
                        }
                    }

                    renderStrokeGeometry(canvas, stroke, dimPaint);

                    if (needsClipRestore) {
                        canvas->restore();
                    }
                }
            } else if (cachedStrokeSnapshot_) {
                canvas->drawImage(cachedStrokeSnapshot_, 0, 0);
            } else if (strokeSurface_) {
                strokeSurface_->draw(canvas, 0, 0);
            }
        }
    }

    // 4. Draw active stroke incrementally (O(1) per frame instead of O(n))
    renderActiveContent(canvas);

    // Draw eraser cursor for pixel eraser
    if (showEraserCursor_ && eraserCursorRadius_ > 0) {
        SkPaint cursorPaint;
        cursorPaint.setStyle(SkPaint::kStroke_Style);
        cursorPaint.setColor(SkColorSetARGB(180, 128, 128, 128));
        cursorPaint.setStrokeWidth(2.0f);
        cursorPaint.setAntiAlias(true);

        canvas->drawCircle(eraserCursorX_, eraserCursorY_, eraserCursorRadius_, cursorPaint);
    }

    // Draw lasso path if active (during selection drag)
    if (currentTool_ == "select") {
        selection_->renderLasso(canvas);
    }

    // Draw selection highlight if strokes are selected
    if (isDraggingSelection_ && selectionHighlightSnapshot_) {
        // During drag, use cached highlight with offset - O(1)
        canvas->drawImage(selectionHighlightSnapshot_, selectionOffsetX_, selectionOffsetY_);
    } else {
        selection_->renderSelection(canvas, strokes_, selectedIndices_);
    }
}

void SkiaDrawingEngine::renderForExport(SkCanvas* canvas) {
    std::lock_guard<std::recursive_mutex> lock(stateMutex_);

    const float originalRenderScale = renderScale_;
    const float originalVisibleLeft = visibleLeft_;
    const float originalVisibleTop = visibleTop_;
    const float originalVisibleWidth = visibleWidth_;
    const float originalVisibleHeight = visibleHeight_;

    renderScale_ = 1.0f;
    visibleLeft_ = 0.0f;
    visibleTop_ = 0.0f;
    visibleWidth_ = static_cast<float>(width_);
    visibleHeight_ = static_cast<float>(height_);
    render(canvas);

    renderScale_ = originalRenderScale;
    visibleLeft_ = originalVisibleLeft;
    visibleTop_ = originalVisibleTop;
    visibleWidth_ = originalVisibleWidth;
    visibleHeight_ = originalVisibleHeight;
}

sk_sp<SkImage> SkiaDrawingEngine::makeSnapshot() {
    std::lock_guard<std::recursive_mutex> lock(stateMutex_);

    SkImageInfo info = SkImageInfo::MakeN32Premul(width_, height_);
    sk_sp<SkSurface> surface = SkSurfaces::Raster(info);
    const float originalRenderScale = renderScale_;
    const float originalVisibleLeft = visibleLeft_;
    const float originalVisibleTop = visibleTop_;
    const float originalVisibleWidth = visibleWidth_;
    const float originalVisibleHeight = visibleHeight_;
    renderScale_ = 1.0f;
    visibleLeft_ = 0.0f;
    visibleTop_ = 0.0f;
    visibleWidth_ = static_cast<float>(width_);
    visibleHeight_ = static_cast<float>(height_);
    render(surface->getCanvas());
    renderScale_ = originalRenderScale;
    visibleLeft_ = originalVisibleLeft;
    visibleTop_ = originalVisibleTop;
    visibleWidth_ = originalVisibleWidth;
    visibleHeight_ = originalVisibleHeight;
    return surface->makeImageSnapshot();
}

std::vector<std::string> SkiaDrawingEngine::batchExportPages(
    const std::vector<std::vector<uint8_t>>& pagesData,
    const std::vector<std::string>& backgroundTypes,
    const std::vector<sk_sp<SkImage>>& pdfBackgrounds,
    const std::vector<int>& pageIndices,
    float scale
) {
    std::lock_guard<std::recursive_mutex> lock(stateMutex_);

    std::vector<std::string> results;
    results.reserve(pagesData.size());

    int scaledWidth = static_cast<int>(width_ * scale);
    int scaledHeight = static_cast<int>(height_ * scale);
    SkImageInfo info = SkImageInfo::MakeN32Premul(scaledWidth, scaledHeight);
    sk_sp<SkSurface> exportSurface = SkSurfaces::Raster(info);

    if (!exportSurface) {
        printf("[C++] batchExportPages: Failed to create export surface\n");
        return results;
    }

    // Save original state
    auto originalStrokes = strokes_;
    auto originalEraserCircles = eraserCircles_;
    auto originalPdfBackground = pdfBackgroundImage_;
    auto originalBackgroundType = backgroundType_;
    float originalBackgroundOriginY = backgroundOriginY_;
    auto originalUndoStack = undoStack_;
    auto originalRedoStack = redoStack_;
    const float originalRenderScale = renderScale_;
    const float originalVisibleLeft = visibleLeft_;
    const float originalVisibleTop = visibleTop_;
    const float originalVisibleWidth = visibleWidth_;
    const float originalVisibleHeight = visibleHeight_;

    renderScale_ = 1.0f;
    visibleLeft_ = 0.0f;
    visibleTop_ = 0.0f;
    visibleWidth_ = static_cast<float>(width_);
    visibleHeight_ = static_cast<float>(height_);

    for (size_t i = 0; i < pagesData.size(); ++i) {
        SkCanvas* canvas = exportSurface->getCanvas();
        canvas->clear(SK_ColorTRANSPARENT);
        canvas->save();
        canvas->scale(scale, scale);

        backgroundType_ = (i < backgroundTypes.size() && !backgroundTypes[i].empty())
            ? backgroundTypes[i] : "plain";
        pdfBackgroundImage_ = (i < pdfBackgrounds.size()) ? pdfBackgrounds[i] : nullptr;
        int pageIndex = (i < pageIndices.size()) ? pageIndices[i] : static_cast<int>(i);
        backgroundOriginY_ = std::max(0, pageIndex) * static_cast<float>(height_);

        if (!pagesData[i].empty()) {
            if (!deserializeDrawing(pagesData[i])) {
                strokes_.clear();
                eraserCircles_.clear();
            }
        } else {
            strokes_.clear();
            eraserCircles_.clear();
        }

        normalizeStrokeColorsForRasterExport(strokes_);

        markStrokeCachesDirty();
        needsEraserMaskRedraw_ = true;
        render(canvas);
        canvas->restore();

        sk_sp<SkImage> snapshot = exportSurface->makeImageSnapshot();
        if (snapshot) {
            sk_sp<SkData> pngData = SkPngEncoder::Encode(nullptr, snapshot.get(), {});
            if (pngData) {
                results.push_back("data:image/png;base64," +
                    BatchExporter::encodeBase64(pngData->data(), pngData->size()));
            } else {
                results.push_back("");
            }
        } else {
            results.push_back("");
        }
    }

    // Restore original state
    strokes_ = originalStrokes;
    eraserCircles_ = originalEraserCircles;
    cachedEraserCircleCount_ = 0;
    pdfBackgroundImage_ = originalPdfBackground;
    backgroundType_ = originalBackgroundType;
    backgroundOriginY_ = originalBackgroundOriginY;
    undoStack_ = std::move(originalUndoStack);
    redoStack_ = std::move(originalRedoStack);
    renderScale_ = originalRenderScale;
    visibleLeft_ = originalVisibleLeft;
    visibleTop_ = originalVisibleTop;
    visibleWidth_ = originalVisibleWidth;
    visibleHeight_ = originalVisibleHeight;
    markStrokeCachesDirty();
    needsEraserMaskRedraw_ = true;

    return results;
}

void SkiaDrawingEngine::setEraserCursor(float x, float y, float radius, bool visible) {
    std::lock_guard<std::recursive_mutex> lock(stateMutex_);

    eraserCursorX_ = x;
    eraserCursorY_ = y;
    eraserCursorRadius_ = radius;
    showEraserCursor_ = visible;
}

bool SkiaDrawingEngine::isEraserCursorVisible() const {
    std::lock_guard<std::recursive_mutex> lock(stateMutex_);
    return showEraserCursor_;
}

} // namespace nativedrawing
