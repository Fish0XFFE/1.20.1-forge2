package com.fish.korolevcross;

import com.fish.korolevcross.config.ModConfig;
import com.fish.korolevcross.gpu.GPUBridge;
import net.minecraftforge.common.MinecraftForge;
import net.minecraftforge.event.server.ServerStartingEvent;
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

    private void commonSetup(final FMLCommonSetupEvent event) {
        event.enqueueWork(() -> {
            LOGGER.info("KorolevCross initializing GPU acceleration...");
            try {
                GPUBridge.extractAndLoadLibrary();
                GPUBridge.initialize();
                LOGGER.info("CUDA and OptiX initialized");
            } catch (Throwable t) {
                LOGGER.error("GPU init failed, chunk generation will use vanilla", t);
            }
        });
    }

    @SubscribeEvent
    public void onServerStarting(ServerStartingEvent event) {
        LOGGER.info("KorolevCross enabled on server");
    }
}