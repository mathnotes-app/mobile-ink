#import <Foundation/Foundation.h>
#import <React/RCTBridgeModule.h>
#import <React/RCTBridge.h>
#include "cpp/ContinuousDocumentPages.h"
#include "cpp/DrawingSerialization.h"
#include <cmath>
#include <memory>
#include <stdexcept>

namespace {
using namespace nativedrawing;
ContinuousDocumentPage decodePage(NSString* payload) {
    if (![payload isKindOfClass:NSString.class]) throw std::invalid_argument("Invalid page payload type");
    NSError* error = nil;
    NSData* jsonData = [payload dataUsingEncoding:NSUTF8StringEncoding];
    if (!jsonData) throw std::invalid_argument("Invalid UTF-8 page payload");
    id root = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&error];
    if (error || ![root isKindOfClass:NSDictionary.class] || ![root[@"pages"] isKindOfClass:NSDictionary.class])
        throw std::invalid_argument("Invalid page payload JSON");
    NSDictionary* encodedPages = root[@"pages"];
    if (encodedPages.count > 1 || (encodedPages.count == 1 && !encodedPages[@"0"]))
        throw std::invalid_argument("Expected a single native page payload");
    ContinuousDocumentPage page;
    if (encodedPages.count) {
        id encoded = encodedPages[@"0"];
        if (![encoded isKindOfClass:NSString.class]) throw std::invalid_argument("Invalid drawing encoding");
        NSData* bytes = [[NSData alloc] initWithBase64EncodedString:encoded options:0];
        if (!bytes.length) throw std::invalid_argument("Invalid drawing bytes");
        const auto* begin = static_cast<const uint8_t*>(bytes.bytes);
        DrawingSerialization serializer;
        if (!serializer.deserialize(std::vector<uint8_t>(begin, begin + bytes.length), page.strokes))
            throw std::invalid_argument("Invalid serialized drawing");
    }
    id order = root[@"documentStrokeOrder"];
    if (order) {
        if (![order isKindOfClass:NSArray.class]) throw std::invalid_argument("Invalid document stroke order");
        for (id value in (NSArray*)order) {
            if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID())
                throw std::invalid_argument("Invalid document stroke order value");
            double number = [value doubleValue];
            if (!std::isfinite(number) || number < 0 || number > 9007199254740991.0 || std::floor(number) != number)
                throw std::invalid_argument("Invalid document stroke order range");
            page.order.push_back(static_cast<uint64_t>(number));
        }
        if (page.order.size() != page.strokes.size()) throw std::invalid_argument("Document stroke order count mismatch");
    }
    return page;
}
NSString* encodePage(const ContinuousDocumentPage& page, bool includeOrder) {
    NSMutableDictionary* root = [NSMutableDictionary dictionary];
    if (page.strokes.empty()) root[@"pages"] = @{};
    else {
        DrawingSerialization serializer;
        const auto bytes = serializer.serialize(page.strokes);
        NSData* data = [NSData dataWithBytes:bytes.data() length:bytes.size()];
        root[@"pages"] = @{@"0": [data base64EncodedStringWithOptions:0]};
    }
    if (includeOrder) {
        NSMutableArray* order = [NSMutableArray arrayWithCapacity:page.order.size()];
        for (uint64_t value : page.order) [order addObject:@(value)];
        root[@"documentStrokeOrder"] = order;
    }
    NSError* error = nil;
    NSData* json = [NSJSONSerialization dataWithJSONObject:root options:0 error:&error];
    if (error || !json) throw std::runtime_error("Cannot encode document page");
    return [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
}
}

@protocol MobileInkDocumentLoader <NSObject>
- (void)loadPreparedDrawing:(NSNumber*)viewTag snapshot:(void*)snapshot
                   callback:(RCTResponseSenderBlock)callback;
// Main thread only; returns an owned std::vector<Stroke>* or NULL.
- (void*)takeDrawingSnapshot:(NSNumber*)viewTag;
@end

