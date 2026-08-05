// Regression coverage for the eraser-cursor lifecycle (GitHub issue #4).
//
// The eraser cursor is a native-only overlay whose visibility must be cleared
// whenever the active tool/mode is not the pixel eraser, and whenever the
// engine is reset for reuse by the pooled continuous canvas. These assertions
// exercise the shared C++ engine directly (raster surfaces, no GPU context),
// covering tool/mode switching and the pooled-engine reassignment path.

#include <cstdint>
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

}  // namespace

int main() {
  SkiaDrawingEngine engine(500, 500);

  // Switching to a non-eraser tool hides a visible cursor.
  engine.setEraserCursor(10.0f, 10.0f, 5.0f, true);
  check(engine.isEraserCursorVisible(), "cursor visible after setEraserCursor");
  engine.setToolWithParams("pen", 3.0f, 0x000000, "pixel");
  check(!engine.isEraserCursorVisible(), "switching to pen hides the cursor");

  // The pixel eraser is the one tool that keeps the cursor visible.
  engine.setEraserCursor(10.0f, 10.0f, 5.0f, true);
  engine.setToolWithParams("eraser", 20.0f, 0x000000, "pixel");
  check(engine.isEraserCursorVisible(), "pixel eraser keeps the cursor");

  // A non-pixel (object) eraser has no cursor overlay.
  engine.setEraserCursor(10.0f, 10.0f, 5.0f, true);
  engine.setToolWithParams("eraser", 20.0f, 0x000000, "object");
  check(!engine.isEraserCursorVisible(), "object eraser hides the cursor");

  // Empty/absent mode normalizes to pixel eraser and keeps the cursor.
  engine.setEraserCursor(10.0f, 10.0f, 5.0f, true);
  engine.setToolWithParams("eraser", 20.0f, 0x000000, "");
  check(engine.isEraserCursorVisible(), "empty mode normalizes to pixel eraser");

  // Pooled-engine reassignment path: clear() resets transient cursor state so a
  // reused engine never renders the previous page's cursor.
  engine.setEraserCursor(10.0f, 10.0f, 5.0f, true);
  engine.clear();
  check(!engine.isEraserCursorVisible(), "clear() hides the cursor (reassignment)");

  if (g_failures == 0) {
    std::cout << "Eraser cursor smoke tests passed" << std::endl;
    return 0;
  }
  std::cerr << g_failures << " eraser cursor smoke test(s) failed" << std::endl;
  return 1;
}
