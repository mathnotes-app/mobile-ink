#include "SkiaDrawingEngine.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <include/core/SkBBHFactory.h>
#include <include/core/SkPictureRecorder.h>
#include <include/gpu/ganesh/SkSurfaceGanesh.h>

namespace nativedrawing {
namespace {
constexpr int kStrokeTileSize = 512;
constexpr size_t kMaxStrokeTileCacheBytes = 96 * 1024 * 1024;
constexpr size_t kMaxCrayonPictureCacheBytes = 32 * 1024 * 1024;
constexpr size_t kMaxPenPictureCacheBytes = 16 * 1024 * 1024;

enum class EraserMaskMode { none, clip, clearLayer };

EraserMaskMode beginEraserMask(SkCanvas* canvas, const Stroke& stroke, const SkRect& bounds) {
    if (stroke.erasedBy.empty()) return EraserMaskMode::none;
    stroke.ensureEraserCacheValid();
    if (stroke.cachedEraserPath.isEmpty()) return EraserMaskMode::none;
    if (stroke.toolType == "crayon") {
        // Apply the mask once instead of clipping every textured draw in the stroke.
        canvas->saveLayer(&bounds, nullptr);
        return EraserMaskMode::clearLayer;
    }
    canvas->save();
    canvas->clipPath(stroke.cachedEraserPath, SkClipOp::kDifference);
    return EraserMaskMode::clip;
}

void endEraserMask(SkCanvas* canvas, const Stroke& stroke, EraserMaskMode mode) {
    if (mode == EraserMaskMode::clearLayer) {
        SkPaint clearPaint;
        clearPaint.setBlendMode(SkBlendMode::kClear);
        canvas->drawPath(stroke.cachedEraserPath, clearPaint);
    }
    if (mode != EraserMaskMode::none) canvas->restore();
}

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

sk_sp<SkPicture> SkiaDrawingEngine::strokePicture(const Stroke& stroke, const SkPaint& paint) {
    uint32_t widthBits = 0;
    const float width = paint.getStrokeWidth();
    static_assert(sizeof(widthBits) == sizeof(width));
    std::memcpy(&widthBits, &width, sizeof(width));
    const StrokePictureKey key{stroke.path.getGenerationID(), displayInkPaint(paint).getColor(), widthBits};
    const bool isPen = stroke.toolType == "pen";
    auto& cache = isPen ? penPictureCache_ : crayonPictureCache_;
    const size_t limit = isPen ? kMaxPenPictureCacheBytes : kMaxCrayonPictureCacheBytes;
    auto found = cache.entries.find(key);
    if (found != cache.entries.end()) {
        found->second.used = ++cache.useCounter;
        return found->second.picture;
    }
    SkPictureRecorder recorder;
    SkRTreeFactory hierarchy;
    auto* recording = recorder.beginRecording(
        SkRect::MakeWH(static_cast<float>(width_), static_cast<float>(height_)), &hierarchy);
    renderStrokeGeometry(recording, stroke, paint);
    auto picture = recorder.finishRecordingAsPicture();
    // A picture also retains its path points outside the recording itself.
    // Budget conservatively for the interpolated pen outline as well.
    const size_t pointBytes = isPen
        ? (stroke.points.size() > limit / 256 ? limit : stroke.points.size() * 256) : 0;
    const size_t bytes = picture ? picture->approximateBytesUsed() + pointBytes : 0;
    if (picture && key.pathID && bytes <= limit) {
        while (cache.bytes + bytes > limit && !cache.entries.empty()) {
            auto oldest = cache.entries.begin();
            for (auto it = cache.entries.begin(); it != cache.entries.end(); ++it)
                if (it->second.used < oldest->second.used) oldest = it;
            cache.bytes -= oldest->second.bytes;
            cache.entries.erase(oldest);
        }
        cache.bytes += bytes;
        cache.entries.emplace(key, StrokePictureEntry{picture, bytes, ++cache.useCounter});
    }
    return picture;
}

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

void SkiaDrawingEngine::setViewportMotionActive(bool active) {
    std::lock_guard<std::recursive_mutex> lock(stateMutex_);
    viewportMotionActive_ = active;
}

bool SkiaDrawingEngine::drawCachedStrokeTileFallback(
    SkCanvas* canvas, const StrokeTileKey& key, int tileWidth, int tileHeight
) {
    const float targetScale = key.scaleBucket / 100.0f;
    const float left = key.tileX * kStrokeTileSize / targetScale;
    const float top = key.tileY * kStrokeTileSize / targetScale;
    const float right = std::min(static_cast<float>(width_), (key.tileX * kStrokeTileSize + tileWidth) / targetScale);
    const float bottom = std::min(static_cast<float>(height_), (key.tileY * kStrokeTileSize + tileHeight) / targetScale);
    std::array<int, 10> scales = {25, 50, 75, 100, 150, 200, 250, 300, 400, 500};
    std::sort(scales.begin(), scales.end(), [targetScale](int a, int b) {
        return std::fabs(std::log((a / 100.0f) / targetScale)) < std::fabs(std::log((b / 100.0f) / targetScale));
    });
    for (const int bucket : scales) {
        if (bucket == key.scaleBucket) continue;
        const float sourceScale = bucket / 100.0f;
        const int startX = std::max(0, static_cast<int>(std::floor(left * sourceScale / kStrokeTileSize)));
        const int startY = std::max(0, static_cast<int>(std::floor(top * sourceScale / kStrokeTileSize)));
        const int endX = std::max(startX, static_cast<int>(std::ceil(right * sourceScale / kStrokeTileSize)) - 1);
        const int endY = std::max(startY, static_cast<int>(std::ceil(bottom * sourceScale / kStrokeTileSize)) - 1);
        bool complete = true;
        for (int y = startY; complete && y <= endY; ++y) {
            for (int x = startX; x <= endX; ++x) {
                auto it = strokeTileCache_.find(StrokeTileKey{bucket, x, y, key.epoch});
                if (it == strokeTileCache_.end() || !it->second.image) { complete = false; break; }
            }
        }
        if (!complete) continue;
        for (int y = startY; complete && y <= endY; ++y) {
            for (int x = startX; x <= endX; ++x) {
                const StrokeTileKey sourceKey{bucket, x, y, key.epoch};
                auto it = strokeTileCache_.find(sourceKey);
                if (it == strokeTileCache_.end() || !applyAppendedStrokes(canvas, sourceKey, it->second)) {
                    complete = false;
                    break;
                }
            }
        }
        if (!complete) continue;
        canvas->save();
        canvas->clipRect(SkRect::MakeXYWH(key.tileX * kStrokeTileSize, key.tileY * kStrokeTileSize, tileWidth, tileHeight));
        canvas->scale(targetScale / sourceScale, targetScale / sourceScale);
        for (int y = startY; y <= endY; ++y) {
            for (int x = startX; x <= endX; ++x) {
                auto it = strokeTileCache_.find(StrokeTileKey{bucket, x, y, key.epoch});
                it->second.lastUsed = ++strokeTileUseCounter_;
                canvas->drawImage(it->second.image, x * kStrokeTileSize, y * kStrokeTileSize,
                                  SkSamplingOptions(SkFilterMode::kLinear));
            }
        }
        canvas->restore();
        return true;
    }
    return false;
}

void SkiaDrawingEngine::appendStrokeToCachedTiles(const SkRect& bounds, size_t strokeIndex) {
    selectionDragLayers_.clear();
    if (bounds.isEmpty()) return;
    for (auto it = strokeTileCache_.begin(); it != strokeTileCache_.end();) {
        const auto& key = it->first;
        auto& entry = it->second;
        if (key.epoch != strokeTileEpoch_ || !entry.image) { ++it; continue; }
        const float scale = key.scaleBucket / 100.0f;
        const SkRect tile = SkRect::MakeLTRB(key.tileX * kStrokeTileSize / scale,
            key.tileY * kStrokeTileSize / scale, (key.tileX + 1) * kStrokeTileSize / scale,
            (key.tileY + 1) * kStrokeTileSize / scale);
        if (SkRect::Intersects(tile, bounds)) {
            if (entry.appendedStrokes.size() >= 128) {
                strokeTileCacheBytes_ -= std::min(strokeTileCacheBytes_, entry.bytes);
                it = strokeTileCache_.erase(it);
                continue;
            }
            entry.appendedStrokes.push_back(strokeIndex);
        }
        ++it;
    }
}

bool SkiaDrawingEngine::applyAppendedStrokes(SkCanvas* canvas, const StrokeTileKey& key, StrokeTileEntry& entry) {
    if (entry.appendedStrokes.empty()) return true;
    if (!entry.image) return false;
    for (size_t index : entry.appendedStrokes) {
        if (index >= strokes_.size() || strokes_[index].isEraser || !strokes_[index].erasedBy.empty()) return false;
    }
    std::unordered_map<size_t, sk_sp<SkPicture>> pictures;
    auto image = renderStrokeTile(canvas, key, entry.image->width(), entry.image->height(),
        key.scaleBucket / 100.0f, entry.appendedStrokes, pictures, entry.image);
    if (!image) return false;
    entry.image = std::move(image);
    entry.appendedStrokes.clear();
    return true;
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
    selectionDragLayers_.clear();
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
    const std::vector<size_t>& candidates,
    std::unordered_map<size_t, sk_sp<SkPicture>>& strokePictures,
    const sk_sp<SkImage>& base
) {
    SkImageInfo info = SkImageInfo::MakeN32Premul(tileWidth, tileHeight);
    // Coverage AA on a single-sample target can rasterize each pressure path
    // into a separate CPU mask. Multisampled tiles let Ganesh tessellate those
    // paths on the GPU. Allocate the cache target first so allocation failure
    // can fall back without retaining multisampled attachments in the cache.
    sk_sp<SkSurface> tileSurface;
    sk_sp<SkSurface> resolved;
    if (auto* context = targetCanvas->recordingContext()) {
        resolved = SkSurfaces::RenderTarget(context, skgpu::Budgeted::kYes, info, 0, nullptr);
        if (resolved) {
            tileSurface = SkSurfaces::RenderTarget(context, skgpu::Budgeted::kYes, info, 4, nullptr);
            if (!tileSurface) tileSurface = resolved;
        }
    } else {
        tileSurface = targetCanvas->makeSurface(info);
    }
    if (!tileSurface) {
        tileSurface = SkSurfaces::Raster(info);
    }
    if (!tileSurface) {
        return nullptr;
    }

    SkCanvas* tileCanvas = tileSurface->getCanvas();
    tileCanvas->clear(SK_ColorTRANSPARENT);
    if (base) tileCanvas->drawImage(base, 0, 0);
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

    size_t imageIndex = base ? imageLayers_.size() : 0;
    for (size_t i : candidates) {
        const auto& stroke = strokes_[i];
        if (stroke.isEraser) {
            continue;
        }
        while (imageIndex < imageLayers_.size() && imageLayers_[imageIndex].layerOrder <= stroke.layerOrder) {
            renderImageLayer(tileCanvas, imageLayers_[imageIndex++]);
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

        SkRect layerBounds;
        if (!layerBounds.intersect(strokeBounds, tileBounds)) continue;
        const auto mask = beginEraserMask(tileCanvas, stroke, layerBounds);

        if (stroke.toolType == "pen" && stroke.points.size() >= 32 &&
            stroke.points.size() <= kMaxPenPictureCacheBytes / 256) {
            // Do not retain all pen pictures for the duration of the frame:
            // a large note can contain more geometry than the bounded cache.
            if (auto picture = strokePicture(stroke, strokePaint)) {
                tileCanvas->drawPicture(picture);
            } else {
                renderStrokeGeometry(tileCanvas, stroke, strokePaint);
            }
        } else if (stroke.toolType == "crayon" && stroke.points.size() >= 64 && !tileBounds.contains(strokeBounds)) {
            auto it = strokePictures.find(i);
            if (it == strokePictures.end()) {
                // Keep bounded, immutable geometry across frames so each new
                // zoom bucket need not rebuild the same stroke segments.
                it = strokePictures.emplace(i, strokePicture(stroke, strokePaint)).first;
            }
            if (it->second) tileCanvas->drawPicture(it->second);
        } else {
            renderStrokeGeometry(tileCanvas, stroke, strokePaint);
        }

        endEraserMask(tileCanvas, stroke, mask);
    }
    while (imageIndex < imageLayers_.size()) renderImageLayer(tileCanvas, imageLayers_[imageIndex++]);

    if (resolved && resolved.get() != tileSurface.get()) {
        // Cache resolved pixels independently. A snapshot of the multisampled
        // render target can also retain its much larger MSAA attachment, which
        // prevents Ganesh from reusing that attachment for the next tile.
        SkPaint copyPaint;
        copyPaint.setBlendMode(SkBlendMode::kSrc);
        tileSurface->draw(resolved->getCanvas(), 0, 0, &copyPaint);
        return resolved->makeImageSnapshot();
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

bool SkiaDrawingEngine::renderCachedSelectionDrag(SkCanvas* canvas, float scale) {
    SkRect clip;
    if (!canvas->getLocalClipBounds(&clip) || clip.isEmpty()) return false;
    const void* context = canvas->recordingContext();
    if (!selectionDragLayers_.empty() && selectionDragContext_ == context &&
        selectionDragScale_ == scale && selectionDragEpoch_ == strokeTileEpoch_ &&
        selectionDragIndices_ == selectedIndices_ && selectionDragCoverage_.contains(clip)) {
        for (const auto& layer : selectionDragLayers_) {
            canvas->save();
            if (layer.selected) canvas->translate(selectionOffsetX_, selectionOffsetY_);
            SkPaint paint;
            paint.setBlendMode(layer.blendMode);
            canvas->drawImageRect(layer.image, layer.bounds, SkSamplingOptions(SkFilterMode::kLinear), &paint);
            canvas->restore();
        }
        return true;
    }

    selectionDragLayers_.clear();
    struct Item { size_t index; bool image; };
    struct Run { bool selected; SkBlendMode blend; SkRect bounds = SkRect::MakeEmpty(); std::vector<Item> items; };
    std::vector<Run> runs;
    // The stationary parts need only cover the current viewport. Selected ink
    // must cover its full bounds so offscreen ink can move into view.
    SkRect coverage = clip;
    coverage.outset(2.0f / scale, 2.0f / scale);
    auto append = [&](bool selected, bool isImage, size_t index, SkRect bounds, SkBlendMode blend) {
        if (!selected && !bounds.intersect(coverage)) return;
        if (bounds.isEmpty()) return;
        // Multiply strokes need their own layers so they blend with all of the
        // content beneath them, including ink that moves independently.
        if (runs.empty() || runs.back().selected != selected ||
            runs.back().blend != SkBlendMode::kSrcOver || blend != SkBlendMode::kSrcOver)
            runs.push_back(Run{selected, blend});
        auto& run = runs.back();
        run.bounds.join(bounds);
        run.items.push_back(Item{index, isImage});
    };
    auto appendImage = [&](size_t index) {
        const auto& layer = imageLayers_[index];
        if (layer.hidden || !layer.image) return;
        SkMatrix rotation;
        rotation.setRotate(layer.rotation, layer.bounds.centerX(), layer.bounds.centerY());
        SkRect bounds = rotation.mapRect(layer.bounds);
        bounds.outset(2, 2);
        append(false, true, index, bounds, SkBlendMode::kSrcOver);
    };
    size_t imageIndex = 0;
    for (size_t i = 0; i < strokes_.size(); ++i) {
        const auto& stroke = strokes_[i];
        while (imageIndex < imageLayers_.size() && imageLayers_[imageIndex].layerOrder <= stroke.layerOrder)
            appendImage(imageIndex++);
        SkRect bounds = stroke.path.getBounds();
        const float outset = std::max(8.0f, stroke.paint.getStrokeWidth() * 2.0f);
        bounds.outset(outset, outset);
        const bool selected = selectedIndices_.count(i) > 0;
        if (!selected && !SkRect::Intersects(bounds, coverage)) continue;
        const auto blend = stroke.paint.asBlendMode();
        if (!blend || (*blend != SkBlendMode::kSrcOver && *blend != SkBlendMode::kMultiply)) return false;
        append(selected, false, i, bounds, *blend);
    }
    while (imageIndex < imageLayers_.size()) appendImage(imageIndex++);
    if (runs.empty() || runs.size() > 32) return false;
    // Bound both individual textures and the total transient allocation.
    size_t totalBytes = 0;
    for (auto& run : runs) {
        const float left = std::floor(run.bounds.left() * scale);
        const float top = std::floor(run.bounds.top() * scale);
        const float right = std::ceil(run.bounds.right() * scale);
        const float bottom = std::ceil(run.bounds.bottom() * scale);
        if (!std::isfinite(left) || !std::isfinite(top) || !std::isfinite(right) || !std::isfinite(bottom) ||
            right <= left || bottom <= top || right - left > 4096 || bottom - top > 4096) return false;
        const size_t bytes = static_cast<size_t>(right - left) * static_cast<size_t>(bottom - top) * 4;
        if (bytes > 64 * 1024 * 1024 - totalBytes) return false;
        totalBytes += bytes;
        run.bounds = SkRect::MakeLTRB(left / scale, top / scale, right / scale, bottom / scale);
    }

    std::vector<SelectionDragLayer> layers;
    layers.reserve(runs.size());
    for (const auto& run : runs) {
        const int width = static_cast<int>(std::round(run.bounds.width() * scale));
        const int height = static_cast<int>(std::round(run.bounds.height() * scale));
        auto surface = canvas->makeSurface(SkImageInfo::MakeN32Premul(width, height));
        if (!surface) return false;
        auto* layerCanvas = surface->getCanvas();
        layerCanvas->clear(SK_ColorTRANSPARENT);
        layerCanvas->scale(scale, scale);
        layerCanvas->translate(-run.bounds.left(), -run.bounds.top());
        for (const auto& item : run.items) {
            if (item.image) { renderImageLayer(layerCanvas, imageLayers_[item.index]); continue; }
            const auto& stroke = strokes_[item.index];
            SkPaint paint = stroke.paint;
            if (!stroke.isEraser)
                paint.setAlpha(static_cast<uint8_t>(stroke.paint.getAlpha() * stroke.originalAlphaMod));
            bool clipped = false;
            if (!stroke.erasedBy.empty()) {
                stroke.ensureEraserCacheValid();
                if (!stroke.cachedEraserPath.isEmpty()) {
                    layerCanvas->save();
                    layerCanvas->clipPath(stroke.cachedEraserPath, SkClipOp::kDifference);
                    clipped = true;
                }
            }
            renderStrokeGeometry(layerCanvas, stroke, paint);
            if (clipped) layerCanvas->restore();
        }
        auto image = surface->makeImageSnapshot();
        if (!image) return false;
        layers.push_back(SelectionDragLayer{std::move(image), run.bounds, run.selected, run.blend});
    }
    selectionDragLayers_ = std::move(layers);
    selectionDragIndices_ = selectedIndices_;
    selectionDragCoverage_ = coverage;
    selectionDragContext_ = context;
    selectionDragScale_ = scale;
    selectionDragEpoch_ = strokeTileEpoch_;
    return renderCachedSelectionDrag(canvas, scale);
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
        if (pendingDeleteIndices_.empty() && viewportOnly_ && isDraggingSelection_ &&
            renderCachedSelectionDrag(canvas, scale)) {
            canvas->restore();
            return;
        }
        SkRect clip;
        const bool hasClip = canvas->getLocalClipBounds(&clip);
        size_t imageIndex = 0;
        for (size_t i = 0; i < strokes_.size(); ++i) {
            const auto& stroke = strokes_[i];
            while (imageIndex < imageLayers_.size() && imageLayers_[imageIndex].layerOrder <= stroke.layerOrder)
                renderImageLayer(canvas, imageLayers_[imageIndex++]);
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
            SkRect localBounds = stroke.path.getBounds();
            localBounds.outset(outset, outset);
            const auto mask = beginEraserMask(canvas, stroke, localBounds);
            renderStrokeGeometry(canvas, stroke, strokePaint);
            endEraserMask(canvas, stroke, mask);
            canvas->restore();
        }
        while (imageIndex < imageLayers_.size()) renderImageLayer(canvas, imageLayers_[imageIndex++]);
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
    std::unordered_map<size_t, sk_sp<SkPicture>> strokePictures;
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
            if (it != strokeTileCache_.end() && !applyAppendedStrokes(canvas, key, it->second)) {
                strokeTileCacheBytes_ -= std::min(strokeTileCacheBytes_, it->second.bytes);
                strokeTileCache_.erase(it);
                it = strokeTileCache_.end();
            }
            if (it == strokeTileCache_.end()) {
                if (viewportMotionActive_ && drawCachedStrokeTileFallback(canvas, key, tileWidth, tileHeight)) {
                    continue;
                }
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
                sk_sp<SkImage> image = renderStrokeTile(canvas, key, tileWidth, tileHeight, bucketScale, candidates, strokePictures);
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
