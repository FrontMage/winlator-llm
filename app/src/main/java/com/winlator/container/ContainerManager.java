package com.winlator.container;

import android.content.Context;
import android.os.Handler;

import com.winlator.R;
import com.winlator.core.Callback;
import com.winlator.core.FileUtils;
import com.winlator.core.OnExtractFileListener;
import com.winlator.core.TarCompressorUtils;
import com.winlator.core.WineInfo;
import com.winlator.core.WineUtils;
import com.winlator.xenvironment.ImageFs;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.io.File;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.concurrent.Executors;

public class ContainerManager {
    private final ArrayList<Container> containers = new ArrayList<>();
    private int maxContainerId = 0;
    private final File homeDir;
    private final Context context;

    public ContainerManager(Context context) {
        this.context = context;
        File rootDir = ImageFs.find(context).getRootDir();
        homeDir = new File(rootDir, "home");
        loadContainers();
    }

    public ArrayList<Container> getContainers() {
        return containers;
    }

    private void loadContainers() {
        containers.clear();
        maxContainerId = 0;

        try {
            File[] files = homeDir.listFiles();
            if (files != null) {
                for (File file : files) {
                    if (file.isDirectory()) {
                        if (file.getName().startsWith(ImageFs.USER+"-")) {
                            Container container = new Container(Integer.parseInt(file.getName().replace(ImageFs.USER+"-", "")));
                            container.setRootDir(new File(homeDir, ImageFs.USER+"-"+container.id));
                            JSONObject data = new JSONObject(FileUtils.readString(container.getConfigFile()));
                            container.loadData(data);
                            containers.add(container);
                            maxContainerId = Math.max(maxContainerId, container.id);
                        }
                    }
                }
            }
        }
        catch (JSONException e) {}
    }

    public void activateContainer(Container container) {
        container.setRootDir(new File(homeDir, ImageFs.USER+"-"+container.id));
        File file = new File(homeDir, ImageFs.USER);
        file.delete();
        FileUtils.symlink("./"+ImageFs.USER+"-"+container.id, file.getPath());
    }

    public void createContainerAsync(final JSONObject data, Callback<Container> callback) {
        final Handler handler = new Handler();
        Executors.newSingleThreadExecutor().execute(() -> {
            final Container container = createContainer(data);
            handler.post(() -> callback.call(container));
        });
    }

    public void duplicateContainerAsync(Container container, Runnable callback) {
        final Handler handler = new Handler();
        Executors.newSingleThreadExecutor().execute(() -> {
            duplicateContainer(container);
            handler.post(callback);
        });
    }

    public void removeContainerAsync(Container container, Runnable callback) {
        final Handler handler = new Handler();
        Executors.newSingleThreadExecutor().execute(() -> {
            removeContainer(container);
            handler.post(callback);
        });
    }

    private Container createContainer(JSONObject data) {
        try {
            int id = maxContainerId + 1;
            data.put("id", id);

            File containerDir = new File(homeDir, ImageFs.USER+"-"+id);
            if (!containerDir.mkdirs()) return null;

            Container container = new Container(id);
            container.setRootDir(containerDir);
            container.loadData(data);

            // New container creation: if the UI didn't specify "wineVersion" (common when only one arm64ec
            // Wine is installed), pick the first available arm64ec Wine. Otherwise we fall back to MAIN_WINE_VERSION
            // and extract the wrong container pattern.
            String wineVersion;
            if (data.has("wineVersion")) {
                wineVersion = data.getString("wineVersion");
            } else {
                WineInfo arm64ec = WineUtils.getFirstArm64ECWineInfo(context);
                wineVersion = arm64ec != null ? arm64ec.identifier() : WineInfo.MAIN_WINE_VERSION.identifier();
                data.put("wineVersion", wineVersion);
            }
            container.setWineVersion(wineVersion);

            if (!extractContainerPatternFile(container.getWineVersion(), containerDir, null)) {
                FileUtils.delete(containerDir);
                return null;
            }

            container.saveData();
            maxContainerId++;
            containers.add(container);
            return container;
        }
        catch (JSONException e) {}
        return null;
    }

