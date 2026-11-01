#include "SkiaDrawingEngine.h"
#include "StrokeTilePreparation.h"
#include "PathRenderer.h"
#include <include/core/SkImage.h>
#include <include/core/SkMatrix.h>
#include <cmath>
#include <climits>

namespace nativedrawing {
namespace {
constexpr int kTileSize = 512;
// Prepared tiles stay GPU-resident and share the existing tile-cache budget.
constexpr size_t kMaxPreparedWorkingBytes = 96 * 1024 * 1024;
}

std::unique_ptr<StrokeTilePreparation> SkiaDrawingEngine::prepareStrokeTiles(
    float scale, float left, float top, float width, float height) {
    std::lock_guard<std::recursive_mutex> lock(stateMutex_);
    if (!viewportOnly_ || !strokeTileContext_ || isDraggingSelection_ || isTransformingSelection_ ||
        !pendingDeleteIndices_.empty() || !pendingPixelEraserCircles_.empty() ||
        !std::isfinite(scale) || !std::isfinite(left) ||
        !std::isfinite(top) || !std::isfinite(width) || !std::isfinite(height) ||
        scale < .25f || scale > 5 || left < 0 || top < 0 || left >= width_ || top >= height_ ||
        width <= 0 || height <= 0 || !std::isfinite(left + width) || !std::isfinite(top + height) ||
        width * scale > 4096 || height * scale > 4096 ||
        static_cast<double>(width_) * scale >= INT_MAX || static_cast<double>(height_) * scale >= INT_MAX) return nullptr;
    auto batch = std::make_unique<StrokeTilePreparation>();
    batch->drawing = std::make_unique<SkiaDrawingEngine>(width_, height_, true);
    batch->drawing->setRenderViewport(scale, left, top, width, height);
    batch->bucket = static_cast<int>(std::round(batch->drawing->renderScale_ * 100));
    if (width * (batch->bucket / 100.f) > 4096 || height * (batch->bucket / 100.f) > 4096) return nullptr;
    batch->revision = strokeTileContentRevision_;
    batch->epoch = strokeTileEpoch_;
    batch->owner = strokeTileIdentity_;
    batch->context = strokeTileContext_;
    const float s = batch->bucket / 100.f;
    if (static_cast<double>(width_) * s >= INT_MAX || static_cast<double>(height_) * s >= INT_MAX) return nullptr;
    const int fullWidth = static_cast<int>(std::ceil(width_ * s));
    const int fullHeight = static_cast<int>(std::ceil(height_ * s));
    // Ratio-to-pixel conversions take slightly different routes in UIKit and
    // the engine. Include a two-pixel guard so rounding cannot leave an edge
    // tile unprepared when the target frame is applied.
    const float guard = 2.f / s;
    const int x0 = std::max(0, static_cast<int>(std::floor(std::max(0.f, left - guard) * s / kTileSize)));
    const int y0 = std::max(0, static_cast<int>(std::floor(std::max(0.f, top - guard) * s / kTileSize)));
    const int x1 = std::min((fullWidth - 1) / kTileSize,
        static_cast<int>(std::ceil(std::min(static_cast<float>(width_), left + width + guard) * s / kTileSize)) - 1);
    const int y1 = std::min((fullHeight - 1) / kTileSize,
        static_cast<int>(std::ceil(std::min(static_cast<float>(height_), top + height + guard) * s / kTileSize)) - 1);
    size_t tileBytes = 0;
    for (int y = y0; y <= y1; ++y) for (int x = x0; x <= x1; ++x) {
        const StrokeTilePreparation::Tile tile{x, y, std::min(kTileSize, fullWidth - x * kTileSize),
                                                     std::min(kTileSize, fullHeight - y * kTileSize)};
        batch->expected.push_back(tile);
        tileBytes += static_cast<size_t>(tile.width) * tile.height * 4;
        if (tileBytes > kMaxPreparedWorkingBytes) return nullptr;
        StrokeTileKey key{batch->bucket, x, y, batch->epoch};
        auto existing = strokeTileCache_.find(key);
        if (existing != strokeTileCache_.end() && existing->second.image && existing->second.appendedStrokes.empty()) {
            existing->second.lastUsed = ++strokeTileUseCounter_;
            continue;
        }
        batch->tiles.push_back(tile);
    }
    if (batch->expected.empty()) return nullptr;
    if (!batch->tiles.empty()) {
        const SkRect needed = SkRect::MakeLTRB(static_cast<float>(x0) * kTileSize / s,
            static_cast<float>(y0) * kTileSize / s, static_cast<float>(x1 + 1) * kTileSize / s,
            static_cast<float>(y1 + 1) * kTileSize / s);
        // Copy only visible geometry; snapshotting an entire long notebook on
        // the input thread would make each new zoom target more expensive.
        constexpr size_t kMaxSnapshotBytes = 16 * 1024 * 1024;
        size_t bytes = 0;
        std::vector<size_t> indices;
        for (size_t i = 0; i < strokes_.size(); ++i) {
            const auto& stroke = strokes_[i];
            if (stroke.isEraser) continue;
            SkRect bounds = stroke.path.getBounds();
            const float outset = std::max(8.f, stroke.paint.getStrokeWidth() * 2.f);
            bounds.outset(outset, outset);
            if (!bounds.intersects(needed)) continue;
            if (sizeof(Stroke) > kMaxSnapshotBytes - bytes) return nullptr;
            bytes += sizeof(Stroke);
            if (stroke.points.size() > (kMaxSnapshotBytes - bytes) / sizeof(Point)) return nullptr;
            bytes += stroke.points.size() * sizeof(Point);
            if (stroke.erasedBy.size() > (kMaxSnapshotBytes - bytes) / sizeof(EraserCircle)) return nullptr;
            bytes += stroke.erasedBy.size() * sizeof(EraserCircle);
            // Unordered-set nodes include allocation and pointer overhead.
            constexpr size_t kIndexBytes = sizeof(size_t) + 2 * sizeof(void*);
            if (stroke.affectedStrokeIndices.size() > (kMaxSnapshotBytes - bytes) / kIndexBytes) return nullptr;
            bytes += stroke.affectedStrokeIndices.size() * kIndexBytes;
            indices.push_back(i);
        }
        batch->drawing->strokes_.reserve(indices.size());
        for (size_t i : indices) batch->drawing->strokes_.push_back(strokes_[i]);
        for (const auto& image : imageLayers_) {
            if (image.hidden || !image.image) continue;
            SkMatrix rotation;
            rotation.setRotate(image.rotation, image.bounds.centerX(), image.bounds.centerY());
            SkRect bounds = rotation.mapRect(image.bounds);
            bounds.outset(2, 2);
            if (bounds.intersects(needed)) batch->drawing->imageLayers_.push_back(image);
        }
        batch->drawing->setInkDisplayTransform(displayInkDark_, displayInkSwap_);
        batch->drawing->pathRenderer_->inheritShaderCacheFrom(*pathRenderer_);
    }
    return batch;
}

int SkiaDrawingEngine::renderPreparedStrokeTileImage(StrokeTilePreparation& batch, SkCanvas* canvas, sk_sp<SkImage>& image) {
    image.reset();
    if (!canvas) return -1;
    if (batch.next >= batch.tiles.size()) return 0;
    batch.ready = batch.tiles[batch.next++];
    auto& drawing = *batch.drawing;
    std::vector<size_t> candidates;
    candidates.reserve(drawing.strokes_.size());
    for (size_t i = 0; i < drawing.strokes_.size(); ++i) if (!drawing.strokes_[i].isEraser) candidates.push_back(i);
    std::unordered_map<size_t, sk_sp<SkPicture>> pictures;
    StrokeTileKey key{batch.bucket, batch.ready.x, batch.ready.y, 1};
    image = drawing.renderStrokeTile(canvas, key, batch.ready.width, batch.ready.height,
                                     batch.bucket / 100.f, candidates, pictures);
    return image ? 1 : -1;
}

int SkiaDrawingEngine::renderPreparedStrokeTile(StrokeTilePreparation& batch, SkCanvas* canvas, GrDirectContext* context) {
    batch.pixels.reset();
    sk_sp<SkImage> image;
    const int result = renderPreparedStrokeTileImage(batch, canvas, image);
    if (result != 1) return result;
    batch.pixels = image->makeRasterImage(context);
    return batch.pixels ? 1 : -1;
}

bool SkiaDrawingEngine::installPreparedStrokeTile(StrokeTilePreparation& batch) {
    std::lock_guard<std::recursive_mutex> lock(stateMutex_);
    if (!batch.pixels || batch.owner != strokeTileIdentity_ || batch.revision != strokeTileContentRevision_ || batch.epoch != strokeTileEpoch_ ||
        batch.context != strokeTileContext_) return false;
    if (!pathRenderer_->mergeShaderCacheFrom(*batch.drawing->pathRenderer_)) return false;
    StrokeTileKey key{batch.bucket, batch.ready.x, batch.ready.y, batch.epoch};
    auto existing = strokeTileCache_.find(key);
    if (existing != strokeTileCache_.end()) {
        if (existing->second.image && existing->second.appendedStrokes.empty()) {
            batch.pixels.reset();
            return true;
        }
        strokeTileCacheBytes_ -= std::min(strokeTileCacheBytes_, existing->second.bytes);
        strokeTileCache_.erase(existing);
    }
    StrokeTileEntry entry;
    entry.image = std::move(batch.pixels);
    entry.bytes = static_cast<size_t>(batch.ready.width) * batch.ready.height * 4;
    entry.lastUsed = ++strokeTileUseCounter_;
    strokeTileCacheBytes_ += entry.bytes;
    strokeTileCache_.emplace(key, std::move(entry));
    pruneStrokeTileCache();
    return true;
}

bool SkiaDrawingEngine::hasPreparedStrokeTiles(const StrokeTilePreparation& batch) {
    std::lock_guard<std::recursive_mutex> lock(stateMutex_);
    if (batch.owner != strokeTileIdentity_ || batch.revision != strokeTileContentRevision_ || batch.epoch != strokeTileEpoch_ ||
        batch.context != strokeTileContext_) return false;
    for (const auto& tile : batch.expected) {
        const auto it = strokeTileCache_.find(StrokeTileKey{batch.bucket, tile.x, tile.y, batch.epoch});
        if (it == strokeTileCache_.end() || !it->second.image || !it->second.appendedStrokes.empty()) return false;
    }
    // Keep the completed set recent while the UI switches its target.
    for (const auto& tile : batch.expected) {
        auto it = strokeTileCache_.find(StrokeTileKey{batch.bucket, tile.x, tile.y, batch.epoch});
        it->second.lastUsed = ++strokeTileUseCounter_;
    }
    return true;
}
}
