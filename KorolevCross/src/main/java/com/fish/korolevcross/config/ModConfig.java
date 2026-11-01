package com.fish.korolevcross.config;

import net.minecraftforge.common.ForgeConfigSpec;

public final class ModConfig {
    public static final ForgeConfigSpec SPEC;

    private static final ForgeConfigSpec.BooleanValue ENABLED;
    private static final ForgeConfigSpec.BooleanValue MIXED_PRECISION;
    private static final ForgeConfigSpec.BooleanValue DEBUG;

    static {
        ForgeConfigSpec.Builder builder = new ForgeConfigSpec.Builder();
        builder.comment("GPU accelerated chunk density generation").push("generation");
        ENABLED = builder
                .comment("Generate terrain density field on the GPU. Terrain stays identical to vanilla.")
                .define("enabled", true);
        MIXED_PRECISION = builder
                .comment("Use the fp16/fp32/fp64 staged pipeline instead of exact fp64 evaluation.")
                .define("mixedPrecision", false);
        DEBUG = builder
                .comment("Log GPU initialization and per-chunk statistics.")
                .define("debug", false);
        builder.pop();
        SPEC = builder.build();
    }

    private ModConfig() {
    }

    public static boolean enabled() {
        try {
            return ENABLED.get();
        } catch (IllegalStateException e) {
            return true;
        }
    }

    public static boolean mixedPrecision() {
        try {
            return MIXED_PRECISION.get();
        } catch (IllegalStateException e) {
            return false;
        }
    }

    public static boolean debug() {
        try {
            return DEBUG.get();
        } catch (IllegalStateException e) {
            return false;
        }
    }
}