    private void duplicateContainer(Container srcContainer) {
        int id = maxContainerId + 1;

        File dstDir = new File(homeDir, ImageFs.USER+"-"+id);
        if (!dstDir.mkdirs()) return;

        if (!FileUtils.copy(srcContainer.getRootDir(), dstDir, (file) -> FileUtils.chmod(file, 0771))) {
            FileUtils.delete(dstDir);
            return;
        }

        Container dstContainer = new Container(id);
        dstContainer.setRootDir(dstDir);
        dstContainer.setName(srcContainer.getName()+" ("+context.getString(R.string.copy)+")");
        dstContainer.setScreenSize(srcContainer.getScreenSize());
        dstContainer.setEnvVars(srcContainer.getEnvVars());
        dstContainer.setCPUList(srcContainer.getCPUList());
        dstContainer.setCPUListWoW64(srcContainer.getCPUListWoW64());
        dstContainer.setGraphicsDriver(srcContainer.getGraphicsDriver());
        dstContainer.setDXWrapper(srcContainer.getDXWrapper());
        dstContainer.setDXWrapperConfig(srcContainer.getDXWrapperConfig());
        dstContainer.setAudioDriver(srcContainer.getAudioDriver());
        dstContainer.setWinComponents(srcContainer.getWinComponents());
        dstContainer.setDrives(srcContainer.getDrives());
        dstContainer.setShowFPS(srcContainer.isShowFPS());
        dstContainer.setWoW64Mode(srcContainer.isWoW64Mode());
        dstContainer.setStartupSelection(srcContainer.getStartupSelection());
        dstContainer.setFEXCoreVersion(srcContainer.getFEXCoreVersion());
        dstContainer.setFEXCorePreset(srcContainer.getFEXCorePreset());
        dstContainer.setDesktopTheme(srcContainer.getDesktopTheme());
        dstContainer.saveData();

        maxContainerId++;
        containers.add(dstContainer);
    }

    private void removeContainer(Container container) {
        if (FileUtils.delete(container.getRootDir())) containers.remove(container);
    }

    public ArrayList<Shortcut> loadShortcuts() {
        ArrayList<Shortcut> shortcuts = new ArrayList<>();
        for (Container container : containers) {
            File desktopDir = container.getDesktopDir();
            File[] files = desktopDir.listFiles();
            if (files != null) {
                for (File file : files) {
                    if (file.getName().endsWith(".desktop")) shortcuts.add(new Shortcut(container, file));
                }
            }
        }

        shortcuts.sort(Comparator.comparing(a -> a.name));
        return shortcuts;
    }

    public int getNextContainerId() {
        return maxContainerId + 1;
    }

    public Container getContainerById(int id) {
        for (Container container : containers) if (container.id == id) return container;
        return null;
    }

    private void extractCommonDlls(String srcName, String dstName, JSONObject commonDlls, File containerDir, OnExtractFileListener onExtractFileListener) throws JSONException {
        File srcDir = new File(ImageFs.find(context).getRootDir(), "/opt/wine/lib/wine/"+srcName);
        JSONArray dlnames = commonDlls.getJSONArray(dstName);

        for (int i = 0; i < dlnames.length(); i++) {
            String dlname = dlnames.getString(i);
            File dstFile = new File(containerDir, ".wine/drive_c/windows/"+dstName+"/"+dlname);
            if (onExtractFileListener != null) {
                dstFile = onExtractFileListener.onExtractFile(dstFile, 0);
                if (dstFile == null) continue;
            }
            FileUtils.copy(new File(srcDir, dlname), dstFile);
        }
    }

