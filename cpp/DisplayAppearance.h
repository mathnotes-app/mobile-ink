#pragma once

#include <include/core/SkColorFilter.h>

namespace nativedrawing {

// Presentation only. Serialized paints and export rendering retain authored colors.
sk_sp<SkColorFilter> makeDisplayColorFilter(bool dark, bool swapRedBlue);

}
