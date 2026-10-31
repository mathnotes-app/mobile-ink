#pragma once

#include "DrawingTypes.h"
#include <cstddef>
#include <cstdint>
#include <vector>

namespace nativedrawing {
// An independent snapshot. It owns only derived mask inputs, never the note.
struct EraserMaskCandidate {
    size_t index = 0;
    uint32_t strokePathID = 0;
    Stroke mask;
};

struct EraserMaskOptimizationBatch {
    std::vector<EraserMaskCandidate> candidates;
    size_t next = 0;
    size_t ready = 0;
    size_t cacheHits = 0;
};

// Runs on a worker: 0 = finished, 1 = optimized, 2 = skipped.
int optimizeNextEraserMask(EraserMaskOptimizationBatch& batch);
void clearEraserMaskOptimizationCache();
} // namespace nativedrawing
