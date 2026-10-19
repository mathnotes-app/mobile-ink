#include "SkiaDrawingEngine.h"

#include <algorithm>
#include <cmath>

namespace nativedrawing {
namespace {
constexpr int kStrokeTileSize = 512;
constexpr size_t kMaxStrokeTileCacheBytes = 96 * 1024 * 1024;

int renderScaleBucket(float scale) {
    const float clamped = std::max(kMinimumRenderScale, std::min(kMaximumRenderScale, scale));
    const float buckets[] = {0.25f, 0.5f, 0.75f, 1.0f, 1.5f, 2.0f, 2.5f, 3.0f, 4.0f, 5.0f};
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

} // namespace

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

void SkiaDrawingEngine::renderVisibleViewport(SkCanvas* canvas) {
    if (!canvas) return;
    std::lock_guard<std::recursive_mutex> lock(stateMutex_);
    canvas->save();
    canvas->translate(-visibleLeft_ * renderScale_, -visibleTop_ * renderScale_);
    render(canvas);
    canvas->restore();
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

sk_sp<SkImage> SkiaDrawingEngine::renderStrokeTile(
    SkCanvas* targetCanvas,
    const StrokeTileKey& key,
    int tileWidth,
    int tileHeight,
    float scale,
    const std::vector<size_t>& candidates
) {
    SkImageInfo info = SkImageInfo::MakeN32Premul(tileWidth, tileHeight);
    sk_sp<SkSurface> tileSurface = targetCanvas->makeSurface(info);
    if (!tileSurface) {
        tileSurface = SkSurfaces::Raster(info);
    }
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

    for (size_t i : candidates) {
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

    if (!viewportOnly_ && !selectedIndices_.empty() && isDraggingSelection_) {
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

    if (!pendingDeleteIndices_.empty() || (viewportOnly_ && isDraggingSelection_)) {
        canvas->save();
        canvas->scale(scale, scale);
        SkRect clip;
        const bool hasClip = canvas->getLocalClipBounds(&clip);
        for (size_t i = 0; i < strokes_.size(); ++i) {
            const auto& stroke = strokes_[i];
            const bool translated = isDraggingSelection_ && selectedIndices_.count(i) > 0;
            SkRect bounds = stroke.path.getBounds();
            const float outset = std::max(8.0f, stroke.paint.getStrokeWidth() * 2.0f);
            bounds.outset(outset, outset);
            if (translated) bounds.offset(selectionOffsetX_, selectionOffsetY_);
            if (hasClip && !bounds.intersects(clip)) continue;
            SkPaint strokePaint = stroke.paint;
            if (!stroke.isEraser) {
                uint8_t baseAlpha = stroke.paint.getAlpha();
                const float alphaMod = pendingDeleteIndices_.count(i) > 0
                    ? stroke.originalAlphaMod * 0.3f
                    : stroke.originalAlphaMod;
                strokePaint.setAlpha(static_cast<uint8_t>(baseAlpha * alphaMod));
            }

            canvas->save();
            if (translated) canvas->translate(selectionOffsetX_, selectionOffsetY_);
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
            canvas->restore();
        }
        canvas->restore();
        return;
    }

    const void* context = canvas->recordingContext();
    if (strokeTileContext_ != context) {
        strokeTileCache_.clear();
        strokeTileCacheBytes_ = 0;
        strokeTileContext_ = context;
    }

    const int bucket = renderScaleBucket(scale);
    const float bucketScale = bucket / 100.0f;
    const float targetWidth = static_cast<float>(width_) * bucketScale;
    const float targetHeight = static_cast<float>(height_) * bucketScale;
    const float overscan = (static_cast<float>(kStrokeTileSize) * 2.0f) / bucketScale;
    SkRect visibleBounds = SkRect::MakeLTRB(
        std::max(0.0f, visibleLeft_ - overscan),
        std::max(0.0f, visibleTop_ - overscan),
        std::min(static_cast<float>(width_), visibleLeft_ + visibleWidth_ + overscan),
        std::min(static_cast<float>(height_), visibleTop_ + visibleHeight_ + overscan)
    );
    // A cropped target cannot display the overscan tiles. Building them here
    // blocks the first sharp frame after zoom for work that will be discarded.
    SkRect targetClip;
    if (!canvas->getLocalClipBounds(&targetClip)) return;
    targetClip = SkRect::MakeLTRB(
        targetClip.left() / bucketScale, targetClip.top() / bucketScale,
        targetClip.right() / bucketScale, targetClip.bottom() / bucketScale
    );
    if (!visibleBounds.intersect(targetClip)) return;
    // Collect once, only if a missing tile needs geometry. Scanning the entire
    // lecture independently for every tile multiplies work as notes grow.
    std::vector<size_t> candidates;
    bool candidatesReady = false;
    const float visibleLeft = visibleBounds.left();
    const float visibleTop = visibleBounds.top();
    const float visibleRight = visibleBounds.right();
    const float visibleBottom = visibleBounds.bottom();

    const int startTileX = std::max(0, static_cast<int>(std::floor((visibleLeft * bucketScale) / kStrokeTileSize)));
    const int startTileY = std::max(0, static_cast<int>(std::floor((visibleTop * bucketScale) / kStrokeTileSize)));
    const int endTileX = std::max(startTileX, static_cast<int>(std::ceil((visibleRight * bucketScale) / kStrokeTileSize)) - 1);
    const int endTileY = std::max(startTileY, static_cast<int>(std::ceil((visibleBottom * bucketScale) / kStrokeTileSize)) - 1);
    const int maxTileX = std::max(0, static_cast<int>(std::ceil(targetWidth / kStrokeTileSize)) - 1);
    const int maxTileY = std::max(0, static_cast<int>(std::ceil(targetHeight / kStrokeTileSize)) - 1);

    // Cached tiles must contain their complete geometry, including portions
    // outside this frame's clip that a later pan may expose.
    const SkRect candidateBounds = SkRect::MakeLTRB(
        startTileX * kStrokeTileSize / bucketScale, startTileY * kStrokeTileSize / bucketScale,
        (endTileX + 1) * kStrokeTileSize / bucketScale, (endTileY + 1) * kStrokeTileSize / bucketScale);
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
                if (!candidatesReady) {
                    for (size_t index = 0; index < strokes_.size(); ++index) {
                        const auto& stroke = strokes_[index];
                        if (stroke.isEraser) continue;
                        SkRect bounds = stroke.path.getBounds();
                        const float outset = std::max(8.0f, stroke.paint.getStrokeWidth() * 2.0f);
                        bounds.outset(outset, outset);
                        if (bounds.intersects(candidateBounds)) candidates.push_back(index);
                    }
                    candidatesReady = true;
                }
                sk_sp<SkImage> image = renderStrokeTile(canvas, key, tileWidth, tileHeight, bucketScale, candidates);
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

} // namespace nativedrawing
