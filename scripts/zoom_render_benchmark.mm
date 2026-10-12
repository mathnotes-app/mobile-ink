#import <Metal/Metal.h>
#include "SkiaDrawingEngine.h"
#include "include/core/SkSurface.h"
#include "include/gpu/ganesh/GrDirectContext.h"
#include "include/gpu/ganesh/SkSurfaceGanesh.h"
#include "include/gpu/ganesh/mtl/GrMtlBackendContext.h"
#include "include/gpu/ganesh/mtl/GrMtlDirectContext.h"
#include <chrono>
#include <cmath>
#include <iostream>
#include <stdexcept>
#include <string>

using nativedrawing::SkiaDrawingEngine;
using Clock = std::chrono::steady_clock;

namespace {
constexpr int kWidth = 1640;
constexpr int kHeight = 2122;

double milliseconds(Clock::time_point start, Clock::time_point end) {
    return std::chrono::duration<double, std::milli>(end - start).count();
}

sk_sp<GrDirectContext> makeContext() {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) throw std::runtime_error("Metal device unavailable");
    id<MTLCommandQueue> queue = [device newCommandQueue];
    GrMtlBackendContext backend{};
    backend.fDevice.retain((__bridge void*)device);
    backend.fQueue.retain((__bridge void*)queue);
    auto context = GrDirectContexts::MakeMetal(backend);
    if (!context) throw std::runtime_error("Metal context unavailable");
    return context;
}

void seed(SkiaDrawingEngine& engine, int count) {
    engine.setToolWithParams("pen", 3, 0x000000, "pixel");
    const int rows = (count + 19) / 20;
    for (int i = 0; i < count; ++i) {
        const float x = 40 + (i % 20) * 78;
        const float y = 40 + (i / 20) * (2000.f / rows);
        engine.touchBegan(x, y, 1);
        for (int j = 1; j < 32; ++j) {
            engine.touchMoved(x + j * 2, y + std::sin(j * .5f) * 6, 1);
        }
        engine.touchEnded();
    }
}

struct Frame {
    const char* name;
    float scale;
    float left;
    float top;
};

// Repeat within a context to separate the initial render, new scale tiles,
// cache hits, and newly revealed tiles. These are engine timings, not UI FPS.
constexpr Frame kFrames[] = {
    {"initial", 1, 0, 0},
    {"zoom_2_new", 2, 350, 400},
    {"zoom_2_cached", 2, 350, 400},
    {"zoom_2_pan_new", 2, 1000, 1500},
    {"zoom_2_pan_cached", 2, 1000, 1500},
    {"zoom_2_5_new", 2.5f, 350, 400},
    {"zoom_2_5_cached", 2.5f, 350, 400},
    {"return_1", 1, 0, 0},
};

void run(int count, int trial, bool metal, bool cropped) {
    auto context = metal ? makeContext() : nullptr;
    SkiaDrawingEngine engine(kWidth, kHeight);
    seed(engine, count);
    sk_sp<SkSurface> surface;
    float surfaceScale = 0;
    for (const auto& frame : kFrames) {
        double allocationMs = 0;
        if (surfaceScale != frame.scale) {
            const auto start = Clock::now();
            const auto info = SkImageInfo::MakeN32Premul(
                cropped ? 820 : kWidth * frame.scale,
                cropped ? 1061 : kHeight * frame.scale);
            surface = metal
                ? SkSurfaces::RenderTarget(context.get(), skgpu::Budgeted::kYes, info)
                : SkSurfaces::Raster(info);
            if (!surface) throw std::runtime_error("Surface allocation failed");
            allocationMs = milliseconds(start, Clock::now());
            surfaceScale = frame.scale;
        }
        const auto start = Clock::now();
        engine.setRenderViewport(frame.scale, frame.left, frame.top,
                                 820 / frame.scale, 1061 / frame.scale);
        if (cropped) engine.renderVisibleViewport(surface->getCanvas());
        else engine.render(surface->getCanvas());
        const auto submitted = Clock::now();
        if (context) {
            context->flush(surface.get());
            if (!context->submit(GrSyncCpu::kYes)) {
                throw std::runtime_error("GPU submission failed");
            }
        }
        const auto done = Clock::now();
        std::cout << "{\"backend\":\"" << (metal ? "metal" : "raster")
                  << "\",\"trial\":" << trial << ",\"strokes\":" << count
                  << ",\"frame\":\"" << frame.name << "\",\"scale\":" << frame.scale
                  << ",\"cropped\":" << (cropped ? "true" : "false")
                  << ",\"target_bytes\":" << surface->width() * surface->height() * 4LL
                  << ",\"allocation_ms\":" << allocationMs
                  << ",\"cpu_record_ms\":" << milliseconds(start, submitted)
                  << ",\"completed_render_ms\":" << milliseconds(start, done)
                  << "}\n";
    }
}
}

int main(int argc, char** argv) {
    try {
        if ((argc != 2 && argc != 3) || (std::string(argv[1]) != "metal" && std::string(argv[1]) != "raster")) {
            throw std::runtime_error("Usage: zoom_render_benchmark metal|raster [crop]");
        }
        const bool metal = std::string(argv[1]) == "metal";
        const bool cropped = argc == 3 && std::string(argv[2]) == "crop";
        if (argc == 3 && !cropped) throw std::runtime_error("Unknown target mode");
        for (int count : {100, 600, 2000}) {
            for (int trial = 0; trial < 5; ++trial) run(count, trial, metal, cropped);
        }
        return 0;
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
