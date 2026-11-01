package com.mathnotes.mobileink;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.Arrays;

public final class LayerOrderTrailerSmoke {
    private static void require(boolean value, String message) {
        if (!value) throw new AssertionError(message);
    }
    private static void rejects(Runnable action) {
        try { action.run(); } catch (IllegalArgumentException expected) { return; }
        throw new AssertionError("Invalid layer metadata accepted");
    }
    public static void main(String[] args) {
        byte[] legacy = ByteBuffer.allocate(24).order(ByteOrder.LITTLE_ENDIAN)
            .putInt(4).putInt(2).putLong(11).putLong(22).array();
        require(LayerOrderTrailer.read(legacy) == null, "Legacy drawing gained metadata");
        byte[] attached = LayerOrderTrailer.attach(legacy, new long[]{9, 4});
        require(Arrays.equals(LayerOrderTrailer.read(attached), new long[]{9, 4}), "Layer order changed");
        require(Arrays.equals(attached, LayerOrderTrailer.attach(attached, new long[]{9, 4})), "Repeated attach changed bytes");
        require(Arrays.equals(LayerOrderTrailer.read(LayerOrderTrailer.attach(attached, new long[]{4, 9})),
            new long[]{4, 9}), "Replacing metadata failed");
        require(LayerOrderTrailer.attach(new byte[0], new long[0]).length == 0, "Blank drawing changed");
        rejects(() -> LayerOrderTrailer.attach(legacy, new long[]{1}));
        rejects(() -> LayerOrderTrailer.attach(legacy, new long[]{-1, 1}));
        rejects(() -> LayerOrderTrailer.attach(legacy, new long[]{1, 9007199254740991L}));
        byte[] badCount = attached.clone();
        ByteBuffer.wrap(badCount).order(ByteOrder.LITTLE_ENDIAN).putInt(badCount.length - 12, 3);
        rejects(() -> LayerOrderTrailer.read(badCount));
        System.out.println("Layer-order trailer roundtrip and invalid-input checks passed");
    }
}
