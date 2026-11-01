#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>
#include <vector>
#include <include/core/SkImage.h>

namespace nativedrawing {
class SkiaDrawingEngine;

struct StrokeTilePreparation {
    struct Tile { int x, y, width, height; };
    std::unique_ptr<SkiaDrawingEngine> drawing;
    std::vector<Tile> tiles;
    std::vector<Tile> expected;
    size_t next = 0;
    Tile ready{};
    sk_sp<SkImage> pixels;
    int bucket = 0;
    uint64_t revision = 0;
    uint64_t epoch = 0;
    std::shared_ptr<const uint8_t> owner;
    const void* context = nullptr;
};
}
