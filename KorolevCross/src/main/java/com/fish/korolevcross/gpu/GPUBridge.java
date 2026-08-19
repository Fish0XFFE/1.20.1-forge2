package com.fish.korolevcross.gpu;

import com.fish.korolevcross.KorolevCross;
import java.io.File;
import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.StandardCopyOption;

public class GPUBridge {
    private static boolean initialized = false;

    public static native short[][][] generateChunk(int chunkX, int chunkZ, int minY, int maxY, int seed);
    public static native boolean initCUDA();

    public static void extractAndLoadLibrary() {
        String libName = System.mapLibraryName("korolev_native");
        InputStream in = GPUBridge.class.getResourceAsStream("/native/" + libName);
        if (in == null) {
            KorolevCross.LOGGER.error("Native library not found");
            return;
        }
        try {
            File tempDir = Files.createTempDirectory("korolev_native_").toFile();
            tempDir.deleteOnExit();
            File libFile = new File(tempDir, libName);
            Files.copy(in, libFile.toPath(), StandardCopyOption.REPLACE_EXISTING);
            in.close();
            System.load(libFile.getAbsolutePath());
        } catch (Exception e) {
            KorolevCross.LOGGER.error("Failed to load native library", e);
        }
    }

    public static boolean isInitialized() { return initialized; }

    public static void initialize() {
        if (!initialized) {
            initialized = initCUDA();
        }
    }
}