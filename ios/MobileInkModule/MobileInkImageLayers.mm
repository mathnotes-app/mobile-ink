#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <TargetConditionals.h>
#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#endif

#include "cpp/SkiaDrawingEngine.h"
#include <include/core/SkData.h>
#include <algorithm>
#include <cmath>
#include <memory>
#include <mutex>
#include <limits>
#include <unordered_map>
#include <vector>

namespace {
using nativedrawing::ImageLayer;

struct CacheEntry { sk_sp<SkImage> image; size_t bytes; uint64_t used; };
std::mutex imageCacheMutex;
std::unordered_map<std::string, CacheEntry> imageCache;
size_t imageCacheBytes = 0;
uint64_t imageCacheCounter = 0;
constexpr size_t kImageCacheLimit = 96 * 1024 * 1024;

sk_sp<SkImage> getCachedImage(const std::string& key) {
    std::lock_guard<std::mutex> lock(imageCacheMutex);
    auto found = imageCache.find(key);
    if (found == imageCache.end()) return nullptr;
    found->second.used = ++imageCacheCounter;
    return found->second.image;
}

sk_sp<SkImage> cacheImage(const std::string& key, sk_sp<SkImage> image, size_t bytes) {
    if (!image || bytes > kImageCacheLimit || key.size() > kImageCacheLimit - bytes) return image;
    bytes += key.size();
    std::lock_guard<std::mutex> lock(imageCacheMutex);
    auto existing = imageCache.find(key);
    if (existing != imageCache.end()) return existing->second.image;
    while (imageCacheBytes + bytes > kImageCacheLimit && !imageCache.empty()) {
        auto oldest = std::min_element(imageCache.begin(), imageCache.end(), [](const auto& a, const auto& b) {
            return a.second.used < b.second.used;
        });
        imageCacheBytes -= oldest->second.bytes;
        imageCache.erase(oldest);
    }
    imageCacheBytes += bytes;
    imageCache.emplace(key, CacheEntry{image, bytes, ++imageCacheCounter});
    return image;
}

double finiteNumber(NSDictionary* object, NSString* key, double fallback) {
    id value = object[key];
    if (!value || value == NSNull.null) return fallback;
    if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID())
        throw std::invalid_argument("Invalid image geometry");
    double number = [value doubleValue];
    if (!std::isfinite(number)) throw std::invalid_argument("Invalid image geometry");
    return number;
}

NSData* imageData(NSString* uri) {
    NSData* bytes = nil;
    if ([uri hasPrefix:@"file://"]) {
        NSURL* url = [NSURL URLWithString:uri];
        if (url.isFileURL) bytes = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:nil];
    } else if ([uri hasPrefix:@"data:image/"]) {
        NSRange marker = [uri rangeOfString:@";base64,"];
        if (marker.location != NSNotFound) {
            bytes = [[NSData alloc] initWithBase64EncodedString:[uri substringFromIndex:NSMaxRange(marker)] options:0];
        }
    }
    if (!bytes.length) throw std::runtime_error("Cannot read inserted image");
    return bytes;
}

sk_sp<SkImage> decodeImageFrame(CGImageSourceRef source, size_t frame, const std::string& key, int maxPixelSize) {
    if (auto cached = getCachedImage(key)) return cached;
    NSDictionary* options = @{
        (__bridge NSString*)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
        (__bridge NSString*)kCGImageSourceCreateThumbnailWithTransform: @YES,
        (__bridge NSString*)kCGImageSourceThumbnailMaxPixelSize: @(maxPixelSize),
    };
    CGImageRef image = CGImageSourceCreateThumbnailAtIndex(source, frame, (__bridge CFDictionaryRef)options);
    if (!image) throw std::runtime_error("Cannot decode inserted image");
    const size_t width = CGImageGetWidth(image), height = CGImageGetHeight(image);
    std::vector<uint8_t> rgba(width * height * 4);
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    if (!space) { CGImageRelease(image); throw std::runtime_error("Cannot allocate image color space"); }
    CGContextRef context = CGBitmapContextCreate(rgba.data(), width, height, 8, width * 4, space,
        static_cast<uint32_t>(kCGImageAlphaPremultipliedLast) | static_cast<uint32_t>(kCGBitmapByteOrder32Big));
    CGColorSpaceRelease(space);
    if (!context) { CGImageRelease(image); throw std::runtime_error("Cannot allocate image buffer"); }
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
    CGContextRelease(context);
    CGImageRelease(image);
    CGImageSourceRemoveCacheAtIndex(source, frame);
    auto info = SkImageInfo::Make(static_cast<int>(width), static_cast<int>(height), kRGBA_8888_SkColorType, kPremul_SkAlphaType);
    return cacheImage(key, SkImages::RasterFromData(info, SkData::MakeWithCopy(rgba.data(), rgba.size()), width * 4), rgba.size());
}

