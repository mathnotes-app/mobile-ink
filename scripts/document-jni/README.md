# Document JNI boundary check

Run `bash scripts/test-document-jni.sh` on macOS with Java 17 and installed Skia dependencies. It compiles the production `android/src/main/cpp/document_bridge.cpp` against the shared C++ codec and runs it through a host JVM with `-Xcheck:jni`.

The fixture contains two strokes crossing a page boundary in opposite directions. Checks cover whole-stroke ownership, draw ordering, byte-for-byte persistence, neighboring overflow in export, malformed payloads, duplicate ordering, invalid dimensions/indices, and 30,000-page documents to exercise bounded JNI local references. Build files live in a temporary directory removed on exit.

This validates JNI descriptors and codec behavior on the host; it does not replace Android Kotlin/Gradle compilation, R8 verification, or device rendering tests. Java classes mirror the production Kotlin native method descriptors and result constructor.

Set `DOCUMENT_CODEC_CLASSPATH` to the compiled production Kotlin classes plus Kotlin standard library to run the same tests against the actual `DocumentCodec` and `DocumentPageData` bytecode instead of the Java signature mirrors.
