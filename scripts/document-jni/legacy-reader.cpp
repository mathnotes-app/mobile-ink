#include "DrawingSerialization.h"
#include <fstream>
#include <iostream>
#include <iterator>
#include <vector>

int main(int argc, char** argv) {
    if (argc != 2) return 1;
    std::ifstream file(argv[1], std::ios::binary);
    std::vector<uint8_t> bytes((std::istreambuf_iterator<char>(file)), {});
    nativedrawing::DrawingSerialization serializer;
    std::vector<nativedrawing::Stroke> strokes;
    if (!serializer.deserialize(bytes, strokes) || strokes.size() != 2 ||
        strokes[0].points.size() != 2 || strokes[1].points.size() != 2 ||
        strokes[0].points[0].y != 1100 || strokes[1].points[0].y != 920) return 1;
    std::cout << "Legacy v4 reader preserved ink from the extended Android stream\n";
}
