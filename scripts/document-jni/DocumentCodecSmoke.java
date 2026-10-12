package com.mathnotes.mobileink;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Arrays;
public final class DocumentCodecSmoke {
    private static void require(boolean value, String message) {
        if (!value) throw new AssertionError(message);
    }
    private static void rejects(Runnable work) {
        try { work.run(); } catch (IllegalArgumentException expected) { return; }
        throw new AssertionError("Invalid document accepted");
    }
    public static void main(String[] args) throws Exception {
        System.load(args[0]);
        DocumentCodec codec = DocumentCodec.INSTANCE;
        byte[] original = Files.readAllBytes(Path.of(args[1]));
        DocumentPageData[] pages = codec.partition(original, new long[0], false, 2, 1000);
        require(pages.length == 2, "Page count changed");
        require(Arrays.equals(pages[0].getOrder(), new long[]{1}) && Arrays.equals(pages[1].getOrder(), new long[]{0}),
            "Crossing strokes were split or reordered");
        byte[][] bytes = { pages[0].getBytes(), pages[1].getBytes() };
        long[][] orders = { pages[0].getOrder(), pages[1].getOrder() };
        boolean[] modern = { true, true };
        byte[] restored = codec.compose(bytes, orders, modern, 1000);
        require(Arrays.equals(original, restored), "Roundtrip changed geometry or draw order");
        DocumentPageData[] exports = codec.project(bytes, orders, modern, 1000, new int[]{0, 1});
        for (DocumentPageData page : exports) {
            // Both crossing strokes must be present in each rendered page.
            DocumentPageData[] projected = codec.partition(page.getBytes(), new long[0], false, 1, 1000);
            require(projected[0].getOrder().length == 2, "Export omitted neighboring overflow");
        }
        rejects(() -> codec.compose(bytes, new long[][]{{0}, {0}}, modern, 1000));
        rejects(() -> codec.partition(original, new long[0], true, 2, 1000));
        rejects(() -> codec.partition(new byte[]{1, 2}, new long[0], false, 2, 1000));
        rejects(() -> codec.partition(original, new long[0], false, 0, 1000));
        rejects(() -> codec.compose(bytes, orders, modern, Float.NaN));
        rejects(() -> codec.project(bytes, orders, modern, 1000, new int[]{2}));
        byte[][] blanks = new byte[30000][];
        long[][] blankOrders = new long[30000][];
        Arrays.fill(blanks, new byte[0]); Arrays.fill(blankOrders, new long[0]);
        require(codec.compose(blanks, blankOrders, new boolean[30000], 1000).length == 0,
            "Large empty document failed");
        require(codec.partition(new byte[0], new long[0], true, 30000, 1000).length == 30000,
            "Large partition failed");
        System.out.println("Document JNI host smoke passed: crossing, order, export, invalid input, 30k pages");
    }
}
