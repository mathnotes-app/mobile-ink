#include "DrawingSerialization.h"
#include "ContinuousDocumentPages.h"
#include <cassert>
#include <fstream>
using namespace nativedrawing;
int main(int argc, char** argv) {
    if (argc != 2) return 1;
    std::vector<Stroke> strokes;
    for (const auto ends : {std::pair<float, float>{1100, 900}, {920, 1080}}) {
        Stroke stroke;
        stroke.paint.setColor(SK_ColorBLACK);
        stroke.paint.setStrokeWidth(4);
        stroke.paint.setStyle(SkPaint::kStroke_Style);
        stroke.paint.setAntiAlias(true);
        for (float y : {ends.first, ends.second}) {
            Point point{};
            point.x = 100; point.y = y; point.pressure = 1; point.calculatedWidth = 4;
            stroke.points.push_back(point);
        }
        strokes.push_back(stroke);
    }
    // A copied owner page must receive local targets before being inserted as
    // legacy data. Reusing its original document IDs would collide on compose.
    auto erased = strokes;
    erased[1].affectedStrokeIndices.insert(1);
    auto pages = partitionContinuousDocument(erased, 2, 1000);
    auto localCopy = composeContinuousDocument({pages[0]}, 1000);
    assert(localCopy.size() == 1);
    assert(localCopy[0].affectedStrokeIndices.count(0) == 1);
    ContinuousDocumentPage copy;
    copy.strokes = localCopy;
    pages.insert(pages.begin() + 1, copy);
    const auto duplicated = composeContinuousDocument(pages, 1000);
    assert(duplicated.size() == 3);
    assert(duplicated[1].affectedStrokeIndices.count(1) == 1);
    assert(duplicated[2].affectedStrokeIndices.count(2) == 1);
    assert(duplicated[2].affectedStrokeIndices.count(1) == 0);
    assert(duplicated[2].points.back().y > 2000); // full overflow retained
    DrawingSerialization serializer;
    const auto bytes = serializer.serialize(strokes);
    std::ofstream output(argv[1], std::ios::binary);
    output.write(reinterpret_cast<const char*>(bytes.data()), bytes.size());
    return output ? 0 : 1;
}