sk_sp<SkImage> loadImage(NSString* uri, int maxPixelSize) {
    const std::string key = std::string("image:") + uri.UTF8String + ":" + std::to_string(maxPixelSize);
    if (auto cached = getCachedImage(key)) return cached;
    NSData* bytes = imageData(uri);
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)bytes, nullptr);
    if (!source) throw std::runtime_error("Cannot decode inserted image");
    try {
        auto result = decodeImageFrame(source, 0, key, maxPixelSize);
        CFRelease(source);
        return result;
    } catch (...) { CFRelease(source); throw; }
}

class AnimatedGif final : public nativedrawing::AnimatedImageSource {
public:
    AnimatedGif(CGImageSourceRef source, std::string uri, int maxPixelSize)
        : source_(source), uri_(std::move(uri)), maxPixelSize_(maxPixelSize) {
        const size_t count = CGImageSourceGetCount(source_);
        if (count > 10000) throw std::invalid_argument("Animated image has too many frames");
        NSDictionary* properties = CFBridgingRelease(CGImageSourceCopyProperties(source_, nullptr));
        NSDictionary* gif = properties[(__bridge NSString*)kCGImagePropertyGIFDictionary];
        NSNumber* loops = gif[(__bridge NSString*)kCGImagePropertyGIFLoopCount];
        loopCount_ = loops ? loops.unsignedLongLongValue : 1;
        for (size_t i = 0; i < count; ++i) {
            NSDictionary* frame = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source_, i, nullptr));
            NSDictionary* info = frame[(__bridge NSString*)kCGImagePropertyGIFDictionary];
            NSNumber* value = info[(__bridge NSString*)kCGImagePropertyGIFUnclampedDelayTime];
            if (!value || value.doubleValue <= 0) value = info[(__bridge NSString*)kCGImagePropertyGIFDelayTime];
            const double raw = value ? value.doubleValue : 0.1;
            const double duration = std::isfinite(raw) && raw > 0 ? std::max(0.02, raw) : 0.1;
            totalDuration_ += duration;
            frameEnds_.push_back(totalDuration_);
        }
    }
    ~AnimatedGif() override { if (source_) CFRelease(source_); }

    int frameAt(double time, size_t currentFrame, size_t& nextFrame, sk_sp<SkImage>& image) override {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!std::isfinite(time) || frameEnds_.empty() || totalDuration_ <= 0) return -1;
        if (start_ < 0) start_ = time;
        const double elapsed = std::max(0.0, time - start_);
        const bool finished = loopCount_ && elapsed >= totalDuration_ * static_cast<double>(loopCount_);
        const double position = finished ? totalDuration_ : std::fmod(elapsed, totalDuration_);
        nextFrame = finished ? frameEnds_.size() - 1
            : std::min(frameEnds_.size() - 1, static_cast<size_t>(std::upper_bound(frameEnds_.begin(), frameEnds_.end(), position) - frameEnds_.begin()));
        if (nextFrame == currentFrame) return 0;
        try {
            const std::string suffix = ":" + std::to_string(maxPixelSize_);
            const std::string key = nextFrame == 0 ? "image:" + uri_ + suffix : "frame:" + uri_ + ":" + std::to_string(nextFrame) + suffix;
            image = decodeImageFrame(source_, nextFrame, key, maxPixelSize_);
            return image ? 1 : -1;
        } catch (...) { return -1; }
    }
private:
    CGImageSourceRef source_;
    std::string uri_;
    int maxPixelSize_;
    std::vector<double> frameEnds_;
    uint64_t loopCount_ = 1;
    double totalDuration_ = 0;
    double start_ = -1;
    std::mutex mutex_;
};

