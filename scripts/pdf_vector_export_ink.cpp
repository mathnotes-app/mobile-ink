#include "DrawingSerialization.h"

#include <fstream>
#include <string>
#include <vector>

extern "C" bool writePdfExportInkFixture(const char* destination, bool textured) {
    nativedrawing::Stroke stroke;
    stroke.toolType = textured ? "crayon" : "pen";
    stroke.paint.setColor(SK_ColorBLACK);
    stroke.paint.setStrokeWidth(18);
    stroke.paint.setStyle(SkPaint::kStroke_Style);
    for (int x = 70; x <= 510; x += 5) {
        nativedrawing::Point point{};
        point.x = x;
        point.y = 218;
        point.pressure = 1;
        point.altitude = 1.57;
        point.calculatedWidth = 18;
        point.timestamp = x;
        stroke.points.push_back(point);
    }
    stroke.erasedBy = {{260, 218, 28}};
    auto bytes = nativedrawing::DrawingSerialization().serialize({stroke});
    std::ofstream file(destination, std::ios::binary);
    return bool(file.write(reinterpret_cast<const char*>(bytes.data()), bytes.size()));
}
