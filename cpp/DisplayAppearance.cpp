#include "DisplayAppearance.h"
#include <array>
#include <cstdio>

#include <include/effects/SkRuntimeEffect.h>

namespace nativedrawing {

sk_sp<SkColorFilter> makeDisplayColorFilter(bool dark, bool swapRedBlue) {
    if (!dark && !swapRedBlue) return nullptr;
    static const auto swap = SkColorFilters::Matrix(std::array<float, 20>{
        0, 0, 1, 0, 0,
        0, 1, 0, 0, 0,
        1, 0, 0, 0, 0,
        0, 0, 0, 1, 0,
    }.data());
    if (!dark) return swap;
    // Use full-precision RGB arithmetic. SkHighContrastFilter's HSL round trip
    // drifts at saturated colors on some Metal GPUs (blue became green-tinted).
    static const auto lightness = [] {
        const auto result = SkRuntimeEffect::MakeForColorFilter(SkString(R"(
            float3 toLinear(float3 c) {
                return mix(c / 12.92, pow((c + 0.055) / 1.055, float3(2.4)), step(float3(0.04045), c));
            }
            float3 toSrgb(float3 c) {
                return mix(c * 12.92, 1.055 * pow(c, float3(1.0 / 2.4)) - 0.055, step(float3(0.0031308), c));
            }
            float4 main(float4 color) {
                if (color.a <= 0.0001) return color;
                float3 rgb = toLinear(clamp(color.rgb / color.a, 0.0, 1.0));
                float shift = 1.0 - max(rgb.r, max(rgb.g, rgb.b)) - min(rgb.r, min(rgb.g, rgb.b));
                return float4((0.15 + 0.85 * toSrgb(clamp(rgb + shift, 0.0, 1.0))) * color.a, color.a);
            }
        )"));
        if (result.effect) return result.effect->makeColorFilter(nullptr);
        std::fprintf(stderr, "[MobileInk] Could not compile display contrast: %s\n", result.errorText.c_str());
        // Retain readable contrast if a platform cannot compile runtime filters.
        return SkColorFilters::Matrix(std::array<float, 20>{
            -.85f, 0, 0, 0, 1,
            0, -.85f, 0, 0, 1,
            0, 0, -.85f, 0, 1,
            0, 0, 0, 1, 0,
        }.data());
    }();
    static const auto darkSwap = SkColorFilters::Compose(lightness, swap);
    return swapRedBlue ? darkSwap : lightness;
}

}
