package com.fish.korolevcross;

import com.fish.korolevcross.config.ModConfig;
import com.fish.korolevcross.gpu.ChunkGpu;
import com.fish.korolevcross.gpu.GenStats;
import com.fish.korolevcross.gpu.NativeBridge;
import net.minecraftforge.common.MinecraftForge;
import net.minecraftforge.event.server.ServerStoppingEvent;
import net.minecraftforge.eventbus.api.SubscribeEvent;
import net.minecraftforge.fml.ModLoadingContext;
import net.minecraftforge.fml.common.Mod;
import net.minecraftforge.fml.config.ModConfig.Type;
import net.minecraftforge.fml.event.lifecycle.FMLCommonSetupEvent;
import net.minecraftforge.fml.javafmlmod.FMLJavaModLoadingContext;
import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;

@Mod(KorolevCross.MODID)
public class KorolevCross {
    public static final String MODID = "korolevcross";
    public static final Logger LOGGER = LogManager.getLogger(MODID);

    public KorolevCross() {
        ModLoadingContext.get().registerConfig(Type.COMMON, ModConfig.SPEC, "korolevcross-common.toml");
        FMLJavaModLoadingContext.get().getModEventBus().addListener(this::commonSetup);
        MinecraftForge.EVENT_BUS.register(this);
    }

    private void commonSetup(FMLCommonSetupEvent event) {
        event.enqueueWork(() -> {
            if (!ModConfig.enabled()) {
                LOGGER.info("KorolevCross disabled by config");
                return;
            }
            if (NativeBridge.load()) {
                LOGGER.info("KorolevCross GPU density engine ready on {}", NativeBridge.nativeDeviceName());
            } else {
                LOGGER.warn("KorolevCross GPU unavailable ({}), chunk generation stays vanilla", NativeBridge.failureReason());
            }
        });
    }

    @SubscribeEvent
    public void onServerStopping(ServerStoppingEvent event) {
        GenStats.report();
        long chunks = ChunkGpu.acceleratedChunks();
        long nanos = ChunkGpu.spentNanos();
        if (chunks > 0) {
            LOGGER.info("KorolevCross accelerated {} chunks, {} ms total, {} us per chunk", chunks, nanos / 1_000_000L,
                    nanos / 1000L / chunks);
        }
    }
}
