package com.mathnotes.mobileink

import android.util.Base64
import com.facebook.react.bridge.*
import com.facebook.react.module.annotations.ReactModule
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.Executors

/** Whole-stroke document codec; no view or GL context is needed. */
@ReactModule(name = MobileInkDocumentBridge.NAME)
class MobileInkDocumentBridge(context: ReactApplicationContext) : ReactContextBaseJavaModule(context) {
    companion object { const val NAME = "MobileInkDocumentBridge" }
    private val executor = Executors.newSingleThreadExecutor()
    private data class Page(val bytes: ByteArray, val order: LongArray, val hasOrder: Boolean)

    override fun getName() = NAME
    override fun invalidate() {
        // Complete accepted codec requests before releasing the worker.
        executor.shutdown()
        super.invalidate()
    }

    private fun decode(payload: String): Page {
        val root = JSONObject(payload)
        val pages = root.getJSONObject("pages")
        require(pages.length() == 0 || (pages.length() == 1 && pages.has("0"))) {
            "Expected a single native page payload"
        }
        val bytes = if (pages.length() == 0) byteArrayOf() else {
            val encoded = pages.get("0")
            require(encoded is String && encoded.isNotEmpty()) { "Invalid drawing encoding" }
            val decoded = Base64.decode(encoded, Base64.NO_WRAP)
            require(decoded.isNotEmpty() && Base64.encodeToString(decoded, Base64.NO_WRAP) == encoded) {
                "Invalid drawing bytes"
            }
            decoded
        }
        val hasOrder = root.has("documentStrokeOrder")
        val order = if (hasOrder) root.getJSONArray("documentStrokeOrder") else JSONArray()
        val values = LongArray(order.length()) { index ->
            val value = order.get(index)
            require(value is Number) { "Invalid document stroke order value" }
            val number = value.toDouble()
            require(number.isFinite() && number >= 0 && number <= 9007199254740991.0 &&
                number == kotlin.math.floor(number)) { "Invalid document stroke order range" }
            number.toLong()
        }
        return Page(bytes, values, hasOrder)
    }

    private fun encode(page: DocumentPageData, includeOrder: Boolean): String {
        val pages = JSONObject()
        if (page.bytes.isNotEmpty()) pages.put("0", Base64.encodeToString(page.bytes, Base64.NO_WRAP))
        val root = JSONObject().put("pages", pages)
        if (includeOrder) root.put("documentStrokeOrder", JSONArray().apply {
            page.order.forEach { put(it) }
        })
        return root.toString()
    }

    private fun payloads(values: ReadableArray): List<String> = (0 until values.size()).map {
        require(values.getType(it) == ReadableType.String) { "Invalid page payload type" }
        requireNotNull(values.getString(it))
    }

    private fun run(promise: Promise, code: String, operation: () -> Any) {
        try {
            executor.execute {
                try { promise.resolve(operation()) }
                catch (error: Exception) { promise.reject(code, error) }
                catch (error: LinkageError) { promise.reject(code, error) }
            }
        } catch (error: Exception) { promise.reject(code, error) }
    }

    @ReactMethod
    fun composeDocument(values: ReadableArray, pageHeight: Double, promise: Promise) {
        // Copy React bridge values before moving to the worker.
        val payloads = try { payloads(values) } catch (error: Exception) {
            promise.reject("DOCUMENT_COMPOSE_FAILED", error); return
        }
        run(promise, "DOCUMENT_COMPOSE_FAILED") {
            val pages = payloads.map(::decode)
            val bytes = DocumentCodec.compose(pages.map { it.bytes }.toTypedArray(),
                pages.map { it.order }.toTypedArray(), pages.map { it.hasOrder }.toBooleanArray(), pageHeight.toFloat())
            encode(DocumentPageData(bytes, longArrayOf()), false)
        }
    }

    @ReactMethod
    fun loadDocument(viewTag: Int, values: ReadableArray, pageHeight: Double, promise: Promise) {
        val payloads = try { payloads(values) } catch (error: Exception) {
            promise.reject("DOCUMENT_LOAD_FAILED", error); return
        }
        try {
            executor.execute {
                try {
                    val pages = payloads.map(::decode)
                    val bytes = DocumentCodec.compose(pages.map { it.bytes }.toTypedArray(),
                        pages.map { it.order }.toTypedArray(), pages.map { it.hasOrder }.toBooleanArray(), pageHeight.toFloat())
                    val payload = encode(DocumentPageData(bytes, longArrayOf()), false)
                    val loader = reactApplicationContext.getNativeModule(MobileInkModule::class.java)
                        ?: throw IllegalStateException("MobileInkModule is unavailable")
                    // This resolves only after the GL thread has loaded the drawing.
                    loader.loadBase64Data(viewTag, payload, promise)
                } catch (error: Exception) { promise.reject("DOCUMENT_LOAD_FAILED", error) }
                catch (error: LinkageError) { promise.reject("DOCUMENT_LOAD_FAILED", error) }
            }
        } catch (error: Exception) { promise.reject("DOCUMENT_LOAD_FAILED", error) }
    }

    @ReactMethod
    fun partitionDocument(payload: String, pageCount: Double, pageHeight: Double, promise: Promise) {
        run(promise, "DOCUMENT_PARTITION_FAILED") {
            require(pageCount.isFinite() && pageCount >= 1 && pageCount <= 100000 &&
                pageCount == kotlin.math.floor(pageCount)) { "Invalid document page count" }
            val page = decode(payload)
            val pages = DocumentCodec.partition(page.bytes, page.order, page.hasOrder, pageCount.toInt(), pageHeight.toFloat())
            Arguments.createArray().apply { pages.forEach { pushString(encode(it, true)) } }
        }
    }

    @ReactMethod
    fun projectDocumentPages(values: ReadableArray, pageHeight: Double, requested: ReadableArray, promise: Promise) {
        val payloads: List<String>
        val indices: IntArray
        try {
            payloads = payloads(values)
            indices = IntArray(requested.size()) {
                require(requested.getType(it) == ReadableType.Number) { "Invalid export page index" }
                val index = requested.getDouble(it)
                require(index.isFinite() && index >= 0 && index < payloads.size &&
                    index == kotlin.math.floor(index)) { "Invalid export page index" }
                index.toInt()
            }
        } catch (error: Exception) { promise.reject("DOCUMENT_EXPORT_FAILED", error); return }
        run(promise, "DOCUMENT_EXPORT_FAILED") {
            val pages = payloads.map(::decode)
            val projected = DocumentCodec.project(pages.map { it.bytes }.toTypedArray(),
                pages.map { it.order }.toTypedArray(), pages.map { it.hasOrder }.toBooleanArray(), pageHeight.toFloat(), indices)
            Arguments.createArray().apply { projected.forEach { pushString(encode(it, false)) } }
        }
    }
}

// Kept as a simple Java-visible constructor for JNI. Consumer rules preserve it.
class DocumentPageData(val bytes: ByteArray, val order: LongArray)

internal object DocumentCodec {
    init { System.loadLibrary("mobileink") }
    external fun compose(bytes: Array<ByteArray>, orders: Array<LongArray>, hasOrders: BooleanArray, height: Float): ByteArray
    external fun partition(bytes: ByteArray, order: LongArray, hasOrder: Boolean, count: Int, height: Float): Array<DocumentPageData>
    external fun project(bytes: Array<ByteArray>, orders: Array<LongArray>, hasOrders: BooleanArray, height: Float, indices: IntArray): Array<DocumentPageData>
}
