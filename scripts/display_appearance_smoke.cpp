#include "DisplayAppearance.h"
#include <include/core/SkColor.h>
#include <cassert>
#include <cmath>
#include <cstdio>
#include <fstream>
#include <iterator>
#include <include/effects/SkRuntimeEffect.h>
#include <include/core/SkShader.h>
#include <include/core/SkSurface.h>
#include <include/core/SkCanvas.h>
#include <include/core/SkBitmap.h>
#include <include/core/SkPaint.h>

int main() {
    std::ifstream sourceFile("src/displayAppearance.ts");
    const std::string file{std::istreambuf_iterator<char>(sourceFile), {}};
    const auto start = file.find("String.raw`") + 11;
    const auto end = file.find("`;", start);
    assert(start >= 11 && end != std::string::npos);
    const auto compiled = SkRuntimeEffect::MakeForShader(SkString(file.substr(start, end - start)));
    if (!compiled.effect) { std::fprintf(stderr, "%s", compiled.errorText.c_str()); return 1; }
    using nativedrawing::makeDisplayColorFilter;
    assert(!makeDisplayColorFilter(false, false));
    for (auto color : {SK_ColorBLACK, SK_ColorWHITE, SK_ColorRED, SkColorSetARGB(128, 51, 102, 153), SK_ColorTRANSPARENT}) {
        const SkColor4f authored = SkColor4f::FromColor(color);
        const auto light = makeDisplayColorFilter(false, true)->filterColor4f(authored, nullptr, nullptr);
        assert(std::abs(light.fR - authored.fB) < .005);
        assert(std::abs(light.fG - authored.fG) < .005);
        assert(std::abs(light.fB - authored.fR) < .005);
        assert(std::abs(light.fA - authored.fA) < .005);
        const auto shown = makeDisplayColorFilter(true, false)->filterColor4f(authored, nullptr, nullptr);
        auto linear = [](float value) { return value <= .04045f ? value / 12.92f : std::pow((value + .055f) / 1.055f, 2.4f); };
        auto srgb = [](float value) { return value <= .0031308f ? value * 12.92f : 1.055f * std::pow(value, 1.f / 2.4f) - .055f; };
        const float shift = 1 - std::max({linear(authored.fR), linear(authored.fG), linear(authored.fB)}) - std::min({linear(authored.fR), linear(authored.fG), linear(authored.fB)});
        std::printf("%08x -> %.4f %.4f %.4f %.4f\n",color,shown.fR,shown.fG,shown.fB,shown.fA);
        if (authored.fA > 0) {
        assert(std::abs(shown.fR - (.15f + .85f * srgb(linear(authored.fR) + shift))) < .005);
        assert(std::abs(shown.fG - (.15f + .85f * srgb(linear(authored.fG) + shift))) < .005);
        assert(std::abs(shown.fB - (.15f + .85f * srgb(linear(authored.fB) + shift))) < .005);
        }
        assert(std::abs(shown.fA - authored.fA) < .005);
        sk_sp<SkShader> children[] = {SkShaders::Color(color)};
        const auto shader = compiled.effect->makeShader(nullptr, children, 1);
        assert(shader);
        auto surface = SkSurfaces::Raster(SkImageInfo::MakeN32Premul(1, 1));
        surface->getCanvas()->clear(SK_ColorTRANSPARENT);
        SkPaint paint;
        paint.setShader(shader);
        surface->getCanvas()->drawPaint(paint);
        SkBitmap pixels;
        pixels.allocN32Pixels(1, 1);
        assert(surface->readPixels(pixels.pixmap(), 0, 0));
        const auto imageColor = SkColor4f::FromColor(pixels.getColor(0, 0));
        if (authored.fA > 0) {
        assert(std::abs(imageColor.fR - shown.fR) < .015);
        assert(std::abs(imageColor.fG - shown.fG) < .015);
        assert(std::abs(imageColor.fB - shown.fB) < .015);
        } else { assert(pixels.getColor(0, 0) == SK_ColorTRANSPARENT); }
        assert(std::abs(imageColor.fA - shown.fA) < .005);
        const auto ordered = makeDisplayColorFilter(true, true)->filterColor4f(authored, nullptr, nullptr);
        assert(std::abs(ordered.fR - shown.fB) < .005);
        assert(std::abs(ordered.fB - shown.fR) < .005);
    }
    std::puts("Native ink and image shader agree on lightness, hue, alpha, and channel ordering");
}
