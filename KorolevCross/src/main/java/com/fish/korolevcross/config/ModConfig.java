package com.fish.korolevcross.config;

import net.minecraftforge.common.ForgeConfigSpec;

public class ModConfig {
    public static final ForgeConfigSpec SPEC;
    public static ForgeConfigSpec.BooleanValue ENABLE_GPU_GENERATION;
    public static ForgeConfigSpec.IntValue GPU_CHUNK_BATCH_SIZE;
    public static ForgeConfigSpec.IntValue RTX_SAMPLES_PER_PIXEL;
    public static ForgeConfigSpec.BooleanValue ENABLE_MIPMAP_FILTER;
    public static ForgeConfigSpec.DoubleValue ANTI_ALIASING_THRESHOLD;

    static {
        ForgeConfigSpec.Builder builder = new ForgeConfigSpec.Builder();
        builder.comment("KorolevCross GPU Configuration").push("gpu");
        ENABLE_GPU_GENERATION = builder.define("enableGpuGeneration", true);
        GPU_CHUNK_BATCH_SIZE = builder.defineInRange("gpuChunkBatchSize", 4, 1, 64);
        RTX_SAMPLES_PER_PIXEL = builder.defineInRange("rtxSamplesPerPixel", 4, 1, 64);
        ENABLE_MIPMAP_FILTER = builder.define("enableMipmapFilter", true);
        ANTI_ALIASING_THRESHOLD = builder.defineInRange("antiAliasingThreshold", 0.5, 0.0, 1.0);
        builder.pop();
        SPEC = builder.build();
    }
}