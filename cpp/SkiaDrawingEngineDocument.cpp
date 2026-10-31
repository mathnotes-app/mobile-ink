#include "SkiaDrawingEngine.h"
#include "ActiveStrokeRenderer.h"
#include "BatchExporter.h"
#include <cmath>
#include <algorithm>
#include <include/core/SkMatrix.h>

namespace nativedrawing {

uint64_t SkiaDrawingEngine::reserveLayerOrder() {
    std::lock_guard<std::recursive_mutex> lock(stateMutex_);
    if (layerSequence_ >= 9007199254740990ULL) return 0;
    return ++layerSequence_;
}

void SkiaDrawingEngine::includeLayerOrder(uint64_t order) {
    std::lock_guard<std::recursive_mutex> lock(stateMutex_);
    layerSequence_ = std::max(layerSequence_, order);
}

void SkiaDrawingEngine::setImageLayers(std::vector<ImageLayer> images) {
    std::lock_guard<std::recursive_mutex> lock(stateMutex_);
    for (const auto& image : images) includeLayerOrder(image.layerOrder);
    std::stable_sort(images.begin(), images.end(), [](const auto& a, const auto& b) {
        return a.layerOrder < b.layerOrder;
    });
    auto bounds = [](const ImageLayer& layer) {
        SkMatrix rotation;
        rotation.setRotate(layer.rotation, layer.bounds.centerX(), layer.bounds.centerY());
        SkRect result = rotation.mapRect(layer.bounds);
        result.outset(2, 2);
        return result;
    };
    auto changed = [](const ImageLayer& a, const ImageLayer& b) {
        return a.layerOrder != b.layerOrder || a.hidden != b.hidden || a.image.get() != b.image.get() ||
            a.bounds != b.bounds || a.crop != b.crop || a.rotation != b.rotation || a.cornerRadius != b.cornerRadius;
    };
    std::unordered_map<std::string, size_t> oldIndices, newIndices;
    for (size_t index = 0; index < imageLayers_.size(); ++index) oldIndices.emplace(imageLayers_[index].id, index);
    for (size_t index = 0; index < images.size(); ++index) newIndices.emplace(images[index].id, index);
    for (size_t index = 0; index < imageLayers_.size(); ++index) {
        const auto& old = imageLayers_[index];
        const auto next = newIndices.find(old.id);
        if (next == newIndices.end() || changed(old, images[next->second]) || next->second != index) {
            if (!old.hidden) invalidateStrokeTilesForRect(bounds(old));
            if (next != newIndices.end() && !images[next->second].hidden) invalidateStrokeTilesForRect(bounds(images[next->second]));
        }
    }
    for (const auto& image : images) {
        if (!oldIndices.count(image.id) && !image.hidden) invalidateStrokeTilesForRect(bounds(image));
    }
    needsStrokeRedraw_ = true;
    imageLayers_ = std::move(images);
}

bool SkiaDrawingEngine::hasImageLayers() const {
    std::lock_guard<std::recursive_mutex> lock(stateMutex_);
    return !imageLayers_.empty();
}

std::vector<ImageLayer> SkiaDrawingEngine::snapshotImageLayers() {
    std::lock_guard<std::recursive_mutex> lock(stateMutex_);
    auto snapshot = imageLayers_;
    const SkRect visible = SkRect::MakeXYWH(visibleLeft_, visibleTop_, visibleWidth_, visibleHeight_);
    for (auto& image : snapshot) {
        SkMatrix transform;
        transform.setRotate(image.rotation, image.bounds.centerX(), image.bounds.centerY());
        image.animationVisible = !image.hidden && SkRect::Intersects(visible, transform.mapRect(image.bounds));
    }
    return snapshot;
}

bool SkiaDrawingEngine::resizeDocument(int width, int height) {
    std::lock_guard<std::recursive_mutex> lock(stateMutex_);
    if (!viewportOnly_ || width <= 0 || height <= 0) return false;
    if (width == width_ && height == height_) return true;

    // Geometry and history stay in document coordinates. Page insertion/removal
    // owns any required translation; changing the extent must not erase edits.
    width_ = width;
    height_ = height;
    activeStrokeRenderer_ = std::make_unique<ActiveStrokeRenderer>(width, height, pathRenderer_.get(), true);
    batchExporter_ = std::make_unique<BatchExporter>(width, height);
    setRenderViewport(renderScale_, visibleLeft_, visibleTop_, visibleWidth_, visibleHeight_);
    markStrokeCachesDirty();
    return true;
}

bool SkiaDrawingEngine::clearDocumentPage(int pageIndex, float pageHeight) {
    std::lock_guard<std::recursive_mutex> lock(stateMutex_);
    if (!viewportOnly_ || pageIndex < 0 || !std::isfinite(pageHeight) || pageHeight <= 0 ||
        static_cast<double>(pageIndex) * pageHeight >= height_) return false;

    cancelSelectionTransform();
    resetIndexedSelectionState();
    const double lastPage = std::ceil(static_cast<double>(height_) / pageHeight) - 1;
    for (size_t index = 0; index < strokes_.size(); ++index) {
        const auto& points = strokes_[index].points;
        if (points.empty()) continue;
        // Match persisted ownership. A crossing stroke remains one object and
        // one undo operation; clearing its owner removes the whole stroke.
        const double owner = std::clamp(std::floor(static_cast<double>(points.front().y) / pageHeight), 0.0, lastPage);
        if (owner == pageIndex) selectedIndices_.insert(index);
    }
    deleteSelection();
    return true;
}

} // namespace nativedrawing
