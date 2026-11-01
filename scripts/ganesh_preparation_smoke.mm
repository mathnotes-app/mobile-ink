#import <Metal/Metal.h>
#include "SkiaDrawingEngine.h"
#include <chrono>
#include <iostream>
#include <thread>
#include <vector>

extern "C" {
void* createGaneshMetalContext(void*, void*);
bool warmGaneshMetalContext(void*, void*);
void destroyGaneshMetalContext(void*);
bool renderToGaneshMetalTexture(void*, void*, void*, int, int, bool);
bool renderToGaneshMetalTextureForDisplay(void*, void*, void*, int, int, bool, bool);
void renderToDisplayCanvas(void*, void*, bool, bool);
void* createSkiaCanvas(void*, int, int, int);
void renderVisibleViewportToCanvas(void*, void*);
void destroySkiaCanvas(void*);
void* snapshotZoomTiles(void*, float, float, float, float, float);
int prepareNextZoomTile(void*, void*, void*, void**);
bool installPreparedZoomTile(void*, void*, void*, void*);
bool hasPreparedZoomTiles(void*, void*);
void releaseZoomTileSnapshot(void*);
}

int main() {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        id<MTLCommandQueue> queue = [device newCommandQueue];
        if (!device || !queue) return 1;
        void* context = nullptr;
        bool ready = false;
        const auto start = std::chrono::steady_clock::now();
        std::thread preparation([&] {
            @autoreleasepool {
                context = createGaneshMetalContext((__bridge void*)device, (__bridge void*)queue);
                ready = context && warmGaneshMetalContext(context, (__bridge void*)device);
            }
        });
        preparation.join();
        if (!ready) {
            if (context) destroyGaneshMetalContext(context);
            std::cerr << "Background Ganesh preparation failed\n";
            return 1;
        }
        const auto preparationMs = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - start).count();
        bool matches = true;
        {
            // Exercise the production GPU handoff across two contexts, then
            // destroy the producer before consuming the imported texture.
            id<MTLCommandQueue> workerQueue = [device newCommandQueue];
            void* workerContext = createGaneshMetalContext((__bridge void*)device, (__bridge void*)workerQueue);
            if (!workerContext) return 1;
            nativedrawing::SkiaDrawingEngine live(512, 512, true), fresh(512, 512, true);
            auto photo = SkSurfaces::Raster(SkImageInfo::MakeN32Premul(32, 32));
            photo->getCanvas()->clear(SK_ColorRED);
            nativedrawing::ImageLayer layer;
            layer.id = "photo"; layer.image = photo->makeImageSnapshot();
            layer.bounds = SkRect::MakeXYWH(80, 80, 120, 120); layer.layerOrder = 2;
            for (auto* drawing : {&live, &fresh}) {
                drawing->setBackgroundType("pdf");
                drawing->setImageLayers({layer});
                drawing->setToolWithParams("crayon", 18, 0xff0033cc, "pixel");
                drawing->touchBegan(30, 120, .7f);
                for (int x = 35; x < 240; x += 5) drawing->touchMoved(x, 120, .7f);
                drawing->touchEnded();
                drawing->setToolWithParams("eraser", 16, 0xff000000, "pixel");
                drawing->touchBegan(120, 100, 1); drawing->touchMoved(120, 140, 1); drawing->touchEnded();
                drawing->setRenderViewport(1, 0, 0, 256, 256);
            }
            auto smallDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:256 height:256 mipmapped:NO];
            smallDesc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
            id<MTLTexture> small = [device newTextureWithDescriptor:smallDesc];
            if (!renderToGaneshMetalTexture(&live, context, (__bridge void*)small, 256, 256, true) ||
                !renderToGaneshMetalTexture(&fresh, context, (__bridge void*)small, 256, 256, true)) return 1;
            void* batch = snapshotZoomTiles(&live, 2, 0, 0, 256, 256);
            if (!batch) return 1;
            void* tile = nullptr;
            int tileResult;
            while ((tileResult = prepareNextZoomTile(batch, workerContext, (__bridge void*)device, &tile)) == 1) {
                if (!tile || !installPreparedZoomTile(&live, batch, context, tile)) return 1;
            }
            if (tileResult != 0 || !hasPreparedZoomTiles(&live, batch)) return 1;
            destroyGaneshMetalContext(workerContext);
            releaseZoomTileSnapshot(batch);
            auto desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:512 height:512 mipmapped:NO];
            desc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
            desc.storageMode = MTLStorageModeShared;
            id<MTLTexture> target = [device newTextureWithDescriptor:desc];
            std::vector<uint8_t> actual(512 * 512 * 4), expected(actual.size());
            for (auto* drawing : {&live, &fresh}) {
                drawing->setRenderViewport(2, 0, 0, 256, 256);
                if (!renderToGaneshMetalTexture(drawing, context, (__bridge void*)target, 512, 512, true)) return 1;
                id<MTLCommandBuffer> barrier = [queue commandBuffer]; [barrier commit]; [barrier waitUntilCompleted];
                auto& pixels = drawing == &live ? actual : expected;
                [target getBytes:pixels.data() bytesPerRow:512 * 4 fromRegion:MTLRegionMake2D(0, 0, 512, 512) mipmapLevel:0];
            }
            if (actual != expected) {
                std::cerr << "Cross-context prepared tile changed image, eraser, or crayon pixels\n";
                return 1;
            }
            workerContext = createGaneshMetalContext((__bridge void*)device, (__bridge void*)workerQueue);
            batch = snapshotZoomTiles(&live, 3, 0, 0, 150, 150);
            if (!workerContext || !batch || prepareNextZoomTile(batch, workerContext, (__bridge void*)device, &tile) != 1 || !tile) return 1;
            live.setToolWithParams("pen", 8, 0xff000000, "pixel");
            live.touchBegan(20, 20, 1); live.touchMoved(80, 20, 1); live.touchEnded();
            if (installPreparedZoomTile(&live, batch, context, tile)) {
                std::cerr << "Installed a GPU tile after the note changed\n";
                return 1;
            }
            releaseZoomTileSnapshot(batch);
            destroyGaneshMetalContext(workerContext);
        }
        {
            nativedrawing::SkiaDrawingEngine drawing(256, 256, true);
            drawing.setBackgroundType("pdf");
            auto descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                width:256 height:256 mipmapped:NO];
            descriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
            descriptor.storageMode = MTLStorageModeShared;
            id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
            if (!texture) return 1;
            for (uint32_t color : {0xFFFF0000u, 0xFF00FF00u, 0xFF0000FFu, 0xFF000000u, 0xFFFFFFFFu, 0x80336699u}) {
                drawing.clear();
                drawing.setToolWithParams("pen", 16, color, "pixel");
                drawing.touchBegan(24, 80, 1);
                for (int x = 32; x <= 232; x += 8) drawing.touchMoved(x, 80, 1);
                for (bool committed : {false, true}) {
                    if (committed) drawing.touchEnded();
                    const auto authored = drawing.serializeDrawing();
                    for (bool dark : {false, true}) {
                    const bool rendered = dark
                        ? renderToGaneshMetalTextureForDisplay(&drawing, context, (__bridge void*)texture, 256, 256, true, true)
                        : renderToGaneshMetalTexture(&drawing, context, (__bridge void*)texture, 256, 256, true);
                    if (!rendered)
                        return 1;
                    id<MTLCommandBuffer> barrier = [queue commandBuffer];
                    [barrier commit];
                    [barrier waitUntilCompleted];
                    std::vector<uint8_t> cpu(256 * 256 * 4), gpu(cpu.size());
                    [texture getBytes:gpu.data() bytesPerRow:256 * 4 fromRegion:MTLRegionMake2D(0, 0, 256, 256) mipmapLevel:0];
                    void* canvas = createSkiaCanvas(cpu.data(), 256, 256, 256 * 4);
                    if (!canvas) return 1;
                    if (dark) renderToDisplayCanvas(&drawing, canvas, true, true);
                    else renderVisibleViewportToCanvas(&drawing, canvas);
                    destroySkiaCanvas(canvas);
                    const int center = (80 * 256 + 100) * 4;
                    for (int channel = 0; channel < 4; ++channel) {
                        if (std::abs(int(cpu[center + channel]) - int(gpu[center + channel])) > (dark ? 1 : 0)) {
                            matches = false;
                            std::cerr << (dark ? "Dark " : "Light ") << "CPU/GPU " << (committed ? "committed" : "live")
                                << " color mismatch for " << std::hex << color << std::dec
                                << " channel " << channel << ": " << int(cpu[center + channel])
                                << " vs " << int(gpu[center + channel]) << '\n';
                        }
                    }
                    }
                    if (drawing.serializeDrawing() != authored) {
                        std::cerr << "Presentation changed authored drawing bytes\n";
                        matches = false;
                    }
                }
            }
            drawing.clear();
            auto image = SkSurfaces::Raster(SkImageInfo::MakeN32Premul(32, 32));
            image->getCanvas()->clear(SK_ColorRED);
            nativedrawing::ImageLayer layer;
            layer.id = "red-photo"; layer.image = image->makeImageSnapshot();
            layer.bounds = SkRect::MakeXYWH(30, 30, 160, 160); layer.layerOrder = 1;
            drawing.setImageLayers({layer});
            drawing.setToolWithParams("pen", 16, 0xFF000000u, "pixel");
            drawing.touchBegan(40, 80, 1);
            for (int x = 48; x <= 160; x += 8) drawing.touchMoved(x, 80, 1);
            drawing.touchEnded();
            for (bool dark : {false, true}) {
                if (!renderToGaneshMetalTextureForDisplay(&drawing, context, (__bridge void*)texture, 256, 256, true, dark)) return 1;
                id<MTLCommandBuffer> barrier = [queue commandBuffer]; [barrier commit]; [barrier waitUntilCompleted];
                std::vector<uint8_t> gpu(256 * 256 * 4);
                [texture getBytes:gpu.data() bytesPerRow:256 * 4 fromRegion:MTLRegionMake2D(0, 0, 256, 256) mipmapLevel:0];
                const int photo = (50 * 256 + 100) * 4, ink = (80 * 256 + 100) * 4;
                if (gpu[photo] > 5 || gpu[photo + 1] > 5 || gpu[photo + 2] < 250 || gpu[photo + 3] < 250 ||
                    (dark ? gpu[ink + 2] < 220 : gpu[ink + 2] > 20)) {
                    matches = false;
                    std::cerr << "Photo or ink changed color incorrectly in " << (dark ? "dark" : "light") << " mode\n";
                }
            }
            // An invisible image should not change the presentation of ink.
            // This compares the per-ink transform used for mixed image notes
            // against the original whole-surface display transform.
            layer.hidden = true;
            for (uint32_t color : {0xFFFF0000u, 0xFF00FF00u, 0xFF0000FFu, 0xFF000000u, 0x80336699u}) {
                drawing.clear(); drawing.setImageLayers({});
                drawing.setToolWithParams("pen", 16, color, "pixel");
                drawing.touchBegan(24, 80, 1);
                for (int x = 32; x <= 232; x += 8) drawing.touchMoved(x, 80, 1);
                drawing.touchEnded();
                for (bool dark : {false, true}) {
                    std::vector<uint8_t> baseline(256 * 256 * 4), mixed(baseline.size());
                    drawing.setImageLayers({});
                    if (!renderToGaneshMetalTextureForDisplay(&drawing, context, (__bridge void*)texture, 256, 256, true, dark)) return 1;
                    id<MTLCommandBuffer> firstBarrier = [queue commandBuffer]; [firstBarrier commit]; [firstBarrier waitUntilCompleted];
                    [texture getBytes:baseline.data() bytesPerRow:256 * 4 fromRegion:MTLRegionMake2D(0, 0, 256, 256) mipmapLevel:0];
                    drawing.setImageLayers({layer});
                    if (!renderToGaneshMetalTextureForDisplay(&drawing, context, (__bridge void*)texture, 256, 256, true, dark)) return 1;
                    id<MTLCommandBuffer> secondBarrier = [queue commandBuffer]; [secondBarrier commit]; [secondBarrier waitUntilCompleted];
                    [texture getBytes:mixed.data() bytesPerRow:256 * 4 fromRegion:MTLRegionMake2D(0, 0, 256, 256) mipmapLevel:0];
                    const int pixel = (80 * 256 + 100) * 4;
                    for (int channel = 0; channel < 4; ++channel) {
                        if (std::abs(int(baseline[pixel + channel]) - int(mixed[pixel + channel])) > 2) {
                            matches = false;
                            std::cerr << "Image layer changed ink display color, channel " << channel
                                << ": " << int(baseline[pixel + channel]) << " vs " << int(mixed[pixel + channel]) << '\n';
                        }
                    }
                }
            }
            // Selection handles are UI chrome, not authored ink. They must
            // stay blue in both appearances, with and without image layers.
            auto neutralImage = SkSurfaces::Raster(SkImageInfo::MakeN32Premul(8, 8));
            neutralImage->getCanvas()->clear(SK_ColorWHITE);
            layer.image = neutralImage->makeImageSnapshot();
            layer.hidden = false;
            for (bool hasImage : {false, true}) {
                drawing.clear();
                drawing.setImageLayers(hasImage ? std::vector<nativedrawing::ImageLayer>{layer}
                                                : std::vector<nativedrawing::ImageLayer>{});
                drawing.setToolWithParams("pen", 16, 0xFF000000u, "pixel");
                drawing.touchBegan(24, 80, 1);
                for (int x = 32; x <= 232; x += 8) drawing.touchMoved(x, 80, 1);
                drawing.touchEnded();
                drawing.setToolWithParams("select", 1, 0xFF000000u, "pixel");
                if (!drawing.selectStrokeAt(100, 80)) return 1;
                for (bool dark : {false, true}) {
                    if (!renderToGaneshMetalTextureForDisplay(&drawing, context, (__bridge void*)texture, 256, 256, true, dark)) return 1;
                    id<MTLCommandBuffer> barrier = [queue commandBuffer]; [barrier commit]; [barrier waitUntilCompleted];
                    std::vector<uint8_t> gpu(256 * 256 * 4), cpu(gpu.size());
                    [texture getBytes:gpu.data() bytesPerRow:256 * 4 fromRegion:MTLRegionMake2D(0, 0, 256, 256) mipmapLevel:0];
                    void* canvas = createSkiaCanvas(cpu.data(), 256, 256, 256 * 4);
                    if (!canvas) return 1;
                    renderToDisplayCanvas(&drawing, canvas, true, dark);
                    destroySkiaCanvas(canvas);
                    for (const auto* pixels : {&gpu, &cpu}) {
                        int blue = 0, orange = 0;
                        for (size_t i = 0; i < pixels->size(); i += 4) {
                            if ((*pixels)[i + 3] < 200) continue;
                            if ((*pixels)[i] > 180 && (*pixels)[i + 2] < 100) ++blue;
                            if ((*pixels)[i + 2] > 180 && (*pixels)[i] < 100) ++orange;
                        }
                        if (blue < 10 || orange > 0) {
                            matches = false;
                            std::cerr << "Selection chrome must be blue: image=" << hasImage << " dark=" << dark
                                      << " backend=" << (pixels == &gpu ? "GPU" : "CPU")
                                      << " blue=" << blue << " orange=" << orange << '\n';
                        }
                    }
                }
            }
        }
        destroyGaneshMetalContext(context);
        if (!matches) return 1;
        std::cout << "Background preparation and sequential context handoff passed (" << preparationMs << " ms); light/dark CPU/GPU live and committed colors match; authored bytes unchanged\n";
    }
    return 0;
}