std::shared_ptr<nativedrawing::AnimatedImageSource> animationFor(NSString* uri, int maxPixelSize) {
    NSString* lower = uri.lowercaseString;
    const bool maybeGif = [lower hasPrefix:@"data:image/gif;"] ||
        ([[NSURL URLWithString:uri].pathExtension.lowercaseString isEqualToString:@"gif"]);
    if (!maybeGif) return nullptr;
    static std::mutex mutex;
    static std::unordered_map<std::string, std::weak_ptr<nativedrawing::AnimatedImageSource>> cache;
    const std::string sourceUri = uri.UTF8String;
    const std::string key = sourceUri + ":" + std::to_string(maxPixelSize);
    std::lock_guard<std::mutex> lock(mutex);
    const bool cacheable = key.size() <= 4096;
    if (cacheable) {
        auto existing = cache.find(key);
        if (existing != cache.end()) if (auto value = existing->second.lock()) return value;
    }
    NSData* data = imageData(uri);
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, nullptr);
    if (!source) throw std::runtime_error("Cannot decode animated image");
    if (CGImageSourceGetCount(source) <= 1) { CFRelease(source); return nullptr; }
    std::shared_ptr<nativedrawing::AnimatedImageSource> result;
    try { result = std::make_shared<AnimatedGif>(source, sourceUri, maxPixelSize); }
    catch (...) { CFRelease(source); throw; }
    if (cache.size() > 1024) {
        for (auto it = cache.begin(); it != cache.end();) {
            if (it->second.expired()) it = cache.erase(it); else ++it;
        }
    }
    if (cacheable) cache[key] = result;
    return result;
}

sk_sp<SkImage> renderText(NSDictionary* spec, double width, double height, double screenScale) {
#if TARGET_OS_IPHONE
    NSString* text = spec[@"text"];
    if (![text isKindOfClass:NSString.class]) throw std::invalid_argument("Invalid text layer");
    NSArray* parts = @[text, @(width), @(height), @(screenScale), spec[@"color"] ?: @0, spec[@"fontSize"] ?: @18];
    NSData* keyData = [NSJSONSerialization dataWithJSONObject:parts options:0 error:nil];
    if (!keyData) throw std::invalid_argument("Invalid text layer style");
    NSString* keyString = [[NSString alloc] initWithData:keyData encoding:NSUTF8StringEncoding];
    const std::string key = std::string("text:") + keyString.UTF8String;
    if (auto cached = getCachedImage(key)) return cached;
    const double scale = std::min(screenScale, 4096.0 / std::max(width, height));
    const size_t pixelWidth = std::max<size_t>(1, std::ceil(width * scale));
    const size_t pixelHeight = std::max<size_t>(1, std::ceil(height * scale));
    std::vector<uint8_t> rgba(pixelWidth * pixelHeight * 4, 0);
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    if (!space) throw std::runtime_error("Cannot allocate text color space");
    CGContextRef context = CGBitmapContextCreate(rgba.data(), pixelWidth, pixelHeight, 8, pixelWidth * 4, space,
        static_cast<uint32_t>(kCGImageAlphaPremultipliedLast) | static_cast<uint32_t>(kCGBitmapByteOrder32Big));
    CGColorSpaceRelease(space);
    if (!context) throw std::runtime_error("Cannot allocate text buffer");
    const double rawColor = finiteNumber(spec, @"color", 0xff000000);
    const double rawFontSize = finiteNumber(spec, @"fontSize", 18);
    if (rawColor < 0 || rawColor > UINT32_MAX || std::floor(rawColor) != rawColor || rawFontSize <= 0 || rawFontSize > 4096) {
        CGContextRelease(context);
        throw std::invalid_argument("Invalid text layer style");
    }
    const uint32_t color = static_cast<uint32_t>(rawColor);
    UIColor* foreground = [UIColor colorWithRed:((color >> 16) & 255) / 255.0
        green:((color >> 8) & 255) / 255.0 blue:(color & 255) / 255.0 alpha:((color >> 24) & 255) / 255.0];
    const CGFloat fontSize = std::max(1.0, rawFontSize) * scale;
    NSMutableParagraphStyle* paragraph = [NSMutableParagraphStyle new];
    paragraph.minimumLineHeight = fontSize * 1.25;
    paragraph.maximumLineHeight = fontSize * 1.25;
    paragraph.lineBreakMode = NSLineBreakByWordWrapping;
    NSDictionary* attributes = @{NSFontAttributeName: [UIFont systemFontOfSize:fontSize],
        NSForegroundColorAttributeName: foreground, NSParagraphStyleAttributeName: paragraph};
    CGContextTranslateCTM(context, 0, pixelHeight);
    CGContextScaleCTM(context, 1, -1);
    UIGraphicsPushContext(context);
    const CGFloat inset = 8 * scale;
    [text drawWithRect:CGRectMake(inset, inset, std::max(0.0, pixelWidth - 2 * inset),
        std::max(0.0, pixelHeight - 2 * inset))
        options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
        attributes:attributes context:nil];
    UIGraphicsPopContext();
    CGContextRelease(context);
    auto info = SkImageInfo::Make(static_cast<int>(pixelWidth), static_cast<int>(pixelHeight), kRGBA_8888_SkColorType, kPremul_SkAlphaType);
    return cacheImage(key, SkImages::RasterFromData(info, SkData::MakeWithCopy(rgba.data(), rgba.size()), pixelWidth * 4), rgba.size());
#else
    throw std::runtime_error("Text rendering requires UIKit");
#endif
}
}

