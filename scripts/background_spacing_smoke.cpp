#include "../cpp/BackgroundRenderer.h"
#include <include/core/SkImageInfo.h>
#include <include/core/SkPixmap.h>
#include <include/core/SkSurface.h>
#include <iostream>
#include <stdexcept>

static int countLines(const char* type, int scale = 1) {
  const int width = 820 * scale, height = 1061 * scale;
  auto surface = SkSurfaces::Raster(SkImageInfo::MakeN32Premul(width, height));
  if (!surface) throw std::runtime_error("Could not create raster surface");
  nativedrawing::BackgroundRenderer renderer;
  renderer.drawBackground(surface->getCanvas(), type, width, height);
  SkPixmap pixels;
  if (!surface->peekPixels(&pixels)) throw std::runtime_error("Could not read raster pixels");
  int count = 0;
  bool previous = false;
  for (int y = 1; y < height - 1; ++y) {
    const bool line = SkColorGetR(pixels.getColor(width / 2, y)) < 250;
    if (line && !previous) ++count;
    previous = line;
  }
  return count;
}

int main() {
  const int standard = countLines("lined");
  const int narrow = countLines("lined-narrow");
  const int compact = countLines("lined-compact");
  const int plain = countLines("plain");
  std::cout << "Line counts: standard=" << standard << " narrow=" << narrow
            << " compact=" << compact << " plain=" << plain << '\n';
  const int narrow2x = countLines("lined-narrow", 2);
  const int compact2x = countLines("lined-compact", 2);
  const int custom = countLines("lined-custom-47");
  const int custom2x = countLines("lined-custom-47", 2);
  return standard > 0 && standard < narrow && narrow < compact && plain == 0 &&
    narrow == narrow2x && compact == compact2x && custom == 46 && custom == custom2x &&
    countLines("lined-custom-99") == 0 && countLines("lined-custom-1x") == 0 ? 0 : 1;
}
