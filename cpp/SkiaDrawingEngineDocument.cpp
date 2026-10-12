#include "SkiaDrawingEngine.h"
#include "ActiveStrokeRenderer.h"
#include "BatchExporter.h"
#include <cmath>
#include <algorithm>

namespace nativedrawing {

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
