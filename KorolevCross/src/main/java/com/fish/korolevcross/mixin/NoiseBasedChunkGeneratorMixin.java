package com.fish.korolevcross.mixin;

import com.fish.korolevcross.config.ModConfig;
import com.fish.korolevcross.gpu.GPUBridge;
import net.minecraft.world.level.StructureManager;
import net.minecraft.world.level.chunk.ChunkAccess;
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

            int chunkX = chunk.getPos().x;
            int chunkZ = chunk.getPos().z;
            int minY = chunk.getMinBuildHeight();
            int maxY = chunk.getMaxBuildHeight();
            int seed = getLevelSeed(randomState);

            short[][][] blockData = GPUBridge.generateChunk(chunkX, chunkZ, minY, maxY, seed);

            if (blockData != null) {
                fillChunk(chunk, blockData, minY, maxY);
                cir.setReturnValue(CompletableFuture.completedFuture(chunk));
            }
        } catch (Exception e) {
            // 失败则回退原版
        }
    }

    private int getLevelSeed(RandomState randomState) {
        try {
            Field field = RandomState.class.getDeclaredField("field_226929_");
            field.setAccessible(true);
            return (int) (long) field.get(randomState);
        } catch (Exception e) {
            try {
                Field field = RandomState.class.getDeclaredField("levelSeed");
                field.setAccessible(true);
                return (int) (long) field.get(randomState);
            } catch (Exception ex) {
                return 0;
            }
        }
    }

    private void fillChunk(ChunkAccess chunk, short[][][] data, int minY, int maxY) {
        for (int s = 0; s < chunk.getSections().length; s++) {
            net.minecraft.world.level.chunk.LevelChunkSection section = chunk.getSections()[s];
            if (section == null) continue;
            int baseY = s * 16 + minY;
            var container = section.getStates();
            for (int x = 0; x < 16; x++) {
                for (int z = 0; z < 16; z++) {
                    for (int y = 0; y < 16; y++) {
                        int worldY = baseY + y;
                        if (worldY >= minY && worldY <= maxY) {
                            short id = data[x][z][worldY - minY];
                            if (id != 0) {
                                container.set(x, y, z, getBlockState(id));
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
            case 1: return net.minecraft.world.level.block.Blocks.STONE.defaultBlockState();
            case 2: return net.minecraft.world.level.block.Blocks.GRASS_BLOCK.defaultBlockState();
            case 3: return net.minecraft.world.level.block.Blocks.DIRT.defaultBlockState();
            case 8: return net.minecraft.world.level.block.Blocks.WATER.defaultBlockState();
            case 12: return net.minecraft.world.level.block.Blocks.BEDROCK.defaultBlockState();
            default: return net.minecraft.world.level.block.Blocks.AIR.defaultBlockState();
        }
    }
}