#include "ContinuousDocumentPages.h"
#include "DrawingSerialization.h"
#include "EraserMaskOptimization.h"
#include "PathRenderer.h"
#import <Metal/Metal.h>
#include "../cpp/SkiaDrawingEngine.h"
#include "include/core/SkBBHFactory.h"
#include "include/core/SkBitmap.h"
#include "include/core/SkPictureRecorder.h"
#include "include/codec/SkCodec.h"
#include "include/gpu/ganesh/GrDirectContext.h"
#include "include/gpu/ganesh/SkSurfaceGanesh.h"
#include "include/gpu/ganesh/mtl/GrMtlBackendContext.h"
#include "include/gpu/ganesh/mtl/GrMtlDirectContext.h"
#include <iostream>
#include <limits>
#include <stdexcept>

using nativedrawing::SkiaDrawingEngine;

namespace {
constexpr int kSize = 1024;

sk_sp<GrDirectContext> makeContext() {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    id<MTLCommandQueue> queue = [device newCommandQueue];
    GrMtlBackendContext backend{};
    backend.fDevice.retain((__bridge void*)device);
    backend.fQueue.retain((__bridge void*)queue);
    auto context = GrDirectContexts::MakeMetal(backend);
    if (!context) throw std::runtime_error("Metal context unavailable");
    return context;
}

SkBitmap render(SkiaDrawingEngine& engine, GrDirectContext* context, bool exportPage = false, int size = kSize) {
    auto info = SkImageInfo::MakeN32Premul(size, size);
    auto surface = context
        ? SkSurfaces::RenderTarget(context, skgpu::Budgeted::kYes, info)
        : SkSurfaces::Raster(info);
    if (!surface) throw std::runtime_error("Surface allocation failed");
    if (exportPage) engine.renderForExport(surface->getCanvas());
    else engine.render(surface->getCanvas());
    SkBitmap pixels;
    pixels.allocPixels(info);
    // readPixels waits for GPU completion, so assertions inspect actual output.
    if (!surface->readPixels(pixels, 0, 0)) throw std::runtime_error("Pixel readback failed");
    return pixels;
}

SkBitmap renderCrop(SkiaDrawingEngine& engine, GrDirectContext* context, int width, int height) {
    const auto info = SkImageInfo::MakeN32Premul(width, height);
    auto surface = context
        ? SkSurfaces::RenderTarget(context, skgpu::Budgeted::kYes, info)
        : SkSurfaces::Raster(info);
    if (!surface) throw std::runtime_error("Crop surface allocation failed");
    const auto originalMatrix = surface->getCanvas()->getLocalToDevice();
    engine.renderVisibleViewport(surface->getCanvas());
    if (surface->getCanvas()->getLocalToDevice() != originalMatrix)
        throw std::runtime_error("Crop leaked its canvas transform");
    SkBitmap pixels;
    pixels.allocPixels(info);
    if (!surface->readPixels(pixels, 0, 0)) throw std::runtime_error("Crop readback failed");
    return pixels;
}

void expectInk(const SkBitmap& pixels, int x, int y, bool ink, const char* label) {
    const auto color = pixels.getColor(x, y);
    const bool actual = SkColorGetA(color) > 100 && SkColorGetR(color) < 100 && SkColorGetG(color) < 100;
    if (actual != ink) throw std::runtime_error(label);
}

void drawLine(SkiaDrawingEngine& engine) {
    engine.setToolWithParams("pen", 10, 0x000000, "pixel");
    engine.touchBegan(40, 100, 1);
    for (int x = 45; x <= 450; x += 5) engine.touchMoved(x, 100, 1);
    engine.touchEnded();
}
}

int main() {
    try {
        auto first = makeContext();
        auto second = makeContext();
        // A fast erase arrives as widely spaced input points. Its live and
        // committed edges must remain straight, including between samples.
        for (auto* context : {static_cast<GrDirectContext*>(nullptr), first.get()}) {
            SkiaDrawingEngine document(512, 512, true);
            document.setBackgroundType("pdf");
            document.setRenderViewport(1, 0, 0, 512, 512);
            document.setToolWithParams("pen", 80, 0xff000000, "pixel");
            document.touchBegan(40, 200, 1);
            for (int x = 45; x <= 450; x += 5) document.touchMoved(x, 200, 1);
            document.touchEnded();
            document.setToolWithParams("eraser", 20, 0xff000000, "pixel");
            document.touchBegan(100, 200, 1);
            document.touchMoved(300, 200, 1);
            auto live = renderCrop(document, context, 512, 512);
            for (int x = 110; x < 290; ++x) {
                expectInk(live, x, 208, false, "Live fast erase left scalloped edges");
                expectInk(live, x, 212, true, "Live fast erase removed ink outside its edge");
            }
            document.touchEnded();
            auto saved = document.snapshotDrawing();
            if (saved.empty() || saved[0].erasedBy.size() < 3)
                throw std::runtime_error("Fast erase did not preserve its samples");
            for (size_t i = 1; i < saved[0].erasedBy.size(); ++i)
                if (saved[0].erasedBy[i].x < saved[0].erasedBy[i - 1].x)
                    throw std::runtime_error("Fast erase samples were recorded out of order");
            auto committed = renderCrop(document, context, 512, 512);
            for (int x = 110; x < 290; ++x) {
                expectInk(committed, x, 208, false, "Committed fast erase left scalloped edges");
                expectInk(committed, x, 212, true, "Committed fast erase removed ink outside its edge");
            }
        }
        // A new eraser mark can extend the persisted mask back into a cached
        // neighboring tile. Both tiles must match a freshly loaded document.
        for (auto* context : {static_cast<GrDirectContext*>(nullptr), first.get()}) {
            SkiaDrawingEngine document(1024, 1024, true);
            document.setBackgroundType("pdf");
            document.setRenderViewport(1, 0, 0, 1024, 1024);
            document.setToolWithParams("pen", 6, 0xff000000, "pixel");
            document.touchBegan(350, 597, 1);
            for (int x = 355; x <= 750; x += 5) document.touchMoved(x, 597, 1);
            document.touchEnded();
            document.setToolWithParams("eraser", 200, 0xff000000, "pixel");
            document.touchBegan(450, 500, 1);
            document.touchEnded();
            expectInk(renderCrop(document, context, 1024, 1024), 500, 597, true,
                      "First erase unexpectedly reached the neighboring ink");
            document.touchBegan(650, 500, 1);
            document.touchEnded();
            auto cached = renderCrop(document, context, 1024, 1024);
            auto strokes = document.snapshotDrawing();
            SkiaDrawingEngine reloaded(1024, 1024, true);
            reloaded.setBackgroundType("pdf");
            reloaded.setRenderViewport(1, 0, 0, 1024, 1024);
            reloaded.replaceDrawing(strokes);
            auto fresh = renderCrop(reloaded, context, 1024, 1024);
            expectInk(fresh, 500, 597, false, "Joined eraser did not extend to the neighboring tile");
            if (cached.getColor(500, 597) != fresh.getColor(500, 597))
                throw std::runtime_error("Joined eraser left a stale neighboring tile");
        }
        // Erasing textured ink must reveal the image underneath without
        // clearing that image or changing the ink's place in the stack.
        for (auto* context : {static_cast<GrDirectContext*>(nullptr), first.get()}) {
            SkiaDrawingEngine document(512, 512, true);
            document.setBackgroundType("pdf");
            document.setRenderViewport(1, 0, 0, 512, 512);
            auto imageSurface = SkSurfaces::Raster(SkImageInfo::MakeN32Premul(8, 8));
            imageSurface->getCanvas()->clear(SK_ColorRED);
            nativedrawing::ImageLayer image;
            image.id = "under-crayon";
            image.layerOrder = document.reserveLayerOrder();
            image.image = imageSurface->makeImageSnapshot();
            image.bounds = SkRect::MakeXYWH(0, 0, 512, 512);
            document.setImageLayers({image});
            document.setToolWithParams("crayon", 40, 0xff000000, "pixel");
            document.touchBegan(50, 200, .7);
            for (int x = 55; x <= 450; x += 5) document.touchMoved(x, 200, .7);
            document.touchEnded();
            document.setToolWithParams("eraser", 30, 0xff000000, "pixel");
            document.touchBegan(250, 170, 1);
            document.touchMoved(250, 230, 1);
            document.touchEnded();
            auto pixels = renderCrop(document, context, 512, 512);
            if (pixels.getColor(250, 200) != SK_ColorRED)
                throw std::runtime_error("Erasing crayon changed its underlying image");
            if (pixels.getColor(100, 200) == SK_ColorRED)
                throw std::runtime_error("Erasing crayon removed unrelated ink");
            document.undo();
            if (renderCrop(document, context, 512, 512).getColor(250, 200) == SK_ColorRED)
                throw std::runtime_error("Undo failed to restore erased crayon");
            document.redo();
            if (renderCrop(document, context, 512, 512).getColor(250, 200) != SK_ColorRED)
                throw std::runtime_error("Redo failed to restore the crayon cutout");
        }
        // Selected and stationary runs can be interleaved with image layers.
        // A cached drag must preserve that order, including after image edits.
        for (auto* context : {static_cast<GrDirectContext*>(nullptr), first.get()}) {
            SkiaDrawingEngine document(512, 512, true);
            document.setBackgroundType("pdf");
            document.setRenderViewport(1, 0, 0, 512, 512);
            auto line = [&](int y, uint32_t color) {
                document.setToolWithParams("pen", 20, color, "pixel");
                document.touchBegan(30, y, 1);
                for (int x = 35; x <= 480; x += 5) document.touchMoved(x, y, 1);
                document.touchEnded();
            };
            line(100, 0xff000000);
            auto imageSurface = SkSurfaces::Raster(SkImageInfo::MakeN32Premul(8, 8));
            imageSurface->getCanvas()->clear(SK_ColorRED);
            nativedrawing::ImageLayer image;
            image.id = "between-ink"; image.layerOrder = document.reserveLayerOrder();
            image.image = imageSurface->makeImageSnapshot();
            image.bounds = SkRect::MakeXYWH(80, 120, 350, 40);
            document.setImageLayers({image});
            line(200, 0xff0000ff);
            line(260, 0xff000000);
            const auto stationaryColor = renderCrop(document, context, 512, 512).getColor(250, 200);
            if (!document.selectStrokeAt(250, 100) || !document.selectStrokeAt(250, 260))
                throw std::runtime_error("Could not select interleaved ink for drag");
            document.beginSelectionDrag();
            document.moveSelection(0, 40);
            auto pixels = renderCrop(document, context, 512, 512);
            if (pixels.getColor(250, 140) != SK_ColorRED)
                throw std::runtime_error("Moving older ink placed it above the image");
            expectInk(pixels, 250, 300, true, "Moving newer ink lost it above the image");
            if (pixels.getColor(250, 200) != stationaryColor)
                throw std::runtime_error("Moving selection changed stationary ink");
            imageSurface->getCanvas()->clear(SK_ColorYELLOW);
            image.image = imageSurface->makeImageSnapshot();
            document.setImageLayers({image});
            pixels = renderCrop(document, context, 512, 512);
            if (pixels.getColor(250, 140) != SK_ColorYELLOW)
                throw std::runtime_error("Selection drag retained a stale image layer");
            document.finalizeMove();
            document.clearSelection();
            pixels = renderCrop(document, context, 512, 512);
            if (pixels.getColor(250, 140) != SK_ColorYELLOW)
                throw std::runtime_error("Finalizing selection changed image order");
            expectInk(pixels, 250, 300, true, "Finalizing selection lost moved ink");
        }
        // The cached selected run includes ink beyond the current viewport,
        // since dragging can bring that ink into view.
        for (auto* context : {static_cast<GrDirectContext*>(nullptr), first.get()}) {
            SkiaDrawingEngine document(1024, 1024, true);
            document.setBackgroundType("pdf");
            document.setRenderViewport(1, 0, 0, 512, 512);
            document.setToolWithParams("pen", 12, 0xff000000, "pixel");
            document.touchBegan(100, 220, 1);
            for (int x = 105; x <= 900; x += 5) document.touchMoved(x, 220, 1);
            document.touchEnded();
            if (!document.selectStrokeAt(200, 220)) throw std::runtime_error("Cannot select offscreen-crossing ink");
            document.beginSelectionDrag();
            document.moveSelection(-400, 0);
            expectInk(renderCrop(document, context, 512, 512), 450, 220, true,
                "Selection drag did not bring offscreen ink into view");
            document.endSelectionDrag();
        }
        // Very large selections must fall back to bounded direct rendering,
        // rather than allocating a document-sized snapshot.
        for (auto* context : {static_cast<GrDirectContext*>(nullptr), first.get()}) {
            SkiaDrawingEngine document(10000, 512, true);
            document.setBackgroundType("pdf");
            document.setRenderViewport(1, 0, 0, 512, 512);
            document.setToolWithParams("pen", 12, 0xff000000, "pixel");
            document.touchBegan(100, 220, 1);
            for (int x = 110; x <= 9000; x += 10) document.touchMoved(x, 220, 1);
            document.touchEnded();
            if (!document.selectStrokeAt(200, 220)) throw std::runtime_error("Cannot select large ink");
            document.beginSelectionDrag();
            document.moveSelection(0, 30);
            expectInk(renderCrop(document, context, 512, 512), 200, 250, true,
                "Large selection fallback lost moved ink");
            document.endSelectionDrag();
        }
        // Multiply-blended highlighter must blend against moving ink exactly
        // as it does after the move is committed.
        for (auto* context : {static_cast<GrDirectContext*>(nullptr), first.get()}) {
          for (bool withImage : {false, true}) {
            SkiaDrawingEngine document(512, 512, true);
            document.setBackgroundType("pdf");
            document.setRenderViewport(1, 0, 0, 512, 512);
            if (withImage) {
                auto imageSurface = SkSurfaces::Raster(SkImageInfo::MakeN32Premul(8, 8));
                imageSurface->getCanvas()->clear(SkColorSetARGB(255, 210, 180, 140));
                nativedrawing::ImageLayer image;
                image.id = "highlighter-background";
                image.layerOrder = document.reserveLayerOrder();
                image.image = imageSurface->makeImageSnapshot();
                image.bounds = SkRect::MakeXYWH(0, 0, 512, 512);
                document.setImageLayers({image});
            }
            document.setToolWithParams("pen", 20, 0xff2244cc, "pixel");
            document.touchBegan(40, 180, 1);
            for (int x = 45; x <= 460; x += 5) document.touchMoved(x, 180 + (x - 40) / 20.0f, 1);
            document.touchEnded();
            document.setToolWithParams("highlighter", 30, 0xffffff00, "pixel");
            document.touchBegan(40, 205, 1);
            for (int x = 45; x <= 460; x += 5) document.touchMoved(x, 205, 1);
            document.touchEnded();
            if (!document.selectStrokeAt(100, 183)) throw std::runtime_error("Cannot select ink under highlighter");
            document.beginSelectionDrag();
            document.moveSelection(0, 20);
            auto dragging = renderCrop(document, context, 512, 512);
            document.finalizeMove();
            document.clearSelection();
            auto committed = renderCrop(document, context, 512, 512);
            for (int x : {130, 160, 190}) {
                const int y = 200 + (x - 40) / 20;
                const auto a = dragging.getColor(x, y), b = committed.getColor(x, y);
                const int delta = std::max({std::abs(int(SkColorGetA(a)) - int(SkColorGetA(b))),
                    std::abs(int(SkColorGetR(a)) - int(SkColorGetR(b))),
                    std::abs(int(SkColorGetG(a)) - int(SkColorGetG(b))),
                    std::abs(int(SkColorGetB(a)) - int(SkColorGetB(b)))});
                if (delta > 8) throw std::runtime_error("Selection drag changed highlighter blending");
            }
          }
        }
        {
            nativedrawing::clearEraserMaskOptimizationCache();
            nativedrawing::EraserMaskOptimizationBatch invalid;
            invalid.candidates.emplace_back();
            invalid.candidates.back().mask.erasedBy.push_back({0, 0, std::numeric_limits<float>::quiet_NaN()});
            if (nativedrawing::optimizeNextEraserMask(invalid) != 2 ||
                nativedrawing::optimizeNextEraserMask(invalid) != 0)
                throw std::runtime_error("Invalid eraser masks were not skipped safely");
            SkiaDrawingEngine document(512, 512, true);
            drawLine(document);
            auto original = document.snapshotDrawing();
            for (int i = 0; i < 300; ++i)
                original[0].erasedBy.push_back({200.f + 25.f * std::sin(i * .12f), 100.f + 12.f * std::cos(i * .12f), 8.f});
            document.replaceDrawing(original);
            auto before = document.serializeDrawing();
            auto batch = document.snapshotEraserMasks();
            if (!batch || nativedrawing::optimizeNextEraserMask(*batch) != 1)
                throw std::runtime_error("Could not simplify a redundant eraser path");
            if (!document.installOptimizedEraserMask(*batch) || before != document.serializeDrawing())
                throw std::runtime_error("Optimizing an eraser path changed saved ink");
            if (document.snapshotEraserMasks()) throw std::runtime_error("Optimized path was scheduled repeatedly");
            if (!document.deserializeDrawing(before)) throw std::runtime_error("Could not reopen optimized test drawing");
            auto reopened = document.snapshotEraserMasks();
            if (!reopened || nativedrawing::optimizeNextEraserMask(*reopened) != 1 || reopened->cacheHits != 1 ||
                !document.installOptimizedEraserMask(*reopened) || document.serializeDrawing() != before)
                throw std::runtime_error("Reopening did not safely reuse the derived eraser mask");
            nativedrawing::clearEraserMaskOptimizationCache();

            // A result computed before another erasure must never overwrite
            // the newer mask, even when it arrives late from the worker.
            auto staleSource = document.snapshotDrawing();
            staleSource[0].cachedEraserOptimized = false;
            staleSource[0].cachedEraserCount = 0;
            document.replaceDrawing(staleSource);
            auto stale = document.snapshotEraserMasks();
            if (!stale || nativedrawing::optimizeNextEraserMask(*stale) != 1)
                throw std::runtime_error("Could not prepare stale mask test");
            auto changedSameCount = document.snapshotDrawing();
            changedSameCount[0].erasedBy[0].x += 1;
            changedSameCount[0].cachedEraserCount = 0;
            document.replaceDrawing(changedSameCount);
            auto sameCountBytes = document.serializeDrawing();
            if (document.installOptimizedEraserMask(*stale) || sameCountBytes != document.serializeDrawing())
                throw std::runtime_error("A stale mask with the same circle count replaced a newer erasure");
            document.setToolWithParams("eraser", 20, 0xff000000, "pixel");
            document.touchBegan(200, 100, 1); document.touchMoved(210, 100, 1); document.touchEnded();
            auto changed = document.serializeDrawing();
            if (document.installOptimizedEraserMask(*stale) || changed != document.serializeDrawing())
                throw std::runtime_error("A stale optimization replaced a newer erasure");
        }
        for (auto* context : {static_cast<GrDirectContext*>(nullptr), first.get()}) {
            SkiaDrawingEngine document(512, 512, true);
            document.setBackgroundType("pdf");
            drawLine(document); // Older ink, underneath the image.
            const auto imageOrder = document.reserveLayerOrder();
            auto photo = SkSurfaces::Raster(SkImageInfo::MakeN32Premul(32, 32));
            photo->getCanvas()->clear(SkColorSetARGB(128, 255, 0, 0));
            nativedrawing::ImageLayer layer;
            layer.id = "photo"; layer.layerOrder = imageOrder;
            layer.image = photo->makeImageSnapshot();
            layer.bounds = SkRect::MakeXYWH(80, 80, 140, 80);
            document.setImageLayers({layer});
            document.setToolWithParams("pen", 10, 0x000000, "pixel");
            document.touchBegan(40, 120, 1);
            for (int x = 45; x <= 450; x += 5) document.touchMoved(x, 120, 1);
            document.touchEnded();
            auto pixels = renderCrop(document, context, 512, 512);
            auto older = pixels.getColor(100, 100);
            if (SkColorGetA(older) < 240 || SkColorGetR(older) < 90 || SkColorGetR(older) > 180)
                throw std::runtime_error("Translucent image did not cover older ink");
            expectInk(pixels, 100, 120, true, "New ink was not above the image");
            document.undo();
            if (SkColorGetA(renderCrop(document, context, 512, 512).getColor(100, 120)) > 180)
                throw std::runtime_error("Undo did not remove ink over the image");
            document.redo();
            expectInk(renderCrop(document, context, 512, 512), 100, 120, true, "Redo lost ink over the image");
            auto saved = document.snapshotDrawing();
            const auto groups = nativedrawing::splitStrokesByLayer(saved, {imageOrder});
            if (groups.size() != 2 || groups[0].size() != 1 || groups[1].size() != 1)
                throw std::runtime_error("Ink was not split around the image layer");
            auto withEraser = saved;
            auto eraser = saved.back(); eraser.isEraser = true; eraser.affectedStrokeIndices = {0, 1};
            withEraser.push_back(eraser);
            const auto erasedGroups = nativedrawing::splitStrokesByLayer(withEraser, {imageOrder});
            if (erasedGroups[0].size() != 2 || erasedGroups[1].size() != 2 ||
                erasedGroups[0].back().affectedStrokeIndices != std::unordered_set<size_t>{0} ||
                erasedGroups[1].back().affectedStrokeIndices != std::unordered_set<size_t>{0})
                throw std::runtime_error("Layer split lost legacy eraser references");
            SkiaDrawingEngine reloaded(512, 512, true);
            reloaded.setBackgroundType("pdf"); reloaded.replaceDrawing(saved); reloaded.setImageLayers({layer});
            auto restored = renderCrop(reloaded, context, 512, 512);
            expectInk(restored, 100, 120, true, "Reload lost ink above the image");
            if (SkColorGetR(restored.getColor(100, 100)) < 90)
                throw std::runtime_error("Reload lost image above older ink");
        }
        // Compositing ink over inserted images depends on a truly transparent
        // native PNG, including after encoding and decoding the export.
        // Appending crayon onto an already-composited tile must preserve the
        // same ink, erasures, transparency, and image order as a fresh render.
        for (auto* context : {static_cast<GrDirectContext*>(nullptr), first.get()}) {
            SkiaDrawingEngine cached(1024, 1024, true), fresh(1024, 1024, true);
            cached.setBackgroundType("pdf"); fresh.setBackgroundType("pdf");
            cached.setRenderViewport(1, 0, 0, 1024, 1024);
            cached.setToolWithParams("pen", 18, 0xff1155bb, "pixel");
            cached.touchBegan(30, 300, .7);
            for (int x = 35; x < 950; x += 5) cached.touchMoved(x, 300 + 20 * std::sin(x * .02), .7);
            cached.touchEnded();
            auto seeded = cached.snapshotDrawing();
            for (int i = 0; i < 1300; ++i) seeded[0].erasedBy.push_back({float(100 + i % 600), 300, 8});
            cached.replaceDrawing(seeded);
            auto imageSurface = SkSurfaces::Raster(SkImageInfo::MakeN32Premul(8, 8));
            imageSurface->getCanvas()->clear(SkColorSetARGB(150, 220, 40, 80));
            nativedrawing::ImageLayer image;
            image.id = "image"; image.layerOrder = cached.reserveLayerOrder();
            image.image = imageSurface->makeImageSnapshot(); image.bounds = SkRect::MakeXYWH(300, 260, 300, 100);
            cached.setImageLayers({image});
            (void)renderCrop(cached, context, 1024, 1024);
            cached.setToolWithParams("crayon", 20, 0xff224466, "pixel");
            for (int y : {300, 305, 310, 315, 320, 325, 330, 335}) {
                cached.touchBegan(100, y, .7);
                for (int x = 105; x < 900; x += 5) cached.touchMoved(x, y + 12 * std::sin(x * .03), .7);
                cached.touchEnded();
                (void)renderCrop(cached, context, 1024, 1024);
            }
            auto actual = renderCrop(cached, context, 1024, 1024);
            auto saved = cached.snapshotDrawing(); fresh.replaceDrawing(saved); fresh.setImageLayers({image});
            fresh.setRenderViewport(1, 0, 0, 1024, 1024);
            auto expected = renderCrop(fresh, context, 1024, 1024);
            size_t differenceCount = 0;
            for (int y = 0; y < 1024; ++y) for (int x = 0; x < 1024; ++x) {
                const auto a = actual.getColor(x, y), b = expected.getColor(x, y);
                if (a != b) {
                    ++differenceCount;
                    const int delta = std::max({std::abs(int(SkColorGetA(a)) - int(SkColorGetA(b))),
                        std::abs(int(SkColorGetR(a)) - int(SkColorGetR(b))),
                        std::abs(int(SkColorGetG(a)) - int(SkColorGetG(b))),
                        std::abs(int(SkColorGetB(a)) - int(SkColorGetB(b)))});
                    if (!context || delta > 96) throw std::runtime_error("Incremental crayon tile changed visible ink");
                }
            }
            // GPU resolve can shift a small number of antialiased edge pixels;
            // the CPU result must remain exact and broad differences must fail.
            if (differenceCount > 1024) throw std::runtime_error("Incremental crayon changed too many pixels");
            cached.undo(); cached.redo();
            actual = renderCrop(cached, context, 1024, 1024);
            for (int y = 0; y < 1024; ++y) for (int x = 0; x < 1024; ++x) {
                if (actual.getColor(x, y) != expected.getColor(x, y))
                    throw std::runtime_error("Crayon tile undo/redo differs from a fresh render");
            }
            // Old cache epochs must not stall the next stroke after undo.
            cached.undo();
            cached.setToolWithParams("crayon", 12, 0xff000000, "pixel");
            cached.touchBegan(80, 400, 1); cached.touchMoved(300, 400, 1); cached.touchEnded();
            (void)renderCrop(cached, context, 1024, 1024);
        }
        {
            SkiaDrawingEngine pending(256, 256, true), fresh(256, 256, true);
            pending.setBackgroundType("pdf"); fresh.setBackgroundType("pdf");
            pending.setRenderViewport(1, 0, 0, 256, 256);
            pending.setToolWithParams("pen", 5, 0xff000000, "pixel");
            pending.touchBegan(20, 180, 1); pending.touchMoved(100, 180, 1); pending.touchEnded();
            (void)renderCrop(pending, nullptr, 256, 256);
            pending.setToolWithParams("crayon", 8, 0xff000000, "pixel");
            for (int i = 0; i < 130; ++i) {
                pending.touchBegan(20, 20 + i, 1); pending.touchMoved(100, 20 + i, 1); pending.touchEnded();
            }
            auto actual = renderCrop(pending, nullptr, 256, 256);
            auto saved = pending.snapshotDrawing(); fresh.replaceDrawing(saved);
            fresh.setRenderViewport(1, 0, 0, 256, 256);
            auto expected = renderCrop(fresh, nullptr, 256, 256);
            for (int y = 0; y < 256; ++y) for (int x = 0; x < 256; ++x)
                if (actual.getColor(x, y) != expected.getColor(x, y))
                    throw std::runtime_error("A capped pending tile lost strokes");
        }
        {
            SkiaDrawingEngine source(512, 512);
            drawLine(source);
            auto pages = source.batchExportPages({source.serializeDrawing()}, {"pdf"}, {}, {0}, 1);
            if (pages.size() != 1) throw std::runtime_error("Transparent export missing");
            NSString* encoded = [NSString stringWithUTF8String:pages[0].c_str() + 22];
            NSData* data = [[NSData alloc] initWithBase64EncodedString:encoded options:0];
            auto codec = SkCodec::MakeFromData(SkData::MakeWithCopy(data.bytes, data.length));
            if (!codec) throw std::runtime_error("Transparent export PNG invalid");
            SkBitmap pixels;
            pixels.allocPixels(SkImageInfo::MakeN32Premul(512, 512));
            if (codec->getPixels(pixels.info(), pixels.getPixels(), pixels.rowBytes()) != SkCodec::kSuccess)
                throw std::runtime_error("Transparent export PNG decode failed");
            if (SkColorGetA(pixels.getColor(10, 10)) != 0)
                throw std::runtime_error("Ink export background is not transparent");
            expectInk(pixels, 100, 100, true, "Ink export did not retain the stroke");
        }
        // A predicted Pencil path is temporary. It must never become part of
        // the cached live stroke after a new actual sample replaces it.
        for (auto* context : {static_cast<GrDirectContext*>(nullptr), first.get()}) {
            SkiaDrawingEngine pen(512, 512, true);
            pen.setBackgroundType("pdf");
            pen.setRenderViewport(1, 0, 0, 512, 512);
            pen.setToolWithParams("pen", 12, 0xff000000, "pixel");
            pen.touchBegan(40, 100, 1, 0, 1.57, 0, true);
            pen.touchMoved(60, 100, 1, 0, 1.57, 1, true);
            for (int i = 1; i <= 8; ++i)
                pen.addPredictedPoint(60 + 10 * i, 100 + 12 * i, 1, 0, 1.57, i + 1, true);
            (void)renderCrop(pen, context, 512, 512);
            pen.clearPredictedPoints();
            for (int x = 70; x <= 180; x += 10)
                pen.touchMoved(x, 100, 1, 0, 1.57, x, true);
            auto corrected = renderCrop(pen, context, 512, 512);
            for (int y = 135; y < 220; ++y) for (int x = 60; x < 180; ++x) {
                if (SkColorGetA(corrected.getColor(x, y)) > 0)
                    throw std::runtime_error("Replaced Pencil predictions left ink in the live stroke");
            }
            pen.touchEnded();
        }
        // Repeated preview updates must not create spikes far outside the
        // same live geometry rendered all at once.
        {
            SkiaDrawingEngine incremental(512, 512, true), single(512, 512, true);
            for (auto* engine : {&incremental, &single}) {
                engine->setBackgroundType("pdf");
                engine->setRenderViewport(1, 0, 0, 512, 512);
                engine->setToolWithParams("pen", 16, 0xff000000, "pixel");
                engine->touchBegan(40, 150, 1, 0, 1.57, 0, true);
            }
            for (int i = 1; i <= 80; ++i) {
                const float x = 40 + i * 5;
                const float y = 150 + 25 * std::sin(i * .35);
                incremental.touchMoved(x, y, 1, 0, 1.57, i, true);
                single.touchMoved(x, y, 1, 0, 1.57, i, true);
                (void)renderCrop(incremental, nullptr, 512, 512);
            }
            auto actual = renderCrop(incremental, nullptr, 512, 512);
            auto expected = renderCrop(single, nullptr, 512, 512);
            int extra = 0;
            for (int y = 100; y < 200; ++y) for (int x = 25; x < 460; ++x)
                if (SkColorGetA(actual.getColor(x, y)) > 180 && SkColorGetA(expected.getColor(x, y)) < 30) ++extra;
            if (extra > 150) throw std::runtime_error("Incremental pen preview added spikes outside the stroke");
        }
        // First use must allocate the live-stroke cache; a following stroke
        // must clear its old snapshot without removing committed ink.
        SkiaDrawingEngine live(512, 512);
        live.setToolWithParams("pen", 10, 0x000000, "pixel");
        for (int y : {100, 180}) {
            live.touchBegan(40, y, 1);
            for (int x = 45; x <= 250; x += 5) live.touchMoved(x, y, 1);
            expectInk(render(live, nullptr), 100, y, true, "First live stroke or reused cache missing");
            live.setRenderViewport(2, 0, 0, 256, 256);
            expectInk(render(live, first.get()), 200, y * 2, true, "Live stroke lost on viewport change");
            live.touchEnded();
            live.setRenderViewport(1, 0, 0, 512, 512);
            expectInk(render(live, nullptr), 100, 100, true, "Starting a stroke erased committed ink");
        }
        // Continuous live ink stays intact across incremental GPU updates,
        // context changes, and CPU capture while a stroke is still in flight.
        SkiaDrawingEngine continuousLive(512, 4096, true);
        continuousLive.setToolWithParams("pen", 12, 0x000000, "pixel");
        continuousLive.setRenderViewport(2, 0, 0, 256, 256);
        continuousLive.touchBegan(24, 80, 1);
        int tip = 24;
        for (auto* context : {first.get(), first.get(), second.get(),
                              static_cast<GrDirectContext*>(nullptr), first.get(), first.get()}) {
            const int previousTip = tip;
            for (int point = 0; point < 8; ++point) {
                tip += 4;
                continuousLive.touchMoved(tip, 80, 1);
            }
            auto pixels = renderCrop(continuousLive, context, 512, 512);
            expectInk(pixels, 64, 160, true, "Incremental update discarded earlier live ink");
            expectInk(pixels, previousTip + tip, 160, true, "Incremental update lost new live ink");
        }
        continuousLive.touchEnded();
        expectInk(renderCrop(continuousLive, nullptr, 512, 512), 200, 160, true,
                  "GPU preview did not persist vector ink at touch-up");
        {
            SkiaDrawingEngine held(512, 1024, true);
            held.setToolWithParams("pen", 8, 0x000000, "pixel");
            held.touchBegan(40, 100, 1, 0, 1.57, 100);
            for (int x = 50; x <= 300; x += 10) held.touchMoved(x, 100, 1, 0, 1.57, 200);
            if (!held.updateHoldShapePreview(600)) throw std::runtime_error("Held line was not recognized");
            held.setHoldToShapeEnabled(false);
            if (held.updateHoldShapePreview(700)) throw std::runtime_error("Disabled shape preview reappeared");
            held.touchEnded(610);
            std::vector<nativedrawing::Stroke> strokes;
            nativedrawing::DrawingSerialization serializer;
            if (!serializer.deserialize(held.serializeDrawing(), strokes) || strokes.size() != 1 || strokes[0].toolType != "pen")
                throw std::runtime_error("Disabling shape recognition did not preserve the freehand stroke");
        }
        // Appending strokes must leave unrelated cached tiles intact while
        // rebuilding affected tiles identically to a fresh render.
        for (auto* context : {first.get(), static_cast<GrDirectContext*>(nullptr)}) {
            std::vector<nativedrawing::Point> points;
            for (int i = 0; i < 300; ++i) {
                points.push_back({30.0f + i * 3.0f, 350.0f + 80.0f * std::sin(i * 0.07f),
                    0.5f + 0.2f * std::sin(i * 0.03f), 0, 1.57f, 14, 0});
            }
            SkPaint paint; paint.setColor(SK_ColorBLUE); paint.setStrokeWidth(14);
            nativedrawing::PathRenderer direct, recorded;
            SkPictureRecorder recorder; SkRTreeFactory hierarchy;
            auto* recording = recorder.beginRecording(SkRect::MakeWH(1024, 1024), &hierarchy);
            recorded.drawCrayonPath(recording, points, paint, false);
            auto picture = recorder.finishRecordingAsPicture();
            for (int offset : {0, 512}) {
                const auto info = SkImageInfo::MakeN32Premul(512, 512);
                auto makeSurface = [&] { return context ? SkSurfaces::RenderTarget(context, skgpu::Budgeted::kYes, info) : SkSurfaces::Raster(info); };
                auto a = makeSurface(), b = makeSurface();
                if (!a || !b) throw std::runtime_error("Crayon comparison surface allocation failed");
                a->getCanvas()->clear(SK_ColorTRANSPARENT); b->getCanvas()->clear(SK_ColorTRANSPARENT);
                a->getCanvas()->translate(-offset, 0); b->getCanvas()->translate(-offset, 0);
                direct.drawCrayonPath(a->getCanvas(), points, paint, false);
                b->getCanvas()->drawPicture(picture);
                SkBitmap x, y; x.allocPixels(info); y.allocPixels(info);
                if (!a->readPixels(x, 0, 0) || !b->readPixels(y, 0, 0)) throw std::runtime_error("Crayon readback failed");
                for (int row = 0; row < 512; ++row) for (int col = 0; col < 512; ++col) {
                    if (x.getColor(col, row) != y.getColor(col, row))
                        throw std::runtime_error("Recorded crayon differs from direct rendering");
                }
            }
        }
        for (auto* context : {first.get(), static_cast<GrDirectContext*>(nullptr)}) {
            SkiaDrawingEngine moving(1024, 1024, true);
            moving.setBackgroundType("pdf");
            moving.setToolWithParams("pen", 12, 0x000000, "pixel");
            moving.touchBegan(40, 100, 1);
            for (int x = 50; x <= 900; x += 10) moving.touchMoved(x, 100, 1);
            moving.touchEnded();
            moving.setRenderViewport(1, 0, 0, 1024, 1024);
            expectInk(renderCrop(moving, context, 1024, 1024), 400, 100, true, "Warm tile lost ink");
            moving.setViewportMotionActive(true);
            moving.setRenderViewport(2, 0, 0, 512, 512);
            expectInk(renderCrop(moving, context, 1024, 1024), 800, 200, true, "Moving fallback lost ink");
            moving.touchBegan(40, 200, 1);
            for (int x = 50; x <= 400; x += 10) moving.touchMoved(x, 200, 1);
            moving.touchEnded();
            expectInk(renderCrop(moving, context, 1024, 1024), 400, 400, true, "Moving fallback reused stale ink after an edit");
            moving.setViewportMotionActive(false);
            auto settled = renderCrop(moving, context, 1024, 1024);
            SkiaDrawingEngine fresh(1024, 1024, true);
            fresh.setBackgroundType("pdf");
            if (!fresh.deserializeDrawing(moving.serializeDrawing())) throw std::runtime_error("Could not reload motion test drawing");
            fresh.setRenderViewport(2, 0, 0, 512, 512);
            auto rebuilt = renderCrop(fresh, context, 1024, 1024);
            for (int y = 0; y < 1024; ++y) for (int x = 0; x < 1024; ++x) {
                if (settled.getColor(x, y) != rebuilt.getColor(x, y))
                    throw std::runtime_error("Settled motion frame differs from a fresh render");
            }
        }
        // Reusing recorded crayon geometry across zoom levels must never
        // retain stale geometry after erasing or moving the stroke.
        for (auto* context : {static_cast<GrDirectContext*>(nullptr), first.get()}) {
            SkiaDrawingEngine document(1024, 1024, true);
            document.setBackgroundType("pdf");
            document.setHoldToShapeEnabled(false);
            document.setToolWithParams("crayon", 16, 0xff000000, "pixel");
            document.touchBegan(30, 300, 0.7);
            for (int x = 35; x <= 920; x += 5) document.touchMoved(x, 300 + 30 * std::sin(x * .02), 0.7);
            document.touchEnded();
            document.setRenderViewport(1, 0, 0, 1024, 1024);
            renderCrop(document, context, 1024, 1024);
            document.setRenderViewport(2, 0, 0, 512, 512);
            renderCrop(document, context, 1024, 1024);
            document.setToolWithParams("eraser", 24, 0xff000000, "pixel");
            document.touchBegan(200, 278, 1);
            document.touchMoved(210, 278, 1);
            document.touchEnded();
            auto saved = document.snapshotDrawing();
            SkiaDrawingEngine fresh(1024, 1024, true);
            fresh.setBackgroundType("pdf"); fresh.replaceDrawing(saved);
            fresh.setRenderViewport(2, 0, 0, 512, 512);
            auto cached = renderCrop(document, context, 1024, 1024);
            auto expected = renderCrop(fresh, context, 1024, 1024);
            for (int y = 0; y < 1024; ++y) for (int x = 0; x < 1024; ++x)
                if (cached.getColor(x, y) != expected.getColor(x, y))
                    throw std::runtime_error("Reused crayon geometry became stale after erase");
            if (!document.selectStrokeAt(500, 300 + 30 * std::sin(10.0)))
                throw std::runtime_error("Cannot select crayon for cache test");
            document.beginSelectionDrag(); document.moveSelection(0, 40); document.finalizeMove(); document.clearSelection();
            saved = document.snapshotDrawing(); fresh.replaceDrawing(saved);
            cached = renderCrop(document, context, 1024, 1024);
            expected = renderCrop(fresh, context, 1024, 1024);
            for (int y = 0; y < 1024; ++y) for (int x = 0; x < 1024; ++x)
                if (cached.getColor(x, y) != expected.getColor(x, y))
                    throw std::runtime_error("Reused crayon geometry became stale after moving");
        }
        for (auto* context : {first.get(), static_cast<GrDirectContext*>(nullptr)}) {
            SkiaDrawingEngine cached(1024, 2048, true);
            cached.setBackgroundType("pdf");
            cached.setRenderViewport(1, 0, 0, 1024, 1024);
            SkiaDrawingEngine fresh(1024, 2048, true);
            fresh.setBackgroundType("pdf");
            fresh.setRenderViewport(1, 0, 0, 1024, 1024);
            for (int n = 0; n < 8; ++n) {
                for (auto* engine : {&cached, &fresh}) {
                    engine->setToolWithParams(n % 2 ? "highlighter" : "pen", 12, 0x1133CC, "pixel");
                    engine->touchBegan(40 + n * 50, 80 + n * 65, 1);
                    engine->touchMoved(300 + n * 50, 90 + n * 65, 1);
                    engine->touchEnded();
                }
                (void)renderCrop(cached, context, 1024, 1024);
            }
            auto incremental = renderCrop(cached, context, 1024, 1024);
            auto rebuilt = renderCrop(fresh, context, 1024, 1024);
            for (int y = 0; y < 1024; ++y) for (int x = 0; x < 1024; ++x) {
                if (incremental.getColor(x, y) != rebuilt.getColor(x, y))
                    throw std::runtime_error("Cached tiles diverged from a fresh render");
            }
        }
        {
            auto cacheContext = makeContext();
            SkiaDrawingEngine cachedPages(512, 4096, true);
            cachedPages.setBackgroundType("pdf");
            cachedPages.setToolWithParams("pen", 10, 0x000000, "pixel");
            for (int page = 0; page < 8; ++page) {
                cachedPages.touchBegan(40, page * 512 + 100, 1);
                for (int x = 45; x <= 450; x += 5) cachedPages.touchMoved(x, page * 512 + 100, 1);
                cachedPages.touchEnded();
            }
            for (int page = 0; page < 8; ++page) {
                cachedPages.setRenderViewport(1, 0, page * 512, 512, 512);
                expectInk(renderCrop(cachedPages, cacheContext.get(), 512, 512), 100, 100, true,
                          "Resolving cached tiles lost ink");
            }
            cachedPages.clear();
            cachedPages.setRenderViewport(1, 0, 0, 512, 512);
            auto cleared = renderCrop(cachedPages, cacheContext.get(), 512, 512);
            if (SkColorGetA(cleared.getColor(100, 100)) != 0)
                throw std::runtime_error("Reused resolved tile retained deleted ink");
            cacheContext->freeGpuResources();
            size_t retainedBytes = 0;
            cacheContext->getResourceCacheUsage(nullptr, &retainedBytes);
            // Eight 1 MiB images plus backend overhead fit comfortably here.
            // Retaining their four-sample render targets exceeds this bound.
            if (retainedBytes > 16 * 1024 * 1024)
                throw std::runtime_error("Tile images retained multisampled render attachments");
        }
        // An overview must render every visible page, including newly grown
        // pages, and keep a stroke crossing the divider intact.
        SkiaDrawingEngine overview(512, 2048, true);
        overview.setToolWithParams("pen", 16, 0x000000, "pixel");
        overview.touchBegan(100, 450, 1);
        for (int y = 455; y <= 620; y += 5) overview.touchMoved(100, y, 1);
        overview.touchEnded();
        overview.touchBegan(200, 1700, 1);
        for (int x = 205; x <= 300; x += 5) overview.touchMoved(x, 1700, 1);
        overview.touchEnded();
        for (auto* context : {first.get(), static_cast<GrDirectContext*>(nullptr)}) {
            overview.setRenderViewport(0.25f, 0, 0, 512, 2048);
            const auto pixels = renderCrop(overview, context, 128, 512);
            expectInk(pixels, 25, 120, true, "Overview lost upper crossing stroke");
            expectInk(pixels, 25, 145, true, "Overview lost lower crossing stroke");
            expectInk(pixels, 60, 425, true, "Overview clipped later page");
        }
        if (!overview.resizeDocument(512, 2560)) throw std::runtime_error("Document growth failed");
        overview.setRenderViewport(0.25f, 0, 2048, 512, 512);
        overview.touchBegan(100, 2200, 1);
        for (int x = 105; x <= 300; x += 5) overview.touchMoved(x, 2200, 1);
        expectInk(renderCrop(overview, nullptr, 128, 128), 40, 38, true, "Overview lost live input");
        overview.touchEnded();
        overview.setRenderViewport(0.25f, 0, 2048, 512, 512);
        expectInk(renderCrop(overview, nullptr, 128, 128), 40, 38, true, "New page rejected drawing");
        SkiaDrawingEngine partial(512, 512, true);
        drawLine(partial);
        partial.setRenderViewport(1, 0, 0, 64, 64);
        renderCrop(partial, nullptr, 64, 64);
        partial.setRenderViewport(1, 0, 80, 128, 64);
        expectInk(renderCrop(partial, nullptr, 128, 64), 100, 20, true,
                  "Panning into a cached partial tile lost ink");
        SkiaDrawingEngine engine(512, 512);
        drawLine(engine);
        engine.setRenderViewport(2, 0, 0, 512, 512);
        for (auto* context : {first.get(), static_cast<GrDirectContext*>(nullptr), second.get(), first.get()}) {
            auto pixels = render(engine, context);
            expectInk(pixels, 240, 200, true, "Stroke lost when switching render surfaces");
            expectInk(pixels, 240, 100, false, "Stroke rendered at wrong zoom");
            for (int x = 509; x <= 515; ++x) {
                expectInk(pixels, x, 200, true, "Gap at a zoom tile boundary");
            }
        }
        // A zoomed viewport must render into a small target, independent of
        // full page dimensions. Compare it pixel-for-pixel with the same crop
        // of a full render, on both raster and real Metal surfaces.
        for (int scale : {1, 2, 5}) {
            engine.setRenderViewport(scale, 80, 60, 128, 96);
            for (auto* context : {first.get(), static_cast<GrDirectContext*>(nullptr)}) {
                auto full = render(engine, context, false, 512 * scale);
                auto crop = renderCrop(engine, context, 128 * scale, 96 * scale);
                for (int y = 0; y < crop.height(); ++y) {
                    for (int x = 0; x < crop.width(); ++x) {
                        if (crop.getColor(x, y) != full.getColor(x + 80 * scale, y + 60 * scale))
                            throw std::runtime_error("Viewport crop differs from full-page render");
                    }
                }
                expectInk(crop, 40 * scale, 40 * scale, true, "Viewport omitted visible ink");
                expectInk(render(engine, nullptr, true), 120, 100, true, "Cropped viewport changed page export");
            }
        }
        engine.setRenderViewport(2, 0, 0, 512, 512);
        engine.undo();
        expectInk(render(engine, first.get()), 240, 200, false, "Undo left stale zoom tiles");
        engine.redo();
        expectInk(render(engine, first.get()), 240, 200, true, "Redo did not restore zoom tiles");

        engine.setToolWithParams("eraser", 28, 0x000000, "pixel");
        engine.touchBegan(120, 85, 1);
        for (int y = 90; y <= 120; y += 5) engine.touchMoved(120, y, 1);
        engine.touchEnded();
        expectInk(render(engine, first.get()), 240, 200, false, "Erased pixels survived cached GPU tiles");
        expectInk(render(engine, nullptr, true), 120, 100, false, "Export lost erasure");
        expectInk(render(engine, nullptr, true), 65, 100, true, "Export lost remaining stroke");
        expectInk(render(engine, first.get()), 130, 200, true, "Export changed viewport scale");
        engine.clear();
        expectInk(render(engine, first.get()), 130, 200, false, "Pool reuse left cached ink");
        // Save page ownership without splitting a crossing stroke or sorting
        // overlapping ink by page instead of its original drawing order.
        {
            SkiaDrawingEngine original(512, 2000, true);
            original.setToolWithParams("pen", 10, 0x000000, "pixel");
            for (auto ends : {std::pair<int, int>{1100, 900}, {920, 1080}}) {
                const int direction = ends.second > ends.first ? 5 : -5;
                original.touchBegan(100, ends.first, 1);
                for (int y = ends.first + direction; y != ends.second + direction; y += direction)
                    original.touchMoved(100, y, 1);
                original.touchEnded();
            }
            const auto originalBytes = original.serializeDrawing();
            nativedrawing::DrawingSerialization serializer;
            std::vector<nativedrawing::Stroke> strokes;
            if (!serializer.deserialize(originalBytes, strokes)) throw std::runtime_error("Cannot decode document fixture");
            auto pages = nativedrawing::partitionContinuousDocument(strokes, 2, 1000);
            if (pages[0].strokes.size() != 1 || pages[1].strokes.size() != 1 ||
                pages[0].order[0] != 1 || pages[1].order[0] != 0)
                throw std::runtime_error("Document partition split or reordered crossing strokes");
            for (auto& page : pages) {
                const auto bytes = serializer.serialize(page.strokes);
                if (!serializer.deserialize(bytes, page.strokes)) throw std::runtime_error("Page roundtrip failed");
            }
            const auto restored = nativedrawing::composeContinuousDocument(pages, 1000);
            if (serializer.serialize(restored) != originalBytes)
                throw std::runtime_error("Page ownership roundtrip changed stroke geometry or ordering");
            auto comparePreparedLoad = [&](const std::vector<nativedrawing::Stroke>& preparedStrokes) {
                for (auto* context : {static_cast<GrDirectContext*>(nullptr), first.get()}) {
                    SkiaDrawingEngine decoded(512, 2000, true);
                    SkiaDrawingEngine prepared(512, 2000, true);
                    drawLine(prepared);
                    prepared.setRenderViewport(1, 80, 850, 100, 300);
                    renderCrop(prepared, context, 100, 300); // Populate the previous drawing's tiles.
                    auto incoming = preparedStrokes;
                    prepared.replaceDrawing(incoming);
                    if (incoming.size() != 1 || !decoded.deserializeDrawing(serializer.serialize(preparedStrokes)))
                        throw std::runtime_error("Prepared load did not swap its owned geometry");
                    for (float scale : {0.25f, 0.5f, 1.0f, 2.0f, 5.0f}) {
                        decoded.setRenderViewport(scale, 80, 850, 100, 300);
                        prepared.setRenderViewport(scale, 80, 850, 100, 300);
                        const auto expected = renderCrop(decoded, context, int(100 * scale), int(300 * scale));
                        const auto actual = renderCrop(prepared, context, int(100 * scale), int(300 * scale));
                        for (int y = 0; y < actual.height(); ++y)
                            for (int x = 0; x < actual.width(); ++x)
                                if (actual.getColor(x, y) != expected.getColor(x, y))
                                    throw std::runtime_error("Prepared load changed crossing/erased ink pixels");
                    }
                }
            };
            comparePreparedLoad(restored);
            const auto exportPages = nativedrawing::projectContinuousDocumentPages(pages, 1000, {0, 1});
            for (int pageIndex = 0; pageIndex < 2; ++pageIndex) {
                if (exportPages[pageIndex].size() != 2)
                    throw std::runtime_error("Export projection omitted neighboring crossing ink");
                SkiaDrawingEngine pageEngine(512, 1000);
                if (!pageEngine.deserializeDrawing(serializer.serialize(exportPages[pageIndex])))
                    throw std::runtime_error("Cannot load projected export page");
                pageEngine.setRenderViewport(1, 0, 0, 512, 1000);
                expectInk(render(pageEngine, nullptr, true), 100, pageIndex == 0 ? 950 : 50, true,
                    "Bounded page export lost crossing ink");
            }
            if (!original.clearDocumentPage(0, 1000)) throw std::runtime_error("Page clear failed");
            std::vector<nativedrawing::Stroke> remaining;
            if (!serializer.deserialize(original.serializeDrawing(), remaining) || remaining.size() != 1 ||
                remaining[0].points.front().y != 1100)
                throw std::runtime_error("Page clear removed another page or split a crossing stroke");
            original.undo();
            if (original.serializeDrawing() != originalBytes)
                throw std::runtime_error("Page clear undo did not restore document exactly");
            original.redo();
            if (!serializer.deserialize(original.serializeDrawing(), remaining) || remaining.size() != 1)
                throw std::runtime_error("Page clear redo failed");
            if (original.clearDocumentPage(2, 1000) || original.clearDocumentPage(-1, 1000) ||
                original.clearDocumentPage(0, 0))
                throw std::runtime_error("Invalid page clear accepted");
            // Empty-page clear must not consume undo history.
            original.clearDocumentPage(0, 1000);
            original.undo();
            if (original.serializeDrawing() != originalBytes)
                throw std::runtime_error("Empty page clear consumed undo history");
            // Preserve cross-owner legacy eraser references through reordering.
            strokes[1].isEraser = true;
            strokes[1].affectedStrokeIndices = {0};
            strokes[0].erasedBy.push_back({100, 1000, 8});
            auto erasedPages = nativedrawing::partitionContinuousDocument(strokes, 2, 1000);
            const auto erasedRoundtrip = nativedrawing::composeContinuousDocument(erasedPages, 1000);
            if (erasedRoundtrip[1].affectedStrokeIndices != strokes[1].affectedStrokeIndices ||
                erasedRoundtrip[0].erasedBy[0].y != 1000)
                throw std::runtime_error("Document partition lost eraser metadata");
            comparePreparedLoad(erasedRoundtrip);
            auto corruptPages = pages;
            corruptPages[1].order[0] = corruptPages[0].order[0];
            bool rejected = false;
            try { nativedrawing::composeContinuousDocument(corruptPages, 1000); }
            catch (const std::invalid_argument&) { rejected = true; }
            if (!rejected) throw std::runtime_error("Duplicate stroke order was silently accepted");
        }
        // A 100-page document must keep one editable stroke across a page
        // boundary without allocating a full-document raster surface.
        for (auto* context : {static_cast<GrDirectContext*>(nullptr), first.get()}) {
            SkiaDrawingEngine document(512, 100000, true);
            document.setRenderViewport(1, 0, 49800, 512, 512);
            document.setToolWithParams("pen", 10, 0x000000, "pixel");
            document.touchBegan(100, 49900, 1);
            for (int y = 49905; y <= 50100; y += 5) document.touchMoved(100, y, 1);
            auto livePixels = renderCrop(document, context, 512, 512);
            expectInk(livePixels, 100, 150, true, "Continuous live ink lost above boundary");
            expectInk(livePixels, 100, 250, true, "Continuous live ink lost below boundary");
            document.touchEnded();
            for (float scale : {1.0f, 2.0f, 5.0f}) {
                document.setRenderViewport(scale, 80, 49950, 100, 100);
                auto pixels = renderCrop(document, context, int(100 * scale), int(100 * scale));
                expectInk(pixels, int(20 * scale), int(25 * scale), true, "Committed ink lost above boundary");
                expectInk(pixels, int(20 * scale), int(75 * scale), true, "Committed ink lost below boundary");
            }
            if (!document.resizeDocument(512, 101000)) throw std::runtime_error("Continuous page append failed");
            if (document.resizeDocument(0, 101000)) throw std::runtime_error("Invalid document resize accepted");
            const auto bytes = document.serializeDrawing();
            document.undo();
            expectInk(renderCrop(document, context, 500, 500), 100, 125, false, "Undo retained upper fragment");
            expectInk(renderCrop(document, context, 500, 500), 100, 375, false, "Undo retained lower fragment");
            document.redo();
            expectInk(renderCrop(document, context, 500, 500), 100, 375, true, "Redo lost lower fragment");
            SkiaDrawingEngine reloaded(512, 100000, true);
            if (!reloaded.deserializeDrawing(bytes)) throw std::runtime_error("Continuous document reload failed");
            reloaded.setRenderViewport(1, 0, 49800, 512, 512);
            expectInk(renderCrop(reloaded, context, 512, 512), 100, 250, true, "Reload lost cross-page ink");
            if (!reloaded.selectStrokeAt(100, 50050)) throw std::runtime_error("Cannot select lower half of crossing stroke");
            reloaded.beginSelectionDrag();
            expectInk(renderCrop(reloaded, context, 512, 512), 100, 150, true, "Selection drag lost crossing stroke");
            reloaded.moveSelection(60, 0);
            expectInk(renderCrop(reloaded, context, 512, 512), 160, 150, true, "Continuous selection drag lost upper ink");
            expectInk(renderCrop(reloaded, context, 512, 512), 160, 250, true, "Continuous selection drag lost lower ink");
            expectInk(renderCrop(reloaded, context, 512, 512), 100, 250, false, "Continuous selection drag duplicated ink");
            reloaded.endSelectionDrag();
            expectInk(renderCrop(reloaded, context, 512, 512), 100, 250, true, "Cancelling selection move changed the original stroke");
            expectInk(renderCrop(reloaded, context, 512, 512), 160, 250, false, "Cancelling selection move left a displaced preview");
            reloaded.beginSelectionDrag();
            reloaded.moveSelection(60, 0);
            reloaded.finalizeMove();
            reloaded.undo();
            if (!reloaded.selectStrokeAt(100, 50050)) throw std::runtime_error("Move undo did not restore crossing stroke");
            reloaded.endSelectionDrag();
            reloaded.deleteSelection();
            expectInk(renderCrop(reloaded, context, 512, 512), 100, 150, false, "Deleting selected lower half left upper half");
            reloaded.undo();
            expectInk(renderCrop(reloaded, context, 512, 512), 100, 250, true, "Undo selection deletion lost lower half");
            for (int pageTop : {49000, 50000}) {
                const auto info = SkImageInfo::MakeN32Premul(512, 1000);
                auto surface = SkSurfaces::Raster(info);
                surface->getCanvas()->translate(0, -pageTop);
                reloaded.renderForExport(surface->getCanvas());
                SkBitmap pixels;
                pixels.allocPixels(info);
                if (!surface->readPixels(pixels, 0, 0)) throw std::runtime_error("Page export readback failed");
                expectInk(pixels, 100, pageTop == 49000 ? 950 : 50, true, "Paged export cut crossing stroke");
            }
            reloaded.setToolWithParams("eraser", 28, 0x000000, "pixel");
            reloaded.touchBegan(85, 50050, 1);
            for (int x = 90; x <= 120; x += 5) reloaded.touchMoved(x, 50050, 1);
            reloaded.touchEnded();
            expectInk(renderCrop(reloaded, context, 512, 512), 100, 250, false, "Continuous document pixel erase failed");
        }
        std::cout << "Zoom surface smoke tests passed\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
