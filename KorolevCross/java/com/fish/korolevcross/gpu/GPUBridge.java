package com.fish.korolevcross.gpu;

import com.fish.korolevcross.KorolevCross;
import java.io.BufferedReader;
import java.io.File;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.StandardCopyOption;
import java.util.HashMap;
import java.util.Map;

public class GPUBridge {
    private static boolean initialized = false;
    private static final Map<String, Long> registeredDimensions = new HashMap<>();
    private static final Map<String, Long> failedDimensions = new HashMap<>();

    public static native int ping();
    public static native boolean initCUDA();
    public static native void registerDensityFunction(String id, String jsonStr);
    public static native void registerNoise(String id, String jsonStr);
    public static native void clearDensityCache();
    public static native boolean registerDimension(String dimName, String noiseJson, long seed);
    public static native void generateChunk(String dimName, int chunkX, int chunkZ,
                                            int minY, int maxY, int seaLevel, short[] output);
    public static native void shutdown();
    public static native String getLastError();

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
            KorolevCross.LOGGER.info("Loaded native library: {}", libFile.getAbsolutePath());
        } catch (Exception e) {
            KorolevCross.LOGGER.error("Failed to load native library", e);
        }
    }

    public static boolean isInitialized() {
        return initialized;
    }

    public static void initialize() {
        if (initialized) return;

        try {
            int pong = ping();
            KorolevCross.LOGGER.info("Native ping: {}", pong);
        } catch (Throwable t) {
            KorolevCross.LOGGER.error("Native ping failed", t);
            return;
        }

        initialized = initCUDA();
        if (!initialized) {
            KorolevCross.LOGGER.error("CUDA init failed");
            return;
        }
        registerAllResources();
    }

    private static void registerAllResources() {
        int df = registerFromIndex("/native/dimension/df_index.txt",
                "/native/dimension/density_functions/", true);
        int n = registerFromIndex("/native/dimension/noise_index.txt",
                "/native/dimension/noise/", false);
        KorolevCross.LOGGER.info("Registered {} density functions, {} noises", df, n);
    }

    private static int registerFromIndex(String indexPath, String baseDir, boolean isDensityFunction) {
        int count = 0;
        try {
            InputStream idxIn = GPUBridge.class.getResourceAsStream(indexPath);
            if (idxIn == null) {
                KorolevCross.LOGGER.warn("Index not found: {}", indexPath);
                return 0;
            }

            BufferedReader reader = new BufferedReader(new InputStreamReader(idxIn, StandardCharsets.US_ASCII));
            String line;
            while ((line = reader.readLine()) != null) {
                line = line.trim();
                if (line.isEmpty()) continue;

                String resourcePath = baseDir + line;
                InputStream jsonIn = GPUBridge.class.getResourceAsStream(resourcePath);
                if (jsonIn == null) {
                    continue;
                }

                String jsonStr = new String(jsonIn.readAllBytes(), StandardCharsets.UTF_8);
                jsonIn.close();

                String id = line.substring(0, line.length() - 5).replace("__", "/");
                if (isDensityFunction) {
                    registerDensityFunction(id, jsonStr);
                } else {
                    registerNoise(id, jsonStr);
                }
                count++;
            }
            reader.close();
        } catch (Exception e) {
            KorolevCross.LOGGER.error("Failed to register from index " + indexPath, e);
        }
        return count;
    }

    public static boolean registerDimensionWithSeed(String dimName, long seed) {
        if (!initialized) return false;
        synchronized (registeredDimensions) {
            Long existing = registeredDimensions.get(dimName);
            if (existing != null && existing.longValue() == seed) return true;

            Long failed = failedDimensions.get(dimName);
            if (failed != null && failed.longValue() == seed) return false;

            boolean ok = doRegister(dimName, seed);
            if (ok) {
                registeredDimensions.put(dimName, seed);
            } else {
                failedDimensions.put(dimName, seed);
                String err = "unknown";
                try {
                    err = getLastError();
                } catch (Throwable ignored) {}
                KorolevCross.LOGGER.error("[KorolevCross] GPU registration FAILED permanently: dim={} seed={} reason={}",
                        dimName, seed, err);
            }
            return ok;
        }
    }

    private static boolean doRegister(String dimName, long seed) {
        try {
            String safeName = dimName.replace(":", "_");
            String noisePath = "/native/dimension/" + safeName + "_noise.json";

            InputStream noiseIn = GPUBridge.class.getResourceAsStream(noisePath);
            if (noiseIn == null) {
                return false;
            }

            String noiseJson = new String(noiseIn.readAllBytes(), StandardCharsets.UTF_8);
            noiseIn.close();

            return registerDimension(dimName, noiseJson, seed);
        } catch (Exception e) {
            return false;
        }
    }
}