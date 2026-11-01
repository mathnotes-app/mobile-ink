package com.mathnotes.mobileink;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.Arrays;

/** Android-only metadata trailer for the backward-readable v4 ink stream. */
final class LayerOrderTrailer {
    private static final byte[] MAGIC = {77, 73, 76, 65, 89, 69, 82, 49}; // MILAYER1
    private static final int FOOTER_BYTES = 12;
    static final long MAX_ORDER = 9007199254740990L;

    private static final class Parsed {
        final int offset;
        final long[] orders;
        Parsed(int offset, long[] orders) { this.offset = offset; this.orders = orders; }
    }

    private static Parsed parse(byte[] data) {
        if (data.length < FOOTER_BYTES || !Arrays.equals(MAGIC, Arrays.copyOfRange(data, data.length - 8, data.length))) return null;
        ByteBuffer buffer = ByteBuffer.wrap(data).order(ByteOrder.LITTLE_ENDIAN);
        int count = buffer.getInt(data.length - FOOTER_BYTES);
        if (count < 0 || count > 100000 || data.length < 8 || buffer.getInt(4) != count ||
            (long) count * 8 > data.length - FOOTER_BYTES) throw new IllegalArgumentException("Invalid document layer order count");
        int offset = data.length - FOOTER_BYTES - count * 8;
        if (offset < 8) throw new IllegalArgumentException("Invalid document layer order data");
        long[] orders = new long[count];
        for (int i = 0; i < count; i++) {
            long order = buffer.getLong(offset + i * 8);
            if (order < 0 || order > MAX_ORDER) throw new IllegalArgumentException("Invalid document layer order value");
            orders[i] = order;
        }
        return new Parsed(offset, orders);
    }

    static long[] read(byte[] data) {
        Parsed parsed = parse(data);
        return parsed == null ? null : parsed.orders;
    }

    static byte[] attach(byte[] data, long[] orders) {
        if (data.length == 0) {
            if (orders.length != 0) throw new IllegalArgumentException("Document layer order count mismatch");
            return data;
        }
        if (data.length < 8) throw new IllegalArgumentException("Invalid drawing bytes");
        int count = ByteBuffer.wrap(data).order(ByteOrder.LITTLE_ENDIAN).getInt(4);
        if (count < 0 || count > 100000 || count != orders.length)
            throw new IllegalArgumentException("Document layer order count mismatch");
        Parsed previous = parse(data);
        int baseSize = previous == null ? data.length : previous.offset;
        ByteBuffer buffer = ByteBuffer.allocate(baseSize + count * 8 + FOOTER_BYTES).order(ByteOrder.LITTLE_ENDIAN);
        buffer.put(data, 0, baseSize);
        for (long order : orders) {
            if (order < 0 || order > MAX_ORDER) throw new IllegalArgumentException("Invalid document layer order value");
            buffer.putLong(order);
        }
        buffer.putInt(count);
        buffer.put(MAGIC);
        return buffer.array();
    }
}
