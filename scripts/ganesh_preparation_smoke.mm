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
        }
        destroyGaneshMetalContext(context);
        if (!matches) return 1;
        std::cout << "Background preparation and sequential context handoff passed (" << preparationMs << " ms); light/dark CPU/GPU live and committed colors match; authored bytes unchanged\n";
    }
    return 0;
}
