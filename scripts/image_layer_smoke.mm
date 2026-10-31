#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#include "SkiaDrawingEngine.h"
#include <include/core/SkData.h>
#include <include/core/SkBitmap.h>
#include <include/core/SkSurface.h>
#include <include/encode/SkPngEncoder.h>
#include <stdexcept>
#include <iostream>

extern "C" void* prepareDocumentImageLayers(const char*, double);
extern "C" void installDocumentImageLayers(void*, void*);
extern "C" void releaseDocumentImageLayers(void*);
extern "C" bool documentImageLayersAreAnimated(void*);
extern "C" void* snapshotDocumentImageLayers(void*);
extern "C" int advanceDocumentImageLayers(void*, double);
extern "C" void installAnimatedDocumentImageLayers(void*, void*);

int main() { @autoreleasepool {
    try {
        auto source = SkSurfaces::Raster(SkImageInfo::MakeN32Premul(40, 40));
        source->getCanvas()->clear(SK_ColorBLUE);
        SkPaint red; red.setColor(SK_ColorRED);
        source->getCanvas()->drawRect(SkRect::MakeWH(40, 20), red);
        auto png = SkPngEncoder::Encode(nullptr, source->makeImageSnapshot().get(), {});
        NSString* base64 = [[NSData dataWithBytes:png->data() length:png->size()] base64EncodedStringWithOptions:0];
        NSArray* input = @[@{ @"id": @"sample", @"uri": [@"data:image/png;base64," stringByAppendingString:base64],
                              @"x": @10, @"y": @10, @"width": @40, @"height": @40, @"layerOrder": @1 }];
        NSData* json = [NSJSONSerialization dataWithJSONObject:input options:0 error:nil];
        NSString* encoded = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
        void* prepared = prepareDocumentImageLayers(encoded.UTF8String, 2);
        if (!prepared) throw std::runtime_error("Image preparation failed");
        nativedrawing::SkiaDrawingEngine engine(160, 160, true);
        engine.setBackgroundType("pdf");
        installDocumentImageLayers(&engine, prepared);
        releaseDocumentImageLayers(prepared);
        // A distant layer must not be decoded, but its order must still be
        // accounted for before the next stroke is created.
        void* deferred = prepareDocumentImageLayers("[{\"id\":\"distant\",\"uri\":\"file:///missing\",\"layerOrder\":42,\"defer\":true}]", 2);
        if (!deferred) throw std::runtime_error("Deferred image was decoded");
        installDocumentImageLayers(&engine, deferred);
        releaseDocumentImageLayers(deferred);
        if (engine.reserveLayerOrder() <= 42) throw std::runtime_error("Deferred image order was lost");
        prepared = prepareDocumentImageLayers(encoded.UTF8String, 2);
        if (!prepared) throw std::runtime_error("Image re-preparation failed");
        installDocumentImageLayers(&engine, prepared);
        releaseDocumentImageLayers(prepared);
        auto output = SkSurfaces::Raster(SkImageInfo::MakeN32Premul(160, 160));
        engine.renderVisibleViewport(output->getCanvas());
        SkBitmap bitmap; bitmap.allocPixels(SkImageInfo::MakeN32Premul(160, 160));
        if (!output->readPixels(bitmap, 0, 0)) throw std::runtime_error("Image readback failed");
        if (SkColorGetR(bitmap.getColor(60, 35)) < 200 || SkColorGetB(bitmap.getColor(60, 85)) < 200)
            throw std::runtime_error("Image orientation or scale is incorrect");

        NSMutableData* gifData = [NSMutableData data];
        CGImageDestinationRef gif = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)gifData,
            CFSTR("com.compuserve.gif"), 2, nullptr);
        if (!gif) throw std::runtime_error("Cannot create GIF fixture");
        CGImageDestinationSetProperties(gif, (__bridge CFDictionaryRef)@{
            (__bridge NSString*)kCGImagePropertyGIFDictionary: @{(__bridge NSString*)kCGImagePropertyGIFLoopCount: @0}});
        NSDictionary* frameOptions = @{(__bridge NSString*)kCGImagePropertyGIFDictionary:
            @{(__bridge NSString*)kCGImagePropertyGIFDelayTime: @0.1}};
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        for (int frame = 0; frame < 2; ++frame) {
            std::vector<uint8_t> rgba(20 * 20 * 4, 0);
            for (int pixel = 0; pixel < 20 * 20; ++pixel) { rgba[pixel * 4 + (frame ? 2 : 0)] = 255; rgba[pixel * 4 + 3] = 255; }
            CGContextRef context = CGBitmapContextCreate(rgba.data(), 20, 20, 8, 80, space,
                static_cast<uint32_t>(kCGImageAlphaPremultipliedLast) | static_cast<uint32_t>(kCGBitmapByteOrder32Big));
            CGImageRef image = CGBitmapContextCreateImage(context);
            CGImageDestinationAddImage(gif, image, (__bridge CFDictionaryRef)frameOptions);
            CGImageRelease(image); CGContextRelease(context);
        }
        CGColorSpaceRelease(space);
        if (!CGImageDestinationFinalize(gif)) throw std::runtime_error("Cannot encode GIF fixture");
        CFRelease(gif);
        NSString* gifUri = [@"data:image/gif;base64," stringByAppendingString:[gifData base64EncodedStringWithOptions:0]];
        NSData* gifJson = [NSJSONSerialization dataWithJSONObject:@[@{@"id": @"gif", @"uri": gifUri,
            @"x": @10, @"y": @10, @"width": @40, @"height": @40, @"layerOrder": @1}] options:0 error:nil];
        NSString* gifSpec = [[NSString alloc] initWithData:gifJson encoding:NSUTF8StringEncoding];
        prepared = prepareDocumentImageLayers(gifSpec.UTF8String, 2);
        if (!prepared || !documentImageLayersAreAnimated(prepared)) throw std::runtime_error("GIF was not recognized as animated");
        installDocumentImageLayers(&engine, prepared); releaseDocumentImageLayers(prepared);
        auto advance = [&](double time) {
            void* state = snapshotDocumentImageLayers(&engine);
            const int result = advanceDocumentImageLayers(state, time);
            if (result < 0) throw std::runtime_error("GIF frame decode failed");
            if (result > 0) installAnimatedDocumentImageLayers(&engine, state);
            releaseDocumentImageLayers(state);
            engine.renderVisibleViewport(output->getCanvas());
            if (!output->readPixels(bitmap, 0, 0)) throw std::runtime_error("GIF readback failed");
        };
        advance(10); advance(10.15);
        if (SkColorGetB(bitmap.getColor(60, 60)) < 200) throw std::runtime_error("Second GIF frame was not rendered");
        advance(10.25);
        if (SkColorGetR(bitmap.getColor(60, 60)) < 200) throw std::runtime_error("GIF did not loop to its first frame");
        std::cout << "Image layer decode and rendering passed\n";
        return 0;
    } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
} }
