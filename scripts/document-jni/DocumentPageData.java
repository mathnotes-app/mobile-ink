package com.mathnotes.mobileink;

// Mirrors the Kotlin JNI result constructor for the host boundary test.
public final class DocumentPageData {
    private final byte[] bytes;
    private final long[] order;
    public DocumentPageData(byte[] bytes, long[] order) { this.bytes = bytes; this.order = order; }
    public byte[] getBytes() { return bytes; }
    public long[] getOrder() { return order; }
}
