#include "SkiaDrawingEngine.h"

#include "EraserRenderer.h"
#include "ShapeRecognition.h"
#include "StrokeSplitter.h"

#include <algorithm>
#include <cmath>
#include <utility>

namespace nativedrawing {

void SkiaDrawingEngine::eraseObjects() {
    std::lock_guard<std::recursive_mutex> lock(stateMutex_);

    // Helper lambda to remove strokes and update eraser references
    auto removeStrokes = [this](const std::unordered_set<size_t>& indicesToRemove) {
        // Capture (idx, stroke) pairs for the removed entries BEFORE
        // mutating strokes_. The delta needs them so undo can re-insert
        // at the original indices. Sorted ascending.
        std::vector<size_t> sortedIndices(indicesToRemove.begin(), indicesToRemove.end());
        std::sort(sortedIndices.begin(), sortedIndices.end());
        StrokeDelta delta;
        delta.kind = StrokeDelta::Kind::RemoveStrokes;
        delta.removedStrokes.reserve(sortedIndices.size());
        for (size_t idx : sortedIndices) {
            if (idx < strokes_.size()) {
                delta.removedStrokes.emplace_back(idx, strokes_[idx]);
            }
        }

        std::unordered_map<size_t, size_t> oldToNew;
        size_t newIdx = 0;
        std::vector<Stroke> remaining;
        remaining.reserve(strokes_.size() - indicesToRemove.size());

        for (size_t i = 0; i < strokes_.size(); ++i) {
            if (indicesToRemove.count(i) == 0) {
                oldToNew[i] = newIdx++;
                remaining.push_back(strokes_[i]);
            }
        }
        for (auto& s : remaining) {
            if (s.isEraser) {
                std::unordered_set<size_t> updated;
                for (size_t old : s.affectedStrokeIndices)
                    if (oldToNew.count(old)) updated.insert(oldToNew[old]);
                s.affectedStrokeIndices = updated;
            }
        }
        if (remaining.size() != strokes_.size()) {
            strokes_ = remaining;
            commitDelta(std::move(delta));
            markStrokeCachesDirty();
        }
    };

    if (!pendingDeleteIndices_.empty()) {
        removeStrokes(pendingDeleteIndices_);
        pendingDeleteIndices_.clear();
        currentPoints_.clear();
        currentPath_.reset();
        return;
    }

    if (currentPoints_.empty()) return;

    // Build eraser bounds from current points
    SkRect eraserBounds = SkRect::MakeXYWH(currentPoints_[0].x, currentPoints_[0].y, 0, 0);
    for (const auto& pt : currentPoints_) {
        eraserBounds.join(SkRect::MakeXYWH(pt.x, pt.y, 0, 0));
    }
    eraserBounds.outset(currentPaint_.getStrokeWidth() / 2.0f, currentPaint_.getStrokeWidth() / 2.0f);

    std::unordered_set<size_t> toRemove;
    for (size_t i = 0; i < strokes_.size(); ++i) {
        if (strokes_[i].path.getBounds().intersects(eraserBounds)) toRemove.insert(i);
    }
    removeStrokes(toRemove);
    currentPoints_.clear();
    currentPath_.reset();
}

std::vector<Stroke> SkiaDrawingEngine::splitStrokeAtPoint(
    const Stroke& originalStroke,
    const Point& eraserPoint,
    float eraserRadius
) {
    return strokeSplitter_->splitStrokeAtPoint(originalStroke, eraserPoint, eraserRadius);
}

void SkiaDrawingEngine::bakeEraserCircles() {
    if (eraserCircles_.size() <= bakedCircleCount_) return;  // Nothing new to bake

    // Apply kClear directly to strokeSurface_ using smooth stroke paths
    SkCanvas* canvas = strokeSurface_->getCanvas();

    eraserRenderer_->drawEraserCirclesAsStrokes(
        canvas, eraserCircles_, bakedCircleCount_, eraserCircles_.size());

    // Update cached snapshot
    cachedStrokeSnapshot_ = strokeSurface_->makeImageSnapshot();

    // Mark all circles as baked (but DON'T clear them - needed for redraw/undo)
    bakedCircleCount_ = eraserCircles_.size();

    printf("[C++] bakeEraserCircles: Baked %zu circles total\n", bakedCircleCount_);
}

bool SkiaDrawingEngine::applyPixelEraserAt(float eraserX, float eraserY, float radius) {
    // Build list of circles to add (may include interpolated circles for full coverage)
    std::vector<EraserCircle> circlesToAdd;
    circlesToAdd.push_back({eraserX, eraserY, radius});

    // Add intermediate circles along path from last position for full coverage
    if (hasLastEraserPoint_) {
        float dx = eraserX - lastEraserX_;
        float dy = eraserY - lastEraserY_;
        float dist = std::sqrt(dx * dx + dy * dy);
        float avgRadius = (radius + lastEraserRadius_) / 2.0f;

        // Add circles at intervals of radius/2 for overlapping coverage
        if (dist > avgRadius * 0.5f) {
            int steps = static_cast<int>(dist / (avgRadius * 0.5f));
            for (int s = 1; s < steps; s++) {
                float t = static_cast<float>(s) / steps;
                float ix = lastEraserX_ + dx * t;
                float iy = lastEraserY_ + dy * t;
                float ir = lastEraserRadius_ + (radius - lastEraserRadius_) * t;
                circlesToAdd.push_back({ix, iy, ir});
            }
        }
    }

    pendingPixelEraserCircles_.insert(
        pendingPixelEraserCircles_.end(),
        circlesToAdd.begin(),
        circlesToAdd.end()
    );

    // Apply kClear directly to strokeSurface_ for instant feedback. Stroke
    // metadata is updated once at touch end so the drag loop stays cheap.
    if (strokeSurface_) {
        SkCanvas* canvas = strokeSurface_->getCanvas();
        SkPaint clearPaint;
        clearPaint.setBlendMode(SkBlendMode::kClear);
        clearPaint.setAntiAlias(true);

        if (hasLastEraserPoint_) {
            SkPath eraserPath;
            eraserPath.moveTo(lastEraserX_, lastEraserY_);
            eraserPath.lineTo(eraserX, eraserY);

            clearPaint.setStyle(SkPaint::kStroke_Style);
            clearPaint.setStrokeWidth(radius * 2.0f);
            clearPaint.setStrokeCap(SkPaint::kRound_Cap);
            clearPaint.setStrokeJoin(SkPaint::kRound_Join);
            canvas->drawPath(eraserPath, clearPaint);
        } else {
            canvas->drawCircle(eraserX, eraserY, radius, clearPaint);
        }

        // Keep the live surface hot during the drag. Snapshotting here forces
        // full-surface work per input sample; touchEnded refreshes caches.
    }

    // Track position for next call
    lastEraserX_ = eraserX;
    lastEraserY_ = eraserY;
    lastEraserRadius_ = radius;
    hasLastEraserPoint_ = true;

    return true;
}

bool SkiaDrawingEngine::applyPendingPixelEraseToStrokes() {
    if (pendingPixelEraserCircles_.empty()) {
        return false;
    }

    SkRect eraseBounds = SkRect::MakeEmpty();
    for (const auto& circle : pendingPixelEraserCircles_) {
        eraseBounds.join(SkRect::MakeLTRB(
            circle.x - circle.radius,
            circle.y - circle.radius,
            circle.x + circle.radius,
            circle.y + circle.radius
        ));
    }

    bool anyModified = false;

    for (size_t strokeIndex = 0; strokeIndex < strokes_.size(); ++strokeIndex) {
        auto& stroke = strokes_[strokeIndex];
        if (stroke.isEraser || stroke.points.size() < 2) {
            continue;
        }

        SkRect bounds = stroke.path.getBounds();
        const float strokeOutset = std::max(8.0f, averageCalculatedWidth(stroke.points));
        bounds.outset(strokeOutset, strokeOutset);
        if (!bounds.intersects(eraseBounds)) {
            continue;
        }

        std::vector<EraserCircle> circlesForStroke;
        circlesForStroke.reserve(pendingPixelEraserCircles_.size());
        for (const auto& circle : pendingPixelEraserCircles_) {
            SkRect circleBounds = SkRect::MakeLTRB(
                circle.x - circle.radius,
                circle.y - circle.radius,
                circle.x + circle.radius,
                circle.y + circle.radius
            );
            if (bounds.intersects(circleBounds)) {
                circlesForStroke.push_back(circle);
            }
        }
        if (circlesForStroke.empty()) {
            continue;
        }

        stroke.erasedBy.insert(
            stroke.erasedBy.end(),
            circlesForStroke.begin(),
            circlesForStroke.end()
        );

        StrokeDelta::PixelEraseEntry entry;
        entry.strokeIndex = strokeIndex;
        entry.addedCircles = std::move(circlesForStroke);
        pendingPixelEraseEntries_.push_back(std::move(entry));

        anyModified = true;
    }

    return anyModified;
}

} // namespace nativedrawing
