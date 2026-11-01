#include "EraserMaskOptimization.h"
#include "SkiaDrawingEngine.h"
#include <SkPathOps.h>
#include <algorithm>
#include <cmath>
#include <cstring>
#include <list>
#include <mutex>

namespace nativedrawing {
namespace {
constexpr size_t kMinimumEraserCircles = 128;
constexpr size_t kMaximumEraserCirclesPerStroke = 20000;
constexpr size_t kMaximumSnapshotCircles = 2 * 1024 * 1024;
constexpr int kMaximumMaskVerbs = 25000;
constexpr size_t kMaximumReusableMaskBytes = 32 * 1024 * 1024;
struct CachedMask {
    uint64_t hash;
    std::vector<EraserCircle> circles;
    SkPath path;
    size_t bytes;
    bool optimized;
};
std::mutex reusableMasksMutex;
std::list<CachedMask> reusableMasks;
size_t reusableMaskBytes = 0;

uint64_t maskHash(const std::vector<EraserCircle>& circles) {
    uint64_t hash = 1469598103934665603ULL;
    for (const auto& circle : circles) for (float value : {circle.x, circle.y, circle.radius}) {
        uint32_t bits; std::memcpy(&bits, &value, sizeof(bits));
        hash = (hash ^ bits) * 1099511628211ULL;
    }
    return hash;
}

bool sameCircles(const std::vector<EraserCircle>& a, const std::vector<EraserCircle>& b) {
    if (a.size() != b.size()) return false;
    for (size_t i = 0; i < a.size(); ++i)
        if (a[i].x != b[i].x || a[i].y != b[i].y || a[i].radius != b[i].radius) return false;
    return true;
}

int findReusableMask(uint64_t hash, const std::vector<EraserCircle>& circles, SkPath& result) {
    std::lock_guard<std::mutex> lock(reusableMasksMutex);
    for (auto it = reusableMasks.begin(); it != reusableMasks.end(); ++it) {
        if (it->hash == hash && sameCircles(it->circles, circles)) {
            result = it->path;
            const int status = it->optimized ? 1 : 2;
            reusableMasks.splice(reusableMasks.begin(), reusableMasks, it);
            return status;
        }
    }
    return 0;
}

void rememberReusableMask(uint64_t hash, const std::vector<EraserCircle>& circles, const SkPath& path, bool optimized) {
    const size_t bytes = circles.size() * sizeof(EraserCircle) + path.approximateBytesUsed();
    if (bytes > kMaximumReusableMaskBytes) return;
    std::lock_guard<std::mutex> lock(reusableMasksMutex);
    while (reusableMaskBytes + bytes > kMaximumReusableMaskBytes && !reusableMasks.empty()) {
        reusableMaskBytes -= reusableMasks.back().bytes;
        reusableMasks.pop_back();
    }
    reusableMasks.push_front(CachedMask{hash, circles, path, bytes, optimized});
    reusableMaskBytes += bytes;
}
}

void clearEraserMaskOptimizationCache() {
    std::lock_guard<std::mutex> lock(reusableMasksMutex);
    reusableMasks.clear();
    reusableMaskBytes = 0;
}

std::unique_ptr<EraserMaskOptimizationBatch> SkiaDrawingEngine::snapshotEraserMasks() {
    std::lock_guard<std::recursive_mutex> lock(stateMutex_);
    auto batch = std::make_unique<EraserMaskOptimizationBatch>();
    std::vector<size_t> indices;
    for (size_t i = 0; i < strokes_.size(); ++i) {
        const auto& stroke = strokes_[i];
        if (stroke.erasedBy.size() < kMinimumEraserCircles || stroke.erasedBy.size() > kMaximumEraserCirclesPerStroke ||
            (stroke.cachedEraserOptimized && stroke.cachedEraserCount == stroke.erasedBy.size())) continue;
        indices.push_back(i);
    }
    std::sort(indices.begin(), indices.end(), [this](size_t a, size_t b) {
        return strokes_[a].erasedBy.size() > strokes_[b].erasedBy.size();
    });
    size_t circleCount = 0;
    for (size_t i : indices) {
        const auto& stroke = strokes_[i];
        if (stroke.erasedBy.size() > kMaximumSnapshotCircles - circleCount) continue;
        EraserMaskCandidate candidate;
        candidate.index = i;
        candidate.strokePathID = stroke.path.getGenerationID();
        candidate.mask.erasedBy = stroke.erasedBy;
        if (stroke.cachedEraserCount == stroke.erasedBy.size()) {
            candidate.mask.cachedEraserPath = stroke.cachedEraserPath;
            candidate.mask.cachedEraserCount = stroke.cachedEraserCount;
        }
        circleCount += stroke.erasedBy.size();
        batch->candidates.push_back(std::move(candidate));
    }
    return batch->candidates.empty() ? nullptr : std::move(batch);
}

int optimizeNextEraserMask(EraserMaskOptimizationBatch& batch) {
    if (batch.next >= batch.candidates.size()) return 0;
    const size_t index = batch.next++;
    auto& mask = batch.candidates[index].mask;
    if (std::any_of(mask.erasedBy.begin(), mask.erasedBy.end(), [](const auto& circle) {
        return !std::isfinite(circle.x) || !std::isfinite(circle.y) || !std::isfinite(circle.radius) || circle.radius <= 0;
    })) return 2;
    const uint64_t hash = maskHash(mask.erasedBy);
    SkPath reused;
    const int cached = findReusableMask(hash, mask.erasedBy, reused);
    if (cached == 2) { ++batch.cacheHits; return 2; }
    if (cached == 1) {
        mask.cachedEraserPath = std::move(reused);
        mask.cachedEraserCount = mask.erasedBy.size();
        mask.cachedEraserOptimized = true;
        batch.ready = index;
        ++batch.cacheHits;
        return 1;
    }
    mask.ensureEraserCacheValid();
    const int before = mask.cachedEraserPath.countVerbs();
    if (before <= 0 || before > kMaximumMaskVerbs || !mask.cachedEraserPath.isFinite()) return 2;
    SkPath simplified, difference;
    if (!Simplify(mask.cachedEraserPath, &simplified) || !simplified.isFinite() || simplified.isInverseFillType() ||
        simplified.countVerbs() >= before ||
        !Op(mask.cachedEraserPath, simplified, kXOR_SkPathOp, &difference) ||
        !difference.isEmpty() || difference.isInverseFillType()) {
        rememberReusableMask(hash, mask.erasedBy, SkPath(), false);
        return 2;
    }
    mask.cachedEraserPath = std::move(simplified);
    mask.cachedEraserOptimized = true;
    rememberReusableMask(hash, mask.erasedBy, mask.cachedEraserPath, true);
    batch.ready = index;
    return 1;
}

bool SkiaDrawingEngine::installOptimizedEraserMask(const EraserMaskOptimizationBatch& batch) {
    std::lock_guard<std::recursive_mutex> lock(stateMutex_);
    if (batch.ready >= batch.candidates.size()) return false;
    const auto& candidate = batch.candidates[batch.ready];
    if (candidate.index >= strokes_.size() || !candidate.mask.cachedEraserOptimized) return false;
    auto& stroke = strokes_[candidate.index];
    if (stroke.path.getGenerationID() != candidate.strokePathID || !sameCircles(stroke.erasedBy, candidate.mask.erasedBy)) return false;
    stroke.cachedEraserPath = candidate.mask.cachedEraserPath;
    stroke.cachedEraserCount = stroke.erasedBy.size();
    stroke.cachedEraserOptimized = true;
    return true;
}
} // namespace nativedrawing
