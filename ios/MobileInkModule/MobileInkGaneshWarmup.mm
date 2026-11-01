#import <Metal/Metal.h>
#include "cpp/SkiaDrawingEngine.h"
#include <cmath>
#include <include/gpu/ganesh/GrDirectContext.h>

extern "C" bool renderToGaneshMetalTexture(void*, void*, void*, int, int, bool);
extern "C" bool renderToGaneshMetalTextureForDisplay(void*, void*, void*, int, int, bool, bool);

// Called exclusively by the preparation queue before this context is handed
// to the UI thread. Compile the live, tiled, clipped and compositing programs
// on a small private target using an independent drawing, never the live note.
extern "C" bool warmGaneshMetalContext(void* contextPtr, void* devicePtr) {
    if (!contextPtr || !devicePtr) return false;
    try {
        @autoreleasepool {
            id<MTLDevice> device = (__bridge id<MTLDevice>)devicePtr;
            auto descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                width:256 height:256 mipmapped:NO];
            descriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
            descriptor.storageMode = MTLStorageModePrivate;
            id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
            if (!texture) return false;
            nativedrawing::SkiaDrawingEngine drawing(256, 256, true);
            drawing.setBackgroundType("pdf");
            auto render = [&] {
                return renderToGaneshMetalTexture(&drawing, contextPtr, (__bridge void*)texture, 256, 256, true);
            };
            for (const char* tool : {"pen", "pencil", "marker", "highlighter", "crayon", "calligraphy"}) {
                for (float pressure : {0.1f, 1.0f}) {
                    for (bool curved : {false, true}) {
                        drawing.clear();
                        drawing.setToolWithParams(tool, 12, 0xFF3040E0, "pixel");
                        drawing.touchBegan(24, curved ? 80 + 14 * std::sin(24 * 0.08f) : 80, pressure);
                        for (int x = 32; x <= 232; x += 8) drawing.touchMoved(x, curved ? 80 + 14 * std::sin(x * 0.08f) : 80, pressure);
                        if (!render()) return false;
                        drawing.touchEnded();
                        if (!render()) return false;
                    }
                }
            }
            drawing.setToolWithParams("eraser", 18, 0xFF000000, "pixel");
            drawing.touchBegan(128, 64, 1);
            drawing.touchMoved(128, 96, 1);
            drawing.touchEnded();
            if (!render()) return false;
            if (drawing.selectStrokeAt(64, 80 + 14 * std::sin(64 * 0.08f))) {
                drawing.beginSelectionDrag();
                drawing.moveSelection(4, 4);
                if (!render()) return false;
                drawing.finalizeMove();
            }
            for (float scale : {0.25f, 0.5f, 1.0f, 2.0f, 5.0f}) {
                drawing.setRenderViewport(scale, 0, 0, 256, 256);
                if (!render()) return false;
            }
            // Compile the display-only contrast program before it can be
            // selected by a theme change on the input thread.
            if (!renderToGaneshMetalTextureForDisplay(&drawing, contextPtr,
                (__bridge void*)texture, 256, 256, true, true)) return false;
            auto* handle = static_cast<sk_sp<GrDirectContext>*>(contextPtr);
            (*handle)->flushAndSubmit(GrSyncCpu::kYes);
            return true;
        }
    } catch (...) {
        return false;
    }
}
