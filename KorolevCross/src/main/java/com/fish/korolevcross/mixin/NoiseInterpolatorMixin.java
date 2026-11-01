package com.fish.korolevcross.mixin;

import com.fish.korolevcross.KorolevCross;
import com.fish.korolevcross.config.ModConfig;
import com.fish.korolevcross.gpu.ChunkGpu;
import com.fish.korolevcross.gpu.GpuColumns;
import com.fish.korolevcross.gpu.GpuValuesHolder;
import net.minecraft.world.level.levelgen.DensityFunction;
import net.minecraft.world.level.levelgen.DensityFunctions;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Unique;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

import java.util.concurrent.atomic.AtomicLong;

@Mixin(targets = "net.minecraft.world.level.levelgen.NoiseChunk$NoiseInterpolator")
public class NoiseInterpolatorMixin implements GpuValuesHolder {
    @Unique
    private static final AtomicLong KOROLEV_CHECKED = new AtomicLong();
    @Unique
    private static final AtomicLong KOROLEV_MISMATCH = new AtomicLong();
    @Unique
    private static volatile double korolev$maxDiff;
    @Unique
    private GpuColumns korolev$columns;
    @Unique
    private int korolev$lastX = Integer.MIN_VALUE;
    @Unique
    private int korolev$z;

    @Override
    public void korolev$setColumns(GpuColumns columns) {
        this.korolev$columns = columns;
        this.korolev$lastX = Integer.MIN_VALUE;
        this.korolev$z = 0;
    }

    @Override
    public GpuColumns korolev$columns() {
        return this.korolev$columns;
    }

    @Inject(method = "fillArray", at = @At("HEAD"), cancellable = true)
    private void korolev$fillArray(double[] out, DensityFunction.ContextProvider provider, CallbackInfo ci) {
        GpuColumns columns = this.korolev$columns;
        if (columns == null || out == null || out.length != columns.columnLength()) {
            return;
        }
        Integer cellX = ChunkGpu.CELL_X.get();
        if (cellX == null) {
            return;
        }
        int x = cellX - columns.firstCellX;
        if (x < 0 || x > columns.cellCountXZ) {
            return;
        }
        if (x != this.korolev$lastX) {
            this.korolev$lastX = x;
            this.korolev$z = 0;
        }
        if (this.korolev$z > columns.cellCountXZ) {
            return;
        }
        if (ModConfig.debug()) {
            korolev$check(columns, x, this.korolev$z, out, provider);
        }
        columns.copyColumn(x, this.korolev$z, out);
        this.korolev$z++;
        ci.cancel();
    }

    @Unique
    private void korolev$check(GpuColumns columns, int x, int z, double[] out, DensityFunction.ContextProvider provider) {
        double[] gpu = new double[out.length];
        columns.copyColumn(x, z, gpu);
        try {
            ((DensityFunctions.MarkerOrMarked) (Object) this).wrapped().fillArray(out, provider);
        } catch (Throwable t) {
            KOROLEV_CHECKED.set(Long.MAX_VALUE);
            KorolevCross.LOGGER.warn("korolevcross: vanilla reference evaluation failed", t);
            return;
        }
        double worst = 0.0D;
        int bad = 0;
        for (int i = 0; i < gpu.length; i++) {
            double diff = Math.abs(gpu[i] - out[i]);
            if (!(diff <= 0.0D)) {
                bad++;
                if (diff > worst) {
                    worst = diff;
                }
            }
        }
        if (bad > 0) {
            KOROLEV_MISMATCH.incrementAndGet();
            double previous = korolev$maxDiff;
            if (worst > previous) {
                korolev$maxDiff = worst;
            }
        }
        long checked = KOROLEV_CHECKED.incrementAndGet();
        if (checked % 4096L == 0L) {
            KorolevCross.LOGGER.info("korolevcross parity: {} columns checked, {} mismatched, max diff {}, island {}",
                    checked, KOROLEV_MISMATCH.get(), korolev$maxDiff, columns.endIsland);
        }
    }
}
