#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
java_root=$(/usr/libexec/java_home -v 17)
work=$(mktemp -d /private/tmp/mobile-ink-document-jni.XXXXXX)
trap 'rm -rf "$work"' EXIT
skia=node_modules/@shopify/react-native-skia
flags=(-std=c++17 -I cpp -I "$skia/cpp/skia" -I "$java_root/include" -I "$java_root/include/darwin")
sources=(cpp/ContinuousDocumentPages.cpp cpp/DrawingSerialization.cpp cpp/DrawingTypes.cpp cpp/ShapeRecognition.cpp)
libs=("$skia/libs/apple/libskia.xcframework/macos-arm64_x86_64/libskia.a" "$skia/libs/apple/libpathops.xcframework/macos-arm64_x86_64/libpathops.a" -framework ApplicationServices -framework CoreFoundation -framework CoreGraphics -framework CoreText -framework Foundation -framework QuartzCore)
clang++ "${flags[@]}" -dynamiclib android/src/main/cpp/document_bridge.cpp "${sources[@]}" "${libs[@]}" -o "$work/libmobileink.dylib"
clang++ "${flags[@]}" scripts/document-jni/fixture.cpp "${sources[@]}" "${libs[@]}" -o "$work/fixture"
"$work/fixture" "$work/document.bin"
if [[ -n "${DOCUMENT_CODEC_CLASSPATH:-}" ]]; then
    "$java_root/bin/javac" -cp "$DOCUMENT_CODEC_CLASSPATH" -d "$work/classes" scripts/document-jni/DocumentCodecSmoke.java
    classpath="$work/classes:$DOCUMENT_CODEC_CLASSPATH"
else
    "$java_root/bin/javac" -d "$work/classes" scripts/document-jni/*.java
    classpath="$work/classes"
fi
"$java_root/bin/java" -Xcheck:jni -Djava.library.path="$work" -cp "$classpath" com.mathnotes.mobileink.DocumentCodecSmoke "$work/libmobileink.dylib" "$work/document.bin"