extern "C" {
void clearDocumentImageCache() {
    std::lock_guard<std::mutex> lock(imageCacheMutex);
    imageCache.clear();
    imageCacheBytes = 0;
}
// Decode on a worker queue. Ownership of the returned vector belongs to the
// caller, including when the view disappears before installation.
void* prepareDocumentImageLayers(const char* json, double scale) {
    @autoreleasepool {
        try {
            if (!json || !std::isfinite(scale) || scale <= 0 || scale > 8) return nullptr;
            NSData* data = [[NSString stringWithUTF8String:json] dataUsingEncoding:NSUTF8StringEncoding];
            if (!data) throw std::invalid_argument("Invalid image list encoding");
            id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if (![root isKindOfClass:NSArray.class]) throw std::invalid_argument("Invalid image list");
            auto result = std::make_unique<std::vector<ImageLayer>>();
            result->reserve([(NSArray*)root count]);
            for (id item in (NSArray*)root) {
                if (![item isKindOfClass:NSDictionary.class]) throw std::invalid_argument("Invalid image layer");
                NSDictionary* spec = item;
                NSString* identifier = spec[@"id"], *uri = spec[@"uri"];
                const bool textLayer = [spec[@"type"] isEqual:@"text"];
                if (![identifier isKindOfClass:NSString.class] || !identifier.length ||
                    (!textLayer && ![uri isKindOfClass:NSString.class])) throw std::invalid_argument("Invalid image source");
                double order = finiteNumber(spec, @"layerOrder", 4);
                if (order < 0 || order >= 9007199254740991.0 || std::floor(order) != order)
                    throw std::invalid_argument("Invalid image layer order");
                double width = finiteNumber(spec, @"width", 240), height = finiteNumber(spec, @"height", 240);
                const double x = finiteNumber(spec, @"x", 0), y = finiteNumber(spec, @"y", 0);
                if (width <= 0 || height <= 0 || width * scale > 1000000000 || height * scale > 1000000000 ||
                    std::fabs(x * scale) > 1000000000 || std::fabs(y * scale) > 1000000000)
                    throw std::invalid_argument("Invalid image dimensions");
                NSDictionary* crop = [spec[@"crop"] isKindOfClass:NSDictionary.class] ? spec[@"crop"] : @{};
                double cropX = finiteNumber(crop, @"x", 0), cropY = finiteNumber(crop, @"y", 0);
                double cropWidth = finiteNumber(crop, @"width", 1), cropHeight = finiteNumber(crop, @"height", 1);
                if (cropX < 0 || cropY < 0 || cropWidth <= 0 || cropHeight <= 0 ||
                    cropX + cropWidth > 1.00001 || cropY + cropHeight > 1.00001)
                    throw std::invalid_argument("Invalid image crop");
                ImageLayer layer;
                layer.id = identifier.UTF8String;
                layer.layerOrder = static_cast<uint64_t>(order);
                layer.hidden = [spec[@"hidden"] boolValue];
                layer.bounds = SkRect::MakeXYWH(x * scale, y * scale, width * scale, height * scale);
                layer.crop = SkRect::MakeXYWH(cropX, cropY, std::max(0.001, cropWidth), std::max(0.001, cropHeight));
                layer.rotation = std::fmod(finiteNumber(spec, @"rotation", 0), 360);
                layer.cornerRadius = textLayer ? 0 : 4 * scale;
                const double pixelLimit = finiteNumber(spec, @"maxPixelSize", 4096);
                const double textScale = finiteNumber(spec, @"textScale", scale);
                if (pixelLimit < 32 || pixelLimit > 4096 || std::floor(pixelLimit) != pixelLimit || textScale < 0.05 || textScale > 40)
                    throw std::invalid_argument("Invalid image resolution");
                if (!layer.hidden && ![spec[@"defer"] boolValue]) {
                    layer.image = textLayer ? renderText(spec, width, height, textScale) : loadImage(uri, static_cast<int>(pixelLimit));
                    if (!layer.image) throw std::runtime_error("Cannot prepare inserted image");
                    if (!textLayer) layer.animation = animationFor(uri, static_cast<int>(pixelLimit));
                }
                result->push_back(std::move(layer));
            }
            return result.release();
        } catch (...) { return nullptr; }
    }
}

void installDocumentImageLayers(void* engine, void* prepared) {
    if (!engine || !prepared) return;
    auto* drawing = static_cast<nativedrawing::SkiaDrawingEngine*>(engine);
    auto& layers = *static_cast<std::vector<ImageLayer>*>(prepared);
    const auto old = drawing->snapshotImageLayers();
    std::unordered_map<std::string, const ImageLayer*> previous;
    for (const auto& layer : old) previous.emplace(layer.id, &layer);
    for (auto& layer : layers) {
        auto found = previous.find(layer.id);
        if (found != previous.end() && layer.animation && layer.animation == found->second->animation &&
            layer.animationFrame == 0) {
            layer.animationFrame = found->second->animationFrame;
            layer.image = found->second->image;
        }
    }
    drawing->setImageLayers(std::move(layers));
}

void installAnimatedDocumentImageLayers(void* engine, void* prepared) {
    if (engine && prepared) static_cast<nativedrawing::SkiaDrawingEngine*>(engine)->setImageLayers(
        std::move(*static_cast<std::vector<ImageLayer>*>(prepared)));
}

bool documentImageLayersAreAnimated(void* prepared) {
    if (!prepared) return false;
    const auto& layers = *static_cast<std::vector<ImageLayer>*>(prepared);
    return std::any_of(layers.begin(), layers.end(), [](const auto& layer) { return bool(layer.animation); });
}

void* snapshotDocumentImageLayers(void* engine) {
    if (!engine) return nullptr;
    try {
        auto layers = static_cast<nativedrawing::SkiaDrawingEngine*>(engine)->snapshotImageLayers();
        if (std::none_of(layers.begin(), layers.end(), [](const auto& layer) {
            return layer.animation && layer.animationVisible;
        })) return nullptr;
        return new std::vector<ImageLayer>(std::move(layers));
    } catch (...) { return nullptr; }
}

int advanceDocumentImageLayers(void* prepared, double time) {
    if (!prepared) return -1;
    bool changed = false;
    for (auto& layer : *static_cast<std::vector<ImageLayer>*>(prepared)) {
        if (!layer.animation || layer.hidden || !layer.animationVisible) continue;
        size_t nextFrame = layer.animationFrame;
        sk_sp<SkImage> image;
        const int result = layer.animation->frameAt(time, layer.animationFrame, nextFrame, image);
        if (result < 0) return -1;
        if (result > 0) {
            layer.animationFrame = nextFrame;
            layer.image = std::move(image);
            changed = true;
        }
    }
    return changed ? 1 : 0;
}

void releaseDocumentImageLayers(void* prepared) {
    delete static_cast<std::vector<ImageLayer>*>(prepared);
}
}