@interface MobileInkDocumentBridge : NSObject <RCTBridgeModule>
@end
// Skia archives can supply exception RTTI that prevents std::exception matching.
// Keep catch-all rejection at every exported C++ boundary; never let an invalid
// notebook unwind through React Native or resolve it as an empty document.
@implementation MobileInkDocumentBridge
RCT_EXPORT_MODULE()
@synthesize bridge = _bridge;
+ (BOOL)requiresMainQueueSetup { return NO; }
- (dispatch_queue_t)methodQueue { return dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0); }
RCT_EXPORT_METHOD(composeDocument:(NSArray<NSString*>*)payloads
                  pageHeight:(double)pageHeight
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    try {
        std::vector<nativedrawing::ContinuousDocumentPage> pages;
        pages.reserve(payloads.count);
        for (NSString* payload in payloads) pages.push_back(decodePage(payload));
        nativedrawing::ContinuousDocumentPage document;
        document.strokes = nativedrawing::composeContinuousDocument(pages, pageHeight);
        resolve(encodePage(document, false));
    } catch (const std::exception& error) {
        reject(@"DOCUMENT_COMPOSE_FAILED", [NSString stringWithUTF8String:error.what()], nil);
    } catch (...) {
        reject(@"DOCUMENT_COMPOSE_FAILED", @"Unable to process drawing data", nil);
    }
}
// Decode and compose off the UI thread, then swap the prepared geometry on the
// main queue. No combined JSON/base64 encoding or second decode is necessary.
RCT_EXPORT_METHOD(loadDocument:(nonnull NSNumber*)viewTag
                  payloads:(NSArray<NSString*>*)payloads
                  pageHeight:(double)pageHeight
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    try {
        std::vector<nativedrawing::ContinuousDocumentPage> pages;
        pages.reserve(payloads.count);
        for (NSString* payload in payloads) pages.push_back(decodePage(payload));
        auto* prepared = new std::vector<nativedrawing::Stroke>(
            nativedrawing::composeContinuousDocument(pages, pageHeight));
        dispatch_async(dispatch_get_main_queue(), ^{
            id<MobileInkDocumentLoader> loader = (id)[self.bridge moduleForName:@"MobileInkCanvasViewManager"];
            if (![loader respondsToSelector:@selector(loadPreparedDrawing:snapshot:callback:)]) {
                reject(@"DOCUMENT_LOAD_UNAVAILABLE", @"MobileInkCanvasViewManager is unavailable", nil);
            } else {
                [loader loadPreparedDrawing:viewTag snapshot:prepared callback:^(NSArray* result) {
                    id error = result.count > 0 ? result[0] : nil;
                    if ([error isKindOfClass:NSString.class]) {
                        reject(@"DOCUMENT_LOAD_FAILED", error, nil);
                    } else {
                        resolve(@(result.count > 1 && [result[1] isKindOfClass:NSNumber.class] && [result[1] boolValue]));
                    }
                }];
            }
            // Swapping puts the old strokes into prepared. Release those on the
            // background queue, including when a view disappeared before handoff.
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                delete prepared;
            });
        });
    } catch (const std::exception& error) {
        reject(@"DOCUMENT_LOAD_FAILED", [NSString stringWithUTF8String:error.what()], nil);
    } catch (...) {
        reject(@"DOCUMENT_LOAD_FAILED", @"Unable to process drawing data", nil);
    }
}
// Copy strokes on the main thread, then partition and encode that copy on this
// module's background queue. Unlike getBase64Data + partitionDocument, the
// whole document is never serialized, sent through JavaScript, and decoded.
RCT_EXPORT_METHOD(captureDocument:(nonnull NSNumber*)viewTag
                  pageCount:(NSInteger)pageCount
                  pageHeight:(double)pageHeight
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    if (pageCount <= 0 || pageCount > 100000) {
        reject(@"DOCUMENT_CAPTURE_FAILED", @"Invalid document page count", nil);
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        id<MobileInkDocumentLoader> loader = (id)[self.bridge moduleForName:@"MobileInkCanvasViewManager"];
        if (![loader respondsToSelector:@selector(takeDrawingSnapshot:)]) {
            reject(@"DOCUMENT_CAPTURE_FAILED", @"MobileInkCanvasViewManager is unavailable", nil);
            return;
        }
        auto* strokes = static_cast<std::vector<nativedrawing::Stroke>*>([loader takeDrawingSnapshot:viewTag]);
        if (!strokes) {
            reject(@"DOCUMENT_CAPTURE_FAILED", @"View not found", nil);
            return;
        }
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            std::unique_ptr<std::vector<nativedrawing::Stroke>> owned(strokes);
            try {
                const auto pages = nativedrawing::partitionContinuousDocument(*owned, (int)pageCount, pageHeight);
                NSMutableArray* result = [NSMutableArray arrayWithCapacity:pages.size()];
                for (const auto& page : pages) [result addObject:encodePage(page, true)];
                resolve(result);
            } catch (const std::exception& error) {
                reject(@"DOCUMENT_CAPTURE_FAILED", [NSString stringWithUTF8String:error.what()], nil);
            } catch (...) {
                reject(@"DOCUMENT_CAPTURE_FAILED", @"Unable to process drawing data", nil);
            }
        });
    });
}
RCT_EXPORT_METHOD(partitionDocument:(NSString*)payload
                  pageCount:(NSInteger)pageCount
                  pageHeight:(double)pageHeight
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    try {
        if (pageCount <= 0 || pageCount > 100000) throw std::invalid_argument("Invalid document page count");
        auto document = decodePage(payload);
        const auto pages = nativedrawing::partitionContinuousDocument(document.strokes, (int)pageCount, pageHeight);
        NSMutableArray* result = [NSMutableArray arrayWithCapacity:pages.size()];
        for (const auto& page : pages) [result addObject:encodePage(page, true)];
        resolve(result);
    } catch (const std::exception& error) {
        reject(@"DOCUMENT_PARTITION_FAILED", [NSString stringWithUTF8String:error.what()], nil);
    } catch (...) {
        reject(@"DOCUMENT_PARTITION_FAILED", @"Unable to process drawing data", nil);
    }
}
RCT_EXPORT_METHOD(projectDocumentPages:(NSArray<NSString*>*)payloads
                  pageHeight:(double)pageHeight
                  pageIndices:(NSArray<NSNumber*>*)pageIndices
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    try {
        std::vector<nativedrawing::ContinuousDocumentPage> pages;
        for (NSString* payload in payloads) pages.push_back(decodePage(payload));
        std::vector<int> indices;
        for (NSNumber* value in pageIndices) {
            if (![value isKindOfClass:NSNumber.class] || !std::isfinite(value.doubleValue) ||
                value.doubleValue < 0 || value.doubleValue >= payloads.count ||
                std::floor(value.doubleValue) != value.doubleValue)
                throw std::invalid_argument("Invalid export page index");
            indices.push_back(value.intValue);
        }
        const auto projected = nativedrawing::projectContinuousDocumentPages(pages, pageHeight, indices);
        NSMutableArray* result = [NSMutableArray arrayWithCapacity:projected.size()];
        for (const auto& strokes : projected) {
            nativedrawing::ContinuousDocumentPage page;
            page.strokes = strokes;
            [result addObject:encodePage(page, false)];
        }
        resolve(result);
    } catch (const std::exception& error) {
        reject(@"DOCUMENT_EXPORT_FAILED", [NSString stringWithUTF8String:error.what()], nil);
    } catch (...) {
        reject(@"DOCUMENT_EXPORT_FAILED", @"Unable to process drawing data", nil);
    }
}
@end
