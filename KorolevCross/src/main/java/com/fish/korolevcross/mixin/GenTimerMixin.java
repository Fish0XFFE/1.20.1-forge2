package com.fish.korolevcross.mixin;

import com.fish.korolevcross.gpu.GenStats;
import net.minecraft.world.level.chunk.ChunkAccess;
import net.minecraft.world.level.levelgen.NoiseBasedChunkGenerator;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;

@Mixin(NoiseBasedChunkGenerator.class)
public abstract class GenTimerMixin {
    @Inject(method = "doFill", at = @At("HEAD"))
    private void korolev$begin(CallbackInfoReturnable<ChunkAccess> cir) {
        GenStats.begin();
    }

    @Inject(method = "doFill", at = @At("RETURN"))
    private void korolev$end(CallbackInfoReturnable<ChunkAccess> cir) {
        GenStats.end();
    }
}