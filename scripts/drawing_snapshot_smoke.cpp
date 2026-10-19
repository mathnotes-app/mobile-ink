// Autosave copies strokes on the UI thread and encodes the copy off-thread so
// pen input is never blocked by serialization. The copy must encode exactly
// like the live engine and must not observe strokes drawn after it was taken.

#include <iostream>
#include <chrono>
#include <thread>

#include "../cpp/DrawingSerialization.h"
#include "../cpp/SkiaDrawingEngine.h"

using namespace nativedrawing;

namespace {

int g_failures = 0;

void check(bool condition, const char* message) {
  if (!condition) {
    std::cerr << "FAIL: " << message << std::endl;
    ++g_failures;
  }
}

void drawStroke(SkiaDrawingEngine& engine, float y) {
  engine.setTool("pen");
  engine.touchBegan(100.0f, y, 1.0f);
  for (int i = 1; i <= 20; ++i) {
    engine.touchMoved(100.0f + i * 10.0f, y + ((i % 2) ? 6.0f : -6.0f), 1.0f);
  }
  engine.touchEnded(0);
}

void snapshotEncodesLikeLiveEngine() {
  SkiaDrawingEngine engine(820, 1061);
  drawStroke(engine, 200.0f);
  drawStroke(engine, 300.0f);
  engine.setTool("eraser");
  engine.touchBegan(150.0f, 200.0f, 1.0f);
  engine.touchMoved(160.0f, 205.0f, 1.0f);
  engine.touchEnded(0);
  const auto live = engine.serializeDrawing();
  const auto snapshot = engine.snapshotDrawing();
  DrawingSerialization serializer;
  check(serializer.serialize(snapshot) == live, "snapshot encoding differs from live serialization");
}

void snapshotIgnoresLaterStrokes() {
  SkiaDrawingEngine engine(820, 1061);
  drawStroke(engine, 200.0f);
  const auto before = engine.serializeDrawing();
  const auto snapshot = engine.snapshotDrawing();
  std::vector<uint8_t> encoded;
  // Encode on another thread while the engine keeps receiving input.
  std::thread encoder([&] { DrawingSerialization serializer; encoded = serializer.serialize(snapshot); });
  for (int i = 0; i < 20; ++i) drawStroke(engine, 300.0f + i * 20.0f);
  encoder.join();
  check(encoded == before, "snapshot observed strokes drawn after capture");
  check(engine.serializeDrawing() != before, "live engine lost strokes drawn after capture");
}

void denseSnapshotKeepsNewInputIndependent() {
  SkiaDrawingEngine engine(820, 106100, true);
  for (int page = 0; page < 100; ++page)
    for (int stroke = 0; stroke < 200; ++stroke)
      drawStroke(engine, page * 1061.0f + 20 + stroke * 4.0f);
  const auto start = std::chrono::steady_clock::now();
  const auto snapshot = engine.snapshotDrawing();
  const auto captured = std::chrono::steady_clock::now();
  std::vector<uint8_t> encoded;
  std::thread writer([&] { DrawingSerialization serializer; encoded = serializer.serialize(snapshot); });
  for (int stroke = 0; stroke < 24; ++stroke) drawStroke(engine, 200 + stroke * 20);
  writer.join();
  std::vector<Stroke> decoded;
  DrawingSerialization serializer;
  check(serializer.deserialize(encoded, decoded), "dense save cannot be decoded");
  check(decoded.size() == 20000, "background encoding changed its captured revision");
  check(engine.snapshotDrawing().size() == 20024, "drawing during dense save lost new input");
  std::cout << "Dense UI-thread snapshot ms: "
    << std::chrono::duration<double, std::milli>(captured - start).count() << std::endl;
}

}  // namespace

int main() {
  snapshotEncodesLikeLiveEngine();
  snapshotIgnoresLaterStrokes();
  denseSnapshotKeepsNewInputIndependent();
  if (g_failures == 0) {
    std::cout << "Drawing snapshot smoke tests passed" << std::endl;
    return 0;
  }
  std::cerr << g_failures << " drawing snapshot smoke test(s) failed" << std::endl;
  return 1;
}
