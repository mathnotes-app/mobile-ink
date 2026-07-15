#pragma once

#include "DrawingTypes.h"
#include <vector>

namespace nativedrawing {

class PathRenderer;

void commitStrokeDelta(
    std::vector<StrokeDelta>& undoStack,
    std::vector<StrokeDelta>& redoStack,
    StrokeDelta&& delta,
    size_t maxHistoryEntries
);

void applyStrokeDelta(
    const StrokeDelta& delta,
    std::vector<Stroke>& strokes,
    std::vector<EraserCircle>& eraserCircles,
    PathRenderer& pathRenderer
);

void revertStrokeDelta(
    const StrokeDelta& delta,
    std::vector<Stroke>& strokes,
    std::vector<EraserCircle>& eraserCircles,
    PathRenderer& pathRenderer
);

} // namespace nativedrawing
