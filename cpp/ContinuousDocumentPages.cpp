#include "ContinuousDocumentPages.h"
#include <algorithm>
#include <cmath>
#include <limits>
#include <stdexcept>
#include <unordered_map>
#include <unordered_set>
#include <include/core/SkMatrix.h>

namespace nativedrawing {
namespace {
void validateHeight(float height) {
    if (!std::isfinite(height) || height <= 0) throw std::invalid_argument("Invalid document page height");
}
void translate(Stroke& stroke, float offset) {
    if (!std::isfinite(offset)) throw std::invalid_argument("Invalid page offset");
    for (auto& point : stroke.points) {
        if (!std::isfinite(point.x) || !std::isfinite(point.y + offset))
            throw std::invalid_argument("Invalid stroke coordinate");
        point.y += offset;
    }
    for (auto& circle : stroke.erasedBy) {
        if (!std::isfinite(circle.x) || !std::isfinite(circle.y + offset) ||
            !std::isfinite(circle.radius) || circle.radius < 0)
            throw std::invalid_argument("Invalid eraser coordinate");
        circle.y += offset;
    }
    // Keep decoded geometry in the same coordinate space as its points.
    // Export uses these bounds before serializing page-local render payloads.
    stroke.path.transform(SkMatrix::Translate(0, offset));
    stroke.cachedEraserPath.reset();
    stroke.cachedEraserCount = 0;
    stroke.cachedHasVisiblePoints = true;
}
}

std::vector<ContinuousDocumentPage> partitionContinuousDocument(
    const std::vector<Stroke>& strokes, int pageCount, float pageHeight) {
    validateHeight(pageHeight);
    if (pageCount <= 0) throw std::invalid_argument("Invalid document page count");
    std::vector<ContinuousDocumentPage> pages(static_cast<size_t>(pageCount));
    for (size_t index = 0; index < strokes.size(); ++index) {
        const auto& stroke = strokes[index];
        if (stroke.points.empty()) throw std::invalid_argument("Cannot partition a stroke without points");
        const float y = stroke.points.front().y;
        if (!std::isfinite(y)) throw std::invalid_argument("Invalid stroke position");
        const double owner = std::clamp(std::floor(static_cast<double>(y) / pageHeight), 0.0, double(pageCount - 1));
        auto& page = pages[static_cast<size_t>(owner)];
        page.strokes.push_back(stroke);
        translate(page.strokes.back(), -static_cast<float>(owner) * pageHeight);
        page.order.push_back(index);
    }
    return pages;
}

std::vector<Stroke> composeContinuousDocument(
    const std::vector<ContinuousDocumentPage>& pages, float pageHeight) {
    validateHeight(pageHeight);
    struct Entry { Stroke stroke; uint64_t order; };
    std::vector<Entry> entries;
    std::unordered_set<uint64_t> usedOrders;
    uint64_t nextOrder = 0;
    for (const auto& page : pages) {
        if (!page.order.empty() && page.order.size() != page.strokes.size())
            throw std::invalid_argument("Stroke order does not match page data");
        for (uint64_t order : page.order) {
            if (order == std::numeric_limits<uint64_t>::max() || !usedOrders.insert(order).second)
                throw std::invalid_argument("Invalid or duplicate document stroke order");
            nextOrder = std::max(nextOrder, order + 1);
        }
    }
    for (size_t pageIndex = 0; pageIndex < pages.size(); ++pageIndex) {
        const auto& page = pages[pageIndex];
        const bool legacy = page.order.empty();
        if (legacy && page.strokes.size() > std::numeric_limits<uint64_t>::max() - nextOrder)
            throw std::overflow_error("Document stroke order overflow");
        const uint64_t legacyStart = nextOrder;
        if (legacy) nextOrder += page.strokes.size();
        for (size_t index = 0; index < page.strokes.size(); ++index) {
            Entry entry{page.strokes[index], legacy ? legacyStart + index : page.order[index]};
            translate(entry.stroke, static_cast<float>(pageIndex) * pageHeight);
            if (legacy) {
                std::unordered_set<size_t> targets;
                for (size_t target : entry.stroke.affectedStrokeIndices) {
                    if (target < page.strokes.size()) targets.insert(static_cast<size_t>(legacyStart + target));
                }
                entry.stroke.affectedStrokeIndices = std::move(targets);
            }
            entries.push_back(std::move(entry));
        }
    }
    std::sort(entries.begin(), entries.end(), [](const Entry& a, const Entry& b) { return a.order < b.order; });
    std::unordered_map<uint64_t, size_t> indices;
    for (size_t index = 0; index < entries.size(); ++index) indices.emplace(entries[index].order, index);
    std::vector<Stroke> strokes;
    strokes.reserve(entries.size());
    for (auto& entry : entries) {
        std::unordered_set<size_t> targets;
        for (size_t target : entry.stroke.affectedStrokeIndices) {
            const auto mapped = indices.find(target);
            if (mapped != indices.end()) targets.insert(mapped->second);
        }
        entry.stroke.affectedStrokeIndices = std::move(targets);
        strokes.push_back(std::move(entry.stroke));
    }
    return strokes;
}
std::vector<std::vector<Stroke>> projectContinuousDocumentPages(
    const std::vector<ContinuousDocumentPage>& pages, float pageHeight,
    const std::vector<int>& pageIndices) {
    for (int index : pageIndices) {
        if (index < 0 || static_cast<size_t>(index) >= pages.size())
            throw std::invalid_argument("Invalid export page index");
    }
    const auto document = composeContinuousDocument(pages, pageHeight);
    std::vector<std::vector<Stroke>> result;
    result.reserve(pageIndices.size());
    for (int pageIndex : pageIndices) {
        const float top = pageIndex * pageHeight;
        std::vector<Stroke> projected;
        std::unordered_map<size_t, size_t> indices;
        for (size_t index = 0; index < document.size(); ++index) {
            const auto& stroke = document[index];
            SkRect bounds = stroke.path.getBounds();
            float margin = std::max(8.0f, stroke.paint.getStrokeWidth() * 2);
            for (const auto& point : stroke.points) margin = std::max(margin, point.calculatedWidth * 2);
            if (bounds.bottom() + margin < top || bounds.top() - margin > top + pageHeight) continue;
            indices.emplace(index, projected.size());
            projected.push_back(stroke);
            translate(projected.back(), -top);
        }
        for (auto& stroke : projected) {
            std::unordered_set<size_t> targets;
            for (size_t target : stroke.affectedStrokeIndices) {
                const auto found = indices.find(target);
                if (found != indices.end()) targets.insert(found->second);
            }
            stroke.affectedStrokeIndices = std::move(targets);
        }
        result.push_back(std::move(projected));
    }
    return result;
}

}
