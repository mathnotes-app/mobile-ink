#include <jni.h>
#include "ContinuousDocumentPages.h"
#include "DrawingSerialization.h"
#include <stdexcept>
#include <limits>

using namespace nativedrawing;
namespace {
void check(JNIEnv* env) {
    if (env->ExceptionCheck()) throw std::runtime_error("Document JNI allocation failed");
}
ContinuousDocumentPage decode(JNIEnv* env, jbyteArray data, jlongArray order, bool hasOrder) {
    if (!data || !order) throw std::invalid_argument("Missing document page data");
    ContinuousDocumentPage page;
    std::vector<uint8_t> bytes(env->GetArrayLength(data));
    if (!bytes.empty()) env->GetByteArrayRegion(data, 0, bytes.size(), reinterpret_cast<jbyte*>(bytes.data()));
    check(env);
    if (!bytes.empty()) {
        DrawingSerialization serializer;
        if (!serializer.deserialize(bytes, page.strokes)) throw std::invalid_argument("Invalid serialized drawing");
    }
    const auto count = env->GetArrayLength(order);
    if (hasOrder && static_cast<size_t>(count) != page.strokes.size())
        throw std::invalid_argument("Document stroke order count mismatch");
    if (!hasOrder && count) throw std::invalid_argument("Unexpected document stroke order");
    std::vector<jlong> values(count);
    if (count) env->GetLongArrayRegion(order, 0, count, values.data());
    check(env);
    for (auto value : values) {
        if (value < 0 || value > 9007199254740991LL) throw std::invalid_argument("Invalid document stroke order");
        page.order.push_back(static_cast<uint64_t>(value));
    }
    return page;
}
std::vector<ContinuousDocumentPage> decodePages(JNIEnv* env, jobjectArray data, jobjectArray orders, jbooleanArray flags) {
    if (!data || !orders || !flags) throw std::invalid_argument("Missing document pages");
    const auto count = env->GetArrayLength(data);
    if (env->GetArrayLength(orders) != count || env->GetArrayLength(flags) != count)
        throw std::invalid_argument("Document page count mismatch");
    std::vector<jboolean> hasOrder(count);
    if (count) env->GetBooleanArrayRegion(flags, 0, count, hasOrder.data());
    check(env);
    std::vector<ContinuousDocumentPage> result;
    result.reserve(count);
    for (jsize index = 0; index < count; ++index) {
        // Bound local JNI references even for very long documents.
        if (env->PushLocalFrame(4) != JNI_OK) throw std::runtime_error("Cannot allocate document JNI frame");
        try {
            auto bytes = static_cast<jbyteArray>(env->GetObjectArrayElement(data, index));
            auto order = static_cast<jlongArray>(env->GetObjectArrayElement(orders, index));
            check(env);
            result.push_back(decode(env, bytes, order, hasOrder[index]));
        } catch (...) { env->PopLocalFrame(nullptr); throw; }
        env->PopLocalFrame(nullptr);
    }
    return result;
}
jbyteArray encodeBytes(JNIEnv* env, const std::vector<Stroke>& strokes) {
    DrawingSerialization serializer;
    const auto bytes = strokes.empty() ? std::vector<uint8_t>() : serializer.serialize(strokes);
    if (bytes.size() > static_cast<size_t>(std::numeric_limits<jsize>::max()))
        throw std::length_error("Document payload exceeds JNI array limit");
    auto result = env->NewByteArray(static_cast<jsize>(bytes.size()));
    check(env);
    if (!bytes.empty()) env->SetByteArrayRegion(result, 0, bytes.size(), reinterpret_cast<const jbyte*>(bytes.data()));
    check(env);
    return result;
}
jobjectArray encodePages(JNIEnv* env, const std::vector<ContinuousDocumentPage>& pages) {
    auto type = env->FindClass("com/mathnotes/mobileink/DocumentPageData");
    check(env);
    auto constructor = env->GetMethodID(type, "<init>", "([B[J)V");
    check(env);
    auto result = env->NewObjectArray(pages.size(), type, nullptr);
    check(env);
    for (size_t index = 0; index < pages.size(); ++index) {
        if (env->PushLocalFrame(4) != JNI_OK) throw std::runtime_error("Cannot allocate document JNI frame");
        try {
            const auto& page = pages[index];
            auto bytes = encodeBytes(env, page.strokes);
            std::vector<jlong> order(page.order.begin(), page.order.end());
            auto indices = env->NewLongArray(order.size());
            check(env);
            if (!order.empty()) env->SetLongArrayRegion(indices, 0, order.size(), order.data());
            check(env);
            auto value = env->NewObject(type, constructor, bytes, indices);
            check(env);
            env->SetObjectArrayElement(result, index, value);
            check(env);
        } catch (...) { env->PopLocalFrame(nullptr); throw; }
        env->PopLocalFrame(nullptr);
    }
    env->DeleteLocalRef(type);
    return result;
}
void reject(JNIEnv* env, const std::exception& error) {
    if (env->ExceptionCheck()) return;
    auto type = env->FindClass("java/lang/IllegalArgumentException");
    if (type) { env->ThrowNew(type, error.what()); env->DeleteLocalRef(type); }
}
}
extern "C" JNIEXPORT jbyteArray JNICALL Java_com_mathnotes_mobileink_DocumentCodec_compose(
    JNIEnv* env, jobject, jobjectArray data, jobjectArray orders, jbooleanArray flags, jfloat height) {
    try { return encodeBytes(env, composeContinuousDocument(decodePages(env, data, orders, flags), height)); }
    catch (const std::exception& error) { reject(env, error); return nullptr; }
    catch (...) { reject(env, std::runtime_error("Unknown document codec failure")); return nullptr; }
}
extern "C" JNIEXPORT jobjectArray JNICALL Java_com_mathnotes_mobileink_DocumentCodec_partition(
    JNIEnv* env, jobject, jbyteArray data, jlongArray order, jboolean hasOrder, jint count, jfloat height) {
    try {
        if (count < 1 || count > 100000) throw std::invalid_argument("Invalid document page count");
        return encodePages(env, partitionContinuousDocument(decode(env, data, order, hasOrder).strokes, count, height));
    } catch (const std::exception& error) { reject(env, error); return nullptr; }
    catch (...) { reject(env, std::runtime_error("Unknown document codec failure")); return nullptr; }
}
// `snapshot` is a std::vector<Stroke>* from MobileInkCanvasView.takeDrawingSnapshot;
// the caller keeps ownership. Partitioning the copy avoids re-decoding a
// serialized document on every autosave.
extern "C" JNIEXPORT jobjectArray JNICALL Java_com_mathnotes_mobileink_DocumentCodec_partitionSnapshot(
    JNIEnv* env, jobject, jlong snapshot, jint count, jfloat height) {
    try {
        if (!snapshot) throw std::invalid_argument("Missing drawing snapshot");
        if (count < 1 || count > 100000) throw std::invalid_argument("Invalid document page count");
        const auto& strokes = *reinterpret_cast<const std::vector<Stroke>*>(snapshot);
        return encodePages(env, partitionContinuousDocument(strokes, count, height));
    } catch (const std::exception& error) { reject(env, error); return nullptr; }
    catch (...) { reject(env, std::runtime_error("Unknown document codec failure")); return nullptr; }
}
extern "C" JNIEXPORT jobjectArray JNICALL Java_com_mathnotes_mobileink_DocumentCodec_project(
    JNIEnv* env, jobject, jobjectArray data, jobjectArray orders, jbooleanArray flags, jfloat height, jintArray requested) {
    try {
        if (!requested) throw std::invalid_argument("Missing export page indices");
        std::vector<jint> raw(env->GetArrayLength(requested));
        if (!raw.empty()) env->GetIntArrayRegion(requested, 0, raw.size(), raw.data());
        check(env);
        const auto projected = projectContinuousDocumentPages(decodePages(env, data, orders, flags), height,
            std::vector<int>(raw.begin(), raw.end()));
        std::vector<ContinuousDocumentPage> pages;
        for (const auto& strokes : projected) pages.push_back({strokes, {}});
        return encodePages(env, pages);
    } catch (const std::exception& error) { reject(env, error); return nullptr; }
    catch (...) { reject(env, std::runtime_error("Unknown document codec failure")); return nullptr; }
}
