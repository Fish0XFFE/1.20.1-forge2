package com.fish.korolevcross.gpu;

import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;

public final class NativeBridge {
    private static volatile boolean available;
    private static volatile String failure = "not initialized";

    private NativeBridge() {
    }

    public static synchronized boolean load() {
        if (available) {
            return true;
        }
        try {
            String override = System.getProperty("korolevcross.native");
            Path dll;
            if (override != null) {
                dll = Path.of(override);
            } else {
                InputStream raw = NativeBridge.class.getResourceAsStream("/native/korolev_native.dll");
                if (raw == null) {
                    raw = NativeBridge.class.getResourceAsStream("/native/Release/korolev_native.dll");
                }
                if (raw == null) {
                    failure = "native library resource missing";
                    return false;
                }
                try (InputStream in = raw) {
                    dll = Files.createTempFile("korolev_native_", ".dll");
                    Files.copy(in, dll, StandardCopyOption.REPLACE_EXISTING);
                    dll.toFile().deleteOnExit();
                }
            }
            System.load(dll.toAbsolutePath().toString());
            int rc = nativeInit();
            if (rc != 0) {
                failure = "cuda init failed: " + rc + " " + getLastError();
                return false;
            }
            available = true;
            failure = "";
            return true;
        } catch (Throwable t) {
            failure = t.toString();
            return false;
        }
    }

    public static boolean isAvailable() {
        return available;
    }

    public static String failureReason() {
        return failure;
    }

    public static native int nativeInit();

    public static native String nativeDeviceName();

    public static native long createProgram(byte[] spec);

    public static native int compute(long handle, int firstCellX, int firstCellZ, int cellWidth, int cellHeight,
                                     int cellNoiseMinY, int cellCountXZ, int cellCountY, double[] flats,
                                     double[] out, int mode);

    public static native void destroyProgram(long handle);

    public static native String getLastError();

    public static native void nativeShutdown();
}
