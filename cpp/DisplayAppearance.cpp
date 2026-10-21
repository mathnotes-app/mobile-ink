#include "DisplayAppearance.h"
#include <array>

#include <include/effects/SkHighContrastFilter.h>

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
    static const auto inverted = SkHighContrastFilter::Make({
        false, SkHighContrastConfig::InvertStyle::kInvertLightness, 0,
    });
    // Map authored white onto the same charcoal as the native paper view.
    // Keeping black at white preserves the full contrast of ordinary ink.
    static const auto lightness = SkColorFilters::Compose(SkColorFilters::Matrix(std::array<float, 20>{
        .85f, 0, 0, 0, .15f,
        0, .85f, 0, 0, .15f,
        0, 0, .85f, 0, .15f,
        0, 0, 0, 1, 0,
    }.data()), inverted);
    static const auto darkSwap = SkColorFilters::Compose(lightness, swap);
    return swapRedBlue ? darkSwap : lightness;
}

}
