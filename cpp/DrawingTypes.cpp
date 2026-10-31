#include "DrawingTypes.h"

#include <cmath>

#include <include/core/SkPathUtils.h>

namespace nativedrawing {

bool Stroke::hasVisiblePoints() const {
    if (erasedBy.empty()) {
        return true;
    }

    for (const auto& pt : points) {
        bool pointVisible = true;
        for (const auto& circle : erasedBy) {
            float dx = pt.x - circle.x;
            float dy = pt.y - circle.y;
            float totalRadius = circle.radius + pt.calculatedWidth / 2.0f;
            if (dx * dx + dy * dy <= totalRadius * totalRadius) {
                pointVisible = false;
                break;
            }
        }
        if (pointVisible) {
            return true;
        }
    }
    return false;
}

void Stroke::ensureEraserCacheValid() const {
    if (erasedBy.size() == cachedEraserCount) {
        return;
    }

    // Always rebuild from scratch to match live eraser rendering exactly.
    cachedEraserPath.reset();
    cachedEraserCount = 0;
    cachedEraserOptimized = false;

    if (erasedBy.empty()) {
        return;
    }

    // Match EraserRenderer::drawEraserCirclesAsStrokes: group circles into
    // strokes, create a path through centers, then stroke it with round caps.
    constexpr float STROKE_BREAK_FACTOR = 2.0f;
    size_t strokeStart = 0;

    for (size_t i = 0; i <= erasedBy.size(); ++i) {
        bool isLast = (i == erasedBy.size());
        bool breakStroke = isLast;
        bool bridgeRadiusChange = false;

        if (!isLast && i > strokeStart) {
            float dx = erasedBy[i].x - erasedBy[i - 1].x;
            float dy = erasedBy[i].y - erasedBy[i - 1].y;
            float dist = std::sqrt(dx * dx + dy * dy);
            float avgRadius = (erasedBy[i].radius + erasedBy[i - 1].radius) / 2.0f;
            if (dist > avgRadius * STROKE_BREAK_FACTOR) {
                breakStroke = true;
            } else if (std::fabs(erasedBy[i].radius - erasedBy[strokeStart].radius) > 0.0001f) {
                // A stroked path has a single width. Starting a new run
                // preserves both radii; bridge their ends as the live eraser does.
                breakStroke = true;
                bridgeRadiusChange = dist > 0.0001f;
            }
        }

        if (breakStroke && i > strokeStart) {
            size_t segmentLen = i - strokeStart;

            if (segmentLen == 1) {
                cachedEraserPath.addCircle(
                    erasedBy[strokeStart].x,
                    erasedBy[strokeStart].y,
                    erasedBy[strokeStart].radius
                );
            } else {
                SkPath strokePath;
                strokePath.moveTo(erasedBy[strokeStart].x, erasedBy[strokeStart].y);
                for (size_t j = strokeStart + 1; j < i; ++j) {
                    strokePath.lineTo(erasedBy[j].x, erasedBy[j].y);
                }

                SkPaint strokePaint;
                strokePaint.setStyle(SkPaint::kStroke_Style);
                strokePaint.setStrokeWidth(erasedBy[strokeStart].radius * 2.0f);
                strokePaint.setStrokeCap(SkPaint::kRound_Cap);
                strokePaint.setStrokeJoin(SkPaint::kRound_Join);

                SkPath filledPath;
                if (skpathutils::FillPathWithPaint(strokePath, strokePaint, &filledPath)) {
                    cachedEraserPath.addPath(filledPath);
                } else {
                    for (size_t j = strokeStart; j < i; ++j) {
                        cachedEraserPath.addCircle(
                            erasedBy[j].x,
                            erasedBy[j].y,
                            erasedBy[j].radius
                        );
                    }
                }
            }

            if (bridgeRadiusChange) {
                const auto& previous = erasedBy[i - 1];
                const auto& next = erasedBy[i];
                const float dx = next.x - previous.x;
                const float dy = next.y - previous.y;
                const float length = std::sqrt(dx * dx + dy * dy);
                const float nx = -dy / length;
                const float ny = dx / length;
                SkPath bridge;
                bridge.moveTo(previous.x + nx * previous.radius, previous.y + ny * previous.radius);
                bridge.lineTo(previous.x - nx * previous.radius, previous.y - ny * previous.radius);
                bridge.lineTo(next.x - nx * next.radius, next.y - ny * next.radius);
                bridge.lineTo(next.x + nx * next.radius, next.y + ny * next.radius);
                bridge.close();
                cachedEraserPath.addPath(bridge);
            }
            strokeStart = i;
        }
    }

    cachedEraserCount = erasedBy.size();
}

} // namespace nativedrawing
