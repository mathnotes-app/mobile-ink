#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d "${TMPDIR:-/tmp}/mobile-ink-pdf-export.XXXXXX")
trap 'rm -rf "$work"' EXIT
skia=${SKIA_PACKAGE_ROOT:-node_modules/@shopify/react-native-skia}
native=ios/MobileInkModule
libs="$skia/libs/apple"
python3 - "$work" "$skia" "$native" <<'PY'
import concurrent.futures
from pathlib import Path
import subprocess
import sys

work, skia, native = sys.argv[1:]
headers = f'{skia}/cpp/skia'
sources = [*Path('cpp').glob('*.cpp'), Path(native, 'MobileInkPdfInk.mm'),
           Path('scripts/pdf_vector_export_ink.cpp')]

def compile(source):
    subprocess.run(['clang++', '-std=c++20', '-O0', '-fobjc-arc', '-fno-rtti', '-I', 'cpp',
                    '-I', headers, '-I', f'{headers}/modules/pathops/include',
                    '-c', str(source), '-o', f'{work}/{source.stem}.o'], check=True)

with concurrent.futures.ThreadPoolExecutor(max_workers=4) as workers:
    list(workers.map(compile, sources))
PY
swiftc -swift-version 5 "$native/MobileInkPdfWriter.swift" scripts/pdf_vector_export_smoke.swift \
  "$work"/*.o "$libs/libskia.xcframework/macos-arm64_x86_64/libskia.a" \
  "$libs/libpathops.xcframework/macos-arm64_x86_64/libpathops.a" \
  -lc++ -framework Metal -framework ApplicationServices -framework CoreGraphics \
  -framework CoreText -framework Foundation -framework QuartzCore -framework ImageIO -o "$work/verify"
"$work/verify"
