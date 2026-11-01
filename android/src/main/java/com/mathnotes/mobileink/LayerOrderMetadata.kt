package com.mathnotes.mobileink

import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject

/** Layer metadata accompanies v4 binary drawings without changing legacy ink bytes. */
internal object LayerOrderMetadata {
    fun apply(root: JSONObject, data: ByteArray): ByteArray {
        if (!root.has("documentLayerOrder")) return data
        val values = root.getJSONArray("documentLayerOrder")
        require(values.length() <= 100000) { "Invalid document layer order count" }
        val orders = LongArray(values.length()) { index ->
            val value = values.get(index)
            require(value is Number) { "Invalid document layer order value" }
            val number = value.toDouble()
            require(number.isFinite() && number >= 0 && number <= LayerOrderTrailer.MAX_ORDER.toDouble() && number == kotlin.math.floor(number)) {
                "Invalid document layer order value"
            }
            number.toLong()
        }
        return LayerOrderTrailer.attach(data, orders)
    }

    fun drawing(data: ByteArray): JSONObject {
        val pages = JSONObject()
        if (data.isNotEmpty()) pages.put("0", Base64.encodeToString(data, Base64.NO_WRAP))
        val root = JSONObject().put("pages", pages)
        LayerOrderTrailer.read(data)?.let { orders -> root.put("documentLayerOrder", JSONArray().apply {
            orders.forEach { put(it) }
        }) }
        return root
    }
}
