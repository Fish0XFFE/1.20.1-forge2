package com.fish.korolevcross.mixin;

import com.fish.korolevcross.KorolevCross;
import com.fish.korolevcross.config.ModConfig;
import com.fish.korolevcross.gpu.GPUBridge;
import net.minecraft.resources.ResourceLocation;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.world.level.StructureManager;
import net.minecraft.world.level.block.Blocks;
import net.minecraft.world.level.chunk.ChunkAccess;
import net.minecraft.world.level.chunk.LevelChunkSection;
import net.minecraft.world.level.chunk.PalettedContainer;
import net.minecraft.world.level.levelgen.NoiseBasedChunkGenerator;
import net.minecraft.world.level.levelgen.RandomState;
import net.minecraft.world.level.levelgen.blending.Blender;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;

import java.lang.reflect.Field;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.Executor;

@Mixin(NoiseBasedChunkGenerator.class)
public class NoiseBasedChunkGeneratorMixin {

    @Inject(method = "fillFromNoise", at = @At("HEAD"), cancellable = true)
    private void onFillFromNoise(Executor executor, Blender blender, RandomState randomState,
                                 StructureManager structureManager, ChunkAccess chunk,
                                 CallbackInfoReturnable<CompletableFuture<ChunkAccess>> cir) {
        try {
            if (!ModConfig.ENABLE_GPU_GENERATION.get() || !GPUBridge.isInitialized()) {
                return;
            }

            String dimName = getDimensionName(chunk);
            if (dimName == null) return;

            long seed = getLevelSeed(randomState);

            if (!GPUBridge.registerDimensionWithSeed(dimName, seed)) {
                return;
            }

            int chunkX = chunk.getPos().x;
            int chunkZ = chunk.getPos().z;
            int minY = chunk.getMinBuildHeight();
            int maxY = chunk.getMaxBuildHeight();
            int seaLevel = getSeaLevel(chunk);

            int sizeX = 16, sizeZ = 16, sizeY = maxY - minY + 1;
            short[] output = new short[sizeX * sizeZ * sizeY];

            GPUBridge.generateChunk(dimName, chunkX, chunkZ, minY, maxY, seaLevel, output);

            fillChunkDirectly(chunk, output, sizeX, sizeZ, sizeY, minY, maxY);

            cir.setReturnValue(CompletableFuture.completedFuture(chunk));
        } catch (Exception e) {
            KorolevCross.LOGGER.error("GPU chunk generation failed", e);
        }
    }

    private String getDimensionName(ChunkAccess chunk) {
        try {
            Field levelField = chunk.getClass().getDeclaredField("level");
            levelField.setAccessible(true);
            Object level = levelField.get(chunk);
            if (level instanceof ServerLevel serverLevel) {
                ResourceLocation loc = serverLevel.dimension().location();
                return loc.toString();
            }
        } catch (Exception ignored) {}
        return "minecraft:overworld";
    }

    private long getLevelSeed(RandomState randomState) {
        String[] names = {"field_226929_", "levelSeed", "f_224525_"};
        for (String name : names) {
            try {
                Field f = RandomState.class.getDeclaredField(name);
                f.setAccessible(true);
                Object v = f.get(randomState);
                if (v instanceof Long) return (Long) v;
            } catch (Exception ignored) {}
        }
        return 0L;
    }

    private int getSeaLevel(ChunkAccess chunk) {
        try {
            Field levelField = chunk.getClass().getDeclaredField("level");
            levelField.setAccessible(true);
            Object level = levelField.get(chunk);
            if (level instanceof ServerLevel serverLevel) {
                return serverLevel.getSeaLevel();
            }
        } catch (Exception ignored) {}
        return 63;
    }

    private void fillChunkDirectly(ChunkAccess chunk, short[] data,
                                   int sizeX, int sizeZ, int sizeY, int minY, int maxY) {
        for (int sectionIdx = 0; sectionIdx < chunk.getSections().length; sectionIdx++) {
            LevelChunkSection section = chunk.getSections()[sectionIdx];
            if (section == null) continue;
            int sectionBaseY = sectionIdx * 16 + minY;
            PalettedContainer<net.minecraft.world.level.block.state.BlockState> container = section.getStates();

            for (int lx = 0; lx < 16; lx++) {
                for (int lz = 0; lz < 16; lz++) {
                    for (int ly = 0; ly < 16; ly++) {
                        int worldY = sectionBaseY + ly;
                        if (worldY >= minY && worldY <= maxY) {
                            int idx = (lx * sizeZ + lz) * sizeY + (worldY - minY);
                            short blockId = data[idx];
                            if (blockId != 0) {
                                container.set(lx, ly, lz, getBlockState(blockId));
                            }
                        }
                    }
                }
            }
            section.recalcBlockCounts();
        }
    }

    private net.minecraft.world.level.block.state.BlockState getBlockState(short id) {
        switch (id) {
            case 1: return Blocks.STONE.defaultBlockState();
            case 2: return Blocks.GRASS_BLOCK.defaultBlockState();
            case 3: return Blocks.DIRT.defaultBlockState();
            case 4: return Blocks.COBBLESTONE.defaultBlockState();
            case 5: return Blocks.OAK_PLANKS.defaultBlockState();
            case 6: return Blocks.SAND.defaultBlockState();
            case 7: return Blocks.GRAVEL.defaultBlockState();
            case 8: return Blocks.WATER.defaultBlockState();
            case 9: return Blocks.LAVA.defaultBlockState();
            case 10: return Blocks.OAK_LOG.defaultBlockState();
            case 11: return Blocks.OAK_LEAVES.defaultBlockState();
            case 12: return Blocks.BEDROCK.defaultBlockState();
            default: return Blocks.AIR.defaultBlockState();
        }
    }
}