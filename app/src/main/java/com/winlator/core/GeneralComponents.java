package com.winlator.core;

import android.content.Context;

import com.winlator.xenvironment.ImageFs;

import java.io.File;

public final class GeneralComponents {
    public enum Type {
        TURNIP("graphics_driver", "turnip"),
        ZINK("graphics_driver", "zink"),
        VIRGL("graphics_driver", "virgl");

        private final String assetDir;
        private final String filePrefix;

        Type(String assetDir, String filePrefix) {
            this.assetDir = assetDir;
            this.filePrefix = filePrefix;
        }
    }

    private GeneralComponents() {}

    public static void extractFile(Type type, Context context, String identifier, String defaultVersion) {
        if (type == null || context == null) return;
        String version = (identifier == null || identifier.isEmpty()) ? defaultVersion : identifier;
        if (version == null || version.isEmpty()) return;

        File rootDir = ImageFs.find(context).getRootDir();
        String assetPath = type.assetDir + "/" + type.filePrefix + "-" + version + ".tzst";
        boolean ok = TarCompressorUtils.extract(TarCompressorUtils.Type.ZSTD, context, assetPath, rootDir);
        if (!ok && defaultVersion != null && !defaultVersion.equals(version)) {
            String fallback = type.assetDir + "/" + type.filePrefix + "-" + defaultVersion + ".tzst";
            TarCompressorUtils.extract(TarCompressorUtils.Type.ZSTD, context, fallback, rootDir);
        }
    }
}