    // Align with Winlator-Ludashi/bionic container creation:
    // After extracting the prefix skeleton, populate C:\\windows\\system32 and syswow64 from the
    // selected Wine's built-in PE DLL sets.
    private void extractCommonDllsFromWine(
            WineInfo wineInfo,
            String srcName,
            String dstName,
            File containerDir,
            OnExtractFileListener onExtractFileListener
    ) {
        if (wineInfo == null || wineInfo.path == null || wineInfo.path.isEmpty()) return;

        File srcDir = new File(wineInfo.path + "/lib/wine/" + srcName);
        File[] srcFiles = srcDir.listFiles(file -> file != null && file.isFile());
        if (srcFiles == null) return;

        File dstDir = new File(containerDir, ".wine/drive_c/windows/" + dstName);
        if (!dstDir.isDirectory()) dstDir.mkdirs();

        for (File file : srcFiles) {
            String dllName = file.getName();
            File srcFile = file;

            // Ludashi/bionic special-case: use the i386 iexplore.exe on arm64ec.
            if ("iexplore.exe".equals(dllName) && wineInfo.isArm64EC() && "aarch64-windows".equals(srcName)) {
                File fallback = new File(wineInfo.path + "/lib/wine/i386-windows/iexplore.exe");
                if (fallback.isFile()) srcFile = fallback;
            }

            // Ludashi/bionic skips these in common extraction.
            if ("tabtip.exe".equals(dllName) || "icu.dll".equals(dllName)) continue;

            File dstFile = new File(dstDir, dllName);
            if (dstFile.exists()) continue;

            if (onExtractFileListener != null) {
                dstFile = onExtractFileListener.onExtractFile(dstFile, 0);
                if (dstFile == null) continue;
            }

            FileUtils.copy(srcFile, dstFile);
        }
    }

    public boolean extractContainerPatternFile(String wineVersion, File containerDir, OnExtractFileListener onExtractFileListener) {
        if (WineInfo.isMainWineVersion(wineVersion)) {
            boolean result = TarCompressorUtils.extract(TarCompressorUtils.Type.ZSTD, context, "container_pattern.tzst", containerDir, onExtractFileListener);

            if (result) {
                try {
                    JSONObject commonDlls = new JSONObject(FileUtils.readString(context, "common_dlls.json"));
                    extractCommonDlls("x86_64-windows", "system32", commonDlls, containerDir, onExtractFileListener);
                    extractCommonDlls("i386-windows", "syswow64", commonDlls, containerDir, onExtractFileListener);
                }
                catch (JSONException e) {
                    return false;
                }
            }

            return result;
        }

        // Non-main versions (including arm64ec): follow Ludashi/bionic extraction order.
        WineInfo wineInfo = WineInfo.fromIdentifier(context, wineVersion);

        // 1) Prefer per-wine container pattern from assets if present.
        String containerPatternAsset = wineVersion + "_container_pattern.tzst";
        boolean result = TarCompressorUtils.extract(
                TarCompressorUtils.Type.ZSTD,
                context,
                containerPatternAsset,
                containerDir,
                onExtractFileListener
        );

        // 2) Fallback to prefixPack shipped inside the wine package.
        if (!result && wineInfo != null && wineInfo.path != null && !wineInfo.path.isEmpty()) {
            File prefixPackFile = new File(wineInfo.path, "prefixPack.txz");
            if (prefixPackFile.isFile()) {
                result = TarCompressorUtils.extract(TarCompressorUtils.Type.XZ, prefixPackFile, containerDir);
            }
        }

        if (result) {
            if (wineInfo != null && wineInfo.isArm64EC()) {
                extractCommonDllsFromWine(wineInfo, "aarch64-windows", "system32", containerDir, onExtractFileListener);
            }
            else {
                extractCommonDllsFromWine(wineInfo, "x86_64-windows", "system32", containerDir, onExtractFileListener);
            }
            extractCommonDllsFromWine(wineInfo, "i386-windows", "syswow64", containerDir, onExtractFileListener);
        }

        return result;
    }
}
