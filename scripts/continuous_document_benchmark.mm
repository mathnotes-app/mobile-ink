#include "SkiaDrawingEngine.h"
#include <mach/mach.h>
#include <chrono>
#include <iostream>
#include <stdexcept>

uint64_t footprint() {
    task_vm_info_data_t info{};
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS)
        throw std::runtime_error("Cannot read process physical footprint");
    return info.phys_footprint;
}
int main() {
    constexpr int width = 2064, pageHeight = 2670, pages = 100;
    const auto baseline = footprint();
    nativedrawing::SkiaDrawingEngine document(width, pageHeight * pages, true);
    const auto constructed = footprint();
    document.setToolWithParams("pen", 4, 0x000000, "pixel");
    for (int page = 0; page < pages; ++page) {
        for (int stroke = 0; stroke < 200; ++stroke) {
            const float x = 30 + (stroke % 10) * 200;
            const float y = page * pageHeight + 30 + (stroke / 10) * 130;
            document.touchBegan(x, y, 1);
            for (int point = 1; point < 32; ++point)
                document.touchMoved(x + point * 4, y + (point % 2) * 5, 1);
            document.touchEnded();
        }
    }
    const auto loaded = footprint();
    document.setRenderViewport(1, 0, pageHeight * 50, width, pageHeight);
    const auto info = SkImageInfo::MakeN32Premul(width, pageHeight);
    auto target = SkSurfaces::Raster(info);
    if (!target) throw std::runtime_error("Cannot allocate viewport");
    const auto start = std::chrono::steady_clock::now();
    document.renderVisibleViewport(target->getCanvas());
    const double firstMs = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
    const auto rendered = footprint();
    const auto cachedStart = std::chrono::steady_clock::now();
    document.renderVisibleViewport(target->getCanvas());
    const double cachedMs = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - cachedStart).count();
    document.touchBegan(100, pageHeight * 50 + 300, 1);
    for (int point = 1; point < 50; ++point)
        document.touchMoved(100 + point, pageHeight * 50 + 300 + point, 1);
    document.renderVisibleViewport(target->getCanvas());
    const auto drawing = footprint();
    document.touchEnded();
    std::cout << "{\"pages\":100,\"strokes\":20000,\"pointsPerStroke\":32,\"baselineBytes\":" << baseline
        << ",\"constructedBytes\":" << constructed << ",\"loadedBytes\":" << loaded
        << ",\"renderedBytes\":" << rendered << ",\"drawingBytes\":" << drawing
        << ",\"firstRenderMs\":" << firstMs << ",\"cachedRenderMs\":" << cachedMs << "}\n";
}
