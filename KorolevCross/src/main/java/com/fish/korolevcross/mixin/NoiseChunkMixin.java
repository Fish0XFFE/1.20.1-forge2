package com.fish.korolevcross.mixin;

import com.fish.korolevcross.gpu.ChunkGpu;
import net.minecraft.world.level.levelgen.NoiseChunk;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

@Mixin(NoiseChunk.class)
public abstract class NoiseChunkMixin {
    @Inject(method = "initializeForFirstCellX", at = @At("HEAD"))
    private void korolev$prepare(CallbackInfo ci) {
        ChunkGpu.prepare((NoiseChunk) (Object) this);
    }

    @Inject(method = "fillSlice", at = @At("HEAD"))
    private void korolev$fillSlice(boolean first, int cellX, CallbackInfo ci) {
        ChunkGpu.CELL_X.set(cellX);
    }
}
