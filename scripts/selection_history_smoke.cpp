// Regression coverage for selection state across undo/redo/clear.
//
// Selection, the object eraser and selection transforms remember strokes by
// their index in the engine's stroke list. Undo/redo/clear rebuild that list,
// so any index kept across them can point at a different stroke or past the
// end. Shipped builds crashed (uncaught std::length_error from a size_t
// underflow in deleteSelection) after: lasso two strokes -> Undo -> Delete,
// and could delete a stroke the user never selected. These assertions drive
// the shared C++ engine directly (raster surfaces, no GPU context).

#include <iostream>

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

// A slightly wavy horizontal stroke, like real pen input (a perfectly flat
// stroke has empty bounds and is skipped by lasso rejection).
void drawStroke(SkiaDrawingEngine& engine, float y) {
  engine.setTool("pen");
  engine.touchBegan(100.0f, y, 1.0f);
  for (int i = 1; i <= 20; ++i) {
    engine.touchMoved(100.0f + i * 10.0f, y + ((i % 2) ? 6.0f : -6.0f), 1.0f);
  }
  engine.touchEnded(0);
}

void lasso(SkiaDrawingEngine& engine, float left, float top, float right, float bottom) {
  const float corners[5][2] = {{left, top}, {right, top}, {right, bottom}, {left, bottom}, {left, top}};
  engine.setTool("select");
  engine.touchBegan(corners[0][0], corners[0][1], 1.0f);
  for (int edge = 0; edge < 4; ++edge) {
    for (int step = 1; step <= 40; ++step) {
      const float t = step / 40.0f;
      engine.touchMoved(
          corners[edge][0] + (corners[edge + 1][0] - corners[edge][0]) * t,
          corners[edge][1] + (corners[edge + 1][1] - corners[edge][1]) * t,
          1.0f);
    }
  }
  engine.touchEnded(0);
}

bool strokeAt(SkiaDrawingEngine& engine, float y) {
  const bool hit = engine.selectStrokeAt(150.0f, y);
  engine.clearSelection();
  return hit;
}

void undoThenDeleteDoesNotCrash() {
  SkiaDrawingEngine engine(820, 1061);
  drawStroke(engine, 200.0f);
  drawStroke(engine, 260.0f);
  lasso(engine, 50.0f, 150.0f, 400.0f, 320.0f);
  check(engine.getSelectionCount() == 2, "lasso selects both strokes");

  engine.undo();
  check(engine.getSelectionCount() == 0, "undo drops the selection");

  try {
    engine.deleteSelection();
  } catch (const std::exception& error) {
    std::cerr << "FAIL: deleteSelection threw after undo: " << error.what() << std::endl;
    ++g_failures;
  }
  check(strokeAt(engine, 200.0f), "delete after undo leaves the surviving stroke");
}

void undoNeverRetargetsSelection() {
  SkiaDrawingEngine engine(820, 1061);
  drawStroke(engine, 200.0f);  // A
  drawStroke(engine, 400.0f);  // B
  drawStroke(engine, 600.0f);  // C
  engine.setTool("select");
  engine.selectStrokeAt(150.0f, 200.0f);
  engine.deleteSelection();  // delete A
  engine.selectStrokeAt(150.0f, 600.0f);  // select C (index 1 now)

  engine.undo();  // A returns at index 0; index 1 is now B
  check(engine.getSelectionCount() == 0, "undo drops a selection whose indices shifted");
  engine.deleteSelection();
  check(strokeAt(engine, 200.0f) && strokeAt(engine, 400.0f) && strokeAt(engine, 600.0f),
        "delete after undo never removes an unselected stroke");
}

void redoAndClearDropSelection() {
  SkiaDrawingEngine engine(820, 1061);
  drawStroke(engine, 200.0f);
  drawStroke(engine, 400.0f);
  engine.undo();
  engine.selectStrokeAt(150.0f, 200.0f);
  check(engine.getSelectionCount() == 1, "stroke selected before redo");
  engine.redo();
  check(engine.getSelectionCount() == 0, "redo drops the selection");

  engine.selectStrokeAt(150.0f, 200.0f);
  engine.clear();
  check(engine.getSelectionCount() == 0, "clear drops the selection");
  engine.deleteSelection();
  engine.undo();  // undo the clear, not a phantom delete
  check(strokeAt(engine, 200.0f) && strokeAt(engine, 400.0f), "undo after clear restores every stroke");
}

void undoCancelsInFlightTransform() {
  SkiaDrawingEngine engine(820, 1061);
  drawStroke(engine, 200.0f);
  drawStroke(engine, 600.0f);
  engine.selectStrokeAt(150.0f, 200.0f);
  engine.beginSelectionTransform(0);
  engine.updateSelectionTransform(400.0f, 450.0f);
  engine.undo();  // removes the second stroke; the uncommitted transform must not leak
  check(engine.getSelectionCount() == 0, "undo during a transform drops the selection");
  check(strokeAt(engine, 200.0f), "undo during a transform restores the stroke's original geometry");
  check(!strokeAt(engine, 600.0f), "undo during a transform still reverts the last change");
}

void undoDropsPendingObjectErase() {
  SkiaDrawingEngine engine(820, 1061);
  drawStroke(engine, 200.0f);  // A
  drawStroke(engine, 400.0f);  // B
  engine.selectStrokeAt(150.0f, 200.0f);
  engine.deleteSelection();  // strokes: [B]

  engine.setToolWithParams("eraser", 20.0f, 0x000000, "object");
  engine.touchBegan(150.0f, 400.0f, 1.0f);
  engine.touchMoved(160.0f, 400.0f, 1.0f);  // B (index 0) marked for deletion
  engine.undo();  // A returns at index 0
  engine.touchEnded(0);
  check(strokeAt(engine, 200.0f), "object erase pending across undo never removes another stroke");
}

void objectEraseDropsLiveSelection() {
  SkiaDrawingEngine engine(820, 1061);
  drawStroke(engine, 200.0f);  // A
  drawStroke(engine, 400.0f);  // B
  engine.selectStrokeAt(150.0f, 400.0f);  // select B (index 1)

  // A host that keeps the selection while object-erasing A shifts B to 0.
  engine.setToolWithParams("eraser", 20.0f, 0x000000, "object");
  engine.touchBegan(150.0f, 200.0f, 1.0f);
  engine.touchMoved(160.0f, 200.0f, 1.0f);
  engine.touchEnded(0);
  check(engine.getSelectionCount() == 0, "object erase drops a selection whose indices shifted");
  engine.deleteSelection();
  check(strokeAt(engine, 400.0f), "delete after object erase never removes an unselected stroke");
}

}  // namespace

int main() {
  undoThenDeleteDoesNotCrash();
  undoNeverRetargetsSelection();
  redoAndClearDropSelection();
  undoCancelsInFlightTransform();
  undoDropsPendingObjectErase();
  objectEraseDropsLiveSelection();

  if (g_failures == 0) {
    std::cout << "Selection history smoke tests passed" << std::endl;
    return 0;
  }
  std::cerr << g_failures << " selection history smoke test(s) failed" << std::endl;
  return 1;
}
