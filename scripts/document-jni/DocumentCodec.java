package com.mathnotes.mobileink;
// Host fallback signatures; use DOCUMENT_CODEC_CLASSPATH for compiled Kotlin.
public final class DocumentCodec {
    public static final DocumentCodec INSTANCE = new DocumentCodec();
    public native byte[] compose(byte[][] bytes, long[][] orders, boolean[] hasOrders, float height);
    public native DocumentPageData[] partition(byte[] bytes, long[] order, boolean hasOrder, int count, float height);
    public native DocumentPageData[] project(byte[][] bytes, long[][] orders, boolean[] hasOrders, float height, int[] indices);
}
