package com.winlator.contentdialog;

import android.content.Context;
import android.view.View;
import android.widget.Spinner;

import com.winlator.R;
import com.winlator.core.AppUtils;
import com.winlator.core.DefaultVersion;
import com.winlator.core.EnvVars;
import com.winlator.core.FileUtils;
import com.winlator.core.KeyValueSet;
import com.winlator.core.StringUtils;
import com.winlator.xenvironment.ImageFs;

import java.io.File;

public class DXVKConfigDialog extends ContentDialog {
    public static final String DEFAULT_CONFIG = "version="+DefaultVersion.DXVK+",framerate=0,maxDeviceMemory=0";

    public DXVKConfigDialog(View anchor) {
        super(anchor.getContext(), R.layout.dxvk_config_dialog);
        setIcon(R.drawable.icon_settings);
        setTitle("DXVK "+anchor.getContext().getString(R.string.configuration));

        final Spinner sVersion = findViewById(R.id.SVersion);
        final Spinner sFramerate = findViewById(R.id.SFramerate);
        final Spinner sMaxDeviceMemory = findViewById(R.id.SMaxDeviceMemory);

        KeyValueSet config = parseConfig(anchor.getTag());
        AppUtils.setSpinnerSelectionFromIdentifier(sVersion, config.get("version"));
        AppUtils.setSpinnerSelectionFromIdentifier(sFramerate, config.get("framerate"));
        AppUtils.setSpinnerSelectionFromNumber(sMaxDeviceMemory, config.get("maxDeviceMemory"));

        setOnConfirmCallback(() -> {
            // Keep version as an identifier (supports suffixes like "2.3.1-arm64ec-gplasync").
            config.put("version", StringUtils.parseIdentifier(sVersion.getSelectedItem()));
            config.put("framerate", StringUtils.parseNumber(sFramerate.getSelectedItem()));
            config.put("maxDeviceMemory", StringUtils.parseNumber(sMaxDeviceMemory.getSelectedItem()));
            anchor.setTag(config.toString());
        });
    }

    public static KeyValueSet parseConfig(Object config) {
        String data = config != null && !config.toString().isEmpty() ? config.toString() : DEFAULT_CONFIG;
        return new KeyValueSet(data);
    }

    public static void setEnvVars(Context context, KeyValueSet config, EnvVars envVars) {
        // DXVK runs inside Wine but uses Win32 file APIs. When DXVK_STATE_CACHE_PATH is a POSIX
        // path, Wine will treat it as a host path. Our sessions use absolute Android paths
        // (not a chroot), so a guest-relative "/home/xuser/.cache" path doesn't exist.
        //
        // Align with Ludashi: point it at the real imagefs path on the host.
        File rootDir = ImageFs.find(context).getRootDir();
        String cachePath = rootDir.getPath() + ImageFs.CACHE_PATH;
        envVars.put("DXVK_STATE_CACHE_PATH", cachePath);
        // Best-effort: ensure the directory exists so DXVK can create the state cache file.
        //noinspection ResultOfMethodCallIgnored
        new File(cachePath).mkdirs();

        File dxvkConfigFile = new File(rootDir, ImageFs.CONFIG_PATH+"/dxvk.conf");

        String content = "";

        String maxDeviceMemory = config.get("maxDeviceMemory");
        if (!maxDeviceMemory.isEmpty() && !maxDeviceMemory.equals("0")) {
            content += "dxgi.maxDeviceMemory = "+maxDeviceMemory+"\n";
            content += "dxgi.maxSharedMemory = "+maxDeviceMemory+"\n";
        }

        String framerate = config.get("framerate");
        if (!framerate.isEmpty() && !framerate.equals("0")) {
            content += "dxgi.maxFrameRate = "+framerate+"\n";
            content += "d3d9.maxFrameRate = "+framerate+"\n";
        }

        FileUtils.delete(dxvkConfigFile);
        if (!content.isEmpty() && FileUtils.writeString(dxvkConfigFile, content)) {
            envVars.put("DXVK_CONFIG_FILE", ImageFs.CONFIG_PATH+"/dxvk.conf");
        }
    }
}
