package com.winlator.contents;

import android.content.Context;
import android.util.Log;

import com.winlator.core.EnvVars;
import com.winlator.core.FileUtils;
import com.winlator.core.TarCompressorUtils;
import com.winlator.xenvironment.ImageFs;

import org.json.JSONException;
import org.json.JSONObject;

import java.io.File;

/**
 * Minimal Adrenotools driver support (bionic/Ludashi-aligned).
 *
 * We only need "extract built-in driver from assets" + "set env vars" so the Vulkan wrapper can
 * load a modern driver on devices where the system Vulkan is too old for DXVK.
 */
public class AdrenotoolsManager {
    private static final String TAG = "AdrenotoolsManager";

    private final Context context;
    private final File adrenotoolsContentDir;

    public AdrenotoolsManager(Context context) {
        this.context = context;
        this.adrenotoolsContentDir = new File(context.getFilesDir(), "contents/adrenotools");
        if (!adrenotoolsContentDir.exists()) adrenotoolsContentDir.mkdirs();
    }

    private File getDriverDir(String driverId) {
        return new File(adrenotoolsContentDir, driverId);
    }

    private String getLibraryName(String driverId) {
        try {
            File meta = new File(getDriverDir(driverId), "meta.json");
            if (!meta.isFile()) return "";
            JSONObject json = new JSONObject(FileUtils.readString(meta));
            return json.optString("libraryName", "");
        } catch (JSONException ignored) {
            return "";
        }
    }

    public boolean extractDriverFromResources(String driverId) {
        File dst = getDriverDir(driverId);
        if (dst.isDirectory() && new File(dst, "meta.json").isFile()) return true;

        FileUtils.delete(dst);
        if (!dst.mkdirs()) return false;

        String assetPath = "graphics_driver/adrenotools-" + driverId + ".tzst";
        Log.i(TAG, "Extracting " + assetPath + " -> " + dst.getAbsolutePath());
        boolean ok = TarCompressorUtils.extract(TarCompressorUtils.Type.ZSTD, context, assetPath, dst);
        if (!ok) FileUtils.delete(dst);
        return ok;
    }

    public void setDriverById(EnvVars envVars, ImageFs imageFs, String driverId) {
        if (driverId == null || driverId.isEmpty()) return;
        if (!extractDriverFromResources(driverId)) return;

        String libraryName = getLibraryName(driverId);
        if (libraryName.isEmpty()) return;

        // The wrapper hook dlopen()s the driver from ADRENOTOOLS_DRIVER_PATH.
        String driverPath = getDriverDir(driverId).getAbsolutePath() + "/";
        envVars.put("ADRENOTOOLS_DRIVER_PATH", driverPath);
        envVars.put("ADRENOTOOLS_DRIVER_NAME", libraryName);
        envVars.put("ADRENOTOOLS_HOOKS_PATH", imageFs.getLibDir().getAbsolutePath());
    }
}

