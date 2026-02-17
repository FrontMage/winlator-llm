package com.winlator.core;

public abstract class DefaultVersion {
    public static final String FEXCORE = "2508";
    // Default runtime migrated to Proton 10 arm64ec.
    public static final String ARM64EC_PROTON = "10";
    public static final String TURNIP = "25.1.0";
    // Adrenotools "turnip" driver bundle. Keep this decoupled from TURNIP (Mesa ICD),
    // so we can A/B test specific Adrenotools builds without touching Mesa packages.
    // Adrenotools driver bundle to ship by default (AdrenoToolsDrivers releases).
    public static final String ADRENOTOOLS_TURNIP = "26.0.0";
    public static final String ZINK = "22.2.5";
    public static final String VIRGL = "23.1.9";
    // Ludashi ships DXVK 2.3.x arm64ec GPLasync builds; prefer that baseline for Adreno 6xx stability.
    public static final String DXVK = "2.3.1-arm64ec-gplasync";
    public static final String D8VK = "1.0";
    public static final String VKD3D = "2.14.1";
}
