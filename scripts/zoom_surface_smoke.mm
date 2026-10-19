#include "ContinuousDocumentPages.h"
#include "DrawingSerialization.h"
#import <Metal/Metal.h>
#include "../cpp/SkiaDrawingEngine.h"
#include "include/core/SkBitmap.h"
#include "include/gpu/ganesh/GrDirectContext.h"
#include "include/gpu/ganesh/SkSurfaceGanesh.h"
#include "include/gpu/ganesh/mtl/GrMtlBackendContext.h"
#include "include/gpu/ganesh/mtl/GrMtlDirectContext.h"
#include <iostream>
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
    const bool actual = SkColorGetR(color) < 100 && SkColorGetG(color) < 100;
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
