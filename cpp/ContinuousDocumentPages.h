#pragma once
#include "DrawingTypes.h"
#include <cstdint>
#include <vector>

namespace nativedrawing {
// New document pages retain whole strokes in owner-page coordinates. The order
// array identifies original document indices (including legacy eraser targets).
// An empty order array on a nonempty page denotes the legacy page-local format.
struct ContinuousDocumentPage {
    std::vector<Stroke> strokes;
    std::vector<uint64_t> order;
};
std::vector<ContinuousDocumentPage> partitionContinuousDocument(
    const std::vector<Stroke>& strokes, int pageCount, float pageHeight);
std::vector<Stroke> composeContinuousDocument(
    const std::vector<ContinuousDocumentPage>& pages, float pageHeight);
// Render-only page payloads include neighboring overflow. Never persist these:
// crossing strokes deliberately occur in every page whose clip they intersect.
std::vector<std::vector<Stroke>> projectContinuousDocumentPages(
    const std::vector<ContinuousDocumentPage>& pages, float pageHeight,
    const std::vector<int>& pageIndices);
}
