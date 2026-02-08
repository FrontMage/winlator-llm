package com.winlator.xenvironment.components;

import android.content.Context;
import android.content.SharedPreferences;
import android.net.ConnectivityManager;
import android.net.LinkProperties;
import android.net.Network;
import android.os.Process;
import android.util.Log;

import androidx.preference.PreferenceManager;

import com.winlator.core.Callback;
import com.winlator.core.DefaultVersion;
import com.winlator.core.EnvVars;
import com.winlator.core.ProcessHelper;
import com.winlator.core.TarCompressorUtils;
import com.winlator.fexcore.FEXCorePreset;
import com.winlator.fexcore.FEXCorePresetManager;
import com.winlator.xconnector.UnixSocketConfig;
import com.winlator.xenvironment.EnvironmentComponent;
import com.winlator.xenvironment.ImageFs;

import java.io.BufferedWriter;
import java.io.File;
import java.io.FileWriter;
import java.io.IOException;
import java.net.InetAddress;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

public class GuestProgramLauncherComponent extends EnvironmentComponent {
    private static final String TAG = "GuestLauncher";
    private String guestExecutable;
    private static int pid = -1;
    private String[] bindingPaths;
    private EnvVars envVars;
    private String fexcoreVersion = DefaultVersion.FEXCORE;
    private String fexcorePreset = FEXCorePreset.INTERMEDIATE;
    private Callback<Integer> terminationCallback;
    private static final Object lock = new Object();
    private boolean wow64Mode = true;
    private boolean arm64ecWine = false;

    private static String ensureWineDebugChannels(String wineDebug, String... channels) {
        if (wineDebug == null) wineDebug = "";
        wineDebug = wineDebug.trim();

        Set<String> enabled = new HashSet<>();
        Set<String> disabled = new HashSet<>();

        if (!wineDebug.isEmpty()) {
            String[] parts = wineDebug.split(",");
            for (String part : parts) {
                String token = part.trim();
                if (token.isEmpty()) continue;

                char prefix = token.charAt(0);
                String name = (prefix == '+' || prefix == '-') ? token.substring(1) : token;
                if (name.isEmpty()) continue;

                if (prefix == '-') disabled.add(name);
                else enabled.add(name);
            }
        }

        String out = wineDebug;
        for (String ch : channels) {
            if (ch == null) continue;
            ch = ch.trim();
            if (ch.isEmpty()) continue;
            if (enabled.contains(ch) || disabled.contains(ch)) continue;

            if (out.isEmpty()) out = "+" + ch;
            else out += ",+" + ch;
            enabled.add(ch);
        }

        return out;
    }

    @Override
    public void start() {
        synchronized (lock) {
            stop();
            extractFexcoreFiles();
            pid = execGuestProgram();
        }
    }

    @Override
    public void stop() {
        synchronized (lock) {
            if (pid != -1) {
                Process.killProcess(pid);
                pid = -1;
            }
        }
    }

    public Callback<Integer> getTerminationCallback() {
        return terminationCallback;
    }

    public void setTerminationCallback(Callback<Integer> terminationCallback) {
        this.terminationCallback = terminationCallback;
    }

    public String getGuestExecutable() {
        return guestExecutable;
    }

    public void setGuestExecutable(String guestExecutable) {
        this.guestExecutable = guestExecutable;
    }

    public boolean isWoW64Mode() {
        return wow64Mode;
    }

    public void setWoW64Mode(boolean wow64Mode) {
        this.wow64Mode = wow64Mode;
    }

    public void setArm64ecWine(boolean arm64ecWine) {
        this.arm64ecWine = arm64ecWine;
    }

    public String[] getBindingPaths() {
        return bindingPaths;
    }

    public void setBindingPaths(String[] bindingPaths) {
        this.bindingPaths = bindingPaths;
    }

    public EnvVars getEnvVars() {
        return envVars;
    }

    public void setEnvVars(EnvVars envVars) {
        this.envVars = envVars;
    }

    public void setFEXCoreVersion(String fexcoreVersion) {
        this.fexcoreVersion = fexcoreVersion != null ? fexcoreVersion : DefaultVersion.FEXCORE;
    }

    public void setFEXCorePreset(String fexcorePreset) {
        this.fexcorePreset = fexcorePreset != null ? fexcorePreset : FEXCorePreset.INTERMEDIATE;
    }

    private int execGuestProgram() {
        Context context = environment.getContext();
        ImageFs imageFs = environment.getImageFs();
        File rootDir = imageFs.getRootDir();
        File tmpDir = environment.getTmpDir();
        String nativeLibraryDir = context.getApplicationInfo().nativeLibraryDir;

        EnvVars envVars = new EnvVars();
        envVars.putAll(FEXCorePresetManager.getEnvVars(context, fexcorePreset));
        envVars.put("HOME", ImageFs.HOME_PATH);
        envVars.put("USER", ImageFs.USER);
        envVars.put("TMPDIR", "/tmp");
        envVars.put("DISPLAY", ":0");
        String winePath = imageFs.getWinePath();
        String rootPath = rootDir.getPath();
        boolean isArm64ecWine = this.arm64ecWine || (winePath != null && winePath.contains("arm64ec"));
        String winePathResolved = winePath != null ? winePath : "";
        if (isArm64ecWine) {
            if (!winePathResolved.isEmpty() && !winePathResolved.startsWith("/")) {
                winePathResolved = rootPath + "/" + winePathResolved;
            }
        }
        String wineBinPath = (isArm64ecWine ? winePathResolved : winePath) + "/bin";

        if (isArm64ecWine) {
            // Align with bionic build: use absolute rootfs paths and minimal bionic loader path.
            envVars.put("HOME", rootPath + ImageFs.HOME_PATH);
            envVars.put("USER", ImageFs.USER);
            File usrTmpDir = new File(rootDir, "/usr/tmp");
            if (!usrTmpDir.isDirectory()) usrTmpDir.mkdirs();
            envVars.put("TMPDIR", usrTmpDir.getAbsolutePath());
            envVars.put("XDG_DATA_DIRS", rootPath + "/usr/share");
            envVars.put("XDG_CONFIG_DIRS", rootPath + "/usr/etc/xdg");
            envVars.put("GST_PLUGIN_PATH", rootPath + "/usr/lib/gstreamer-1.0");
            envVars.put("FONTCONFIG_PATH", rootPath + "/usr/etc/fonts");
            envVars.put("VK_LAYER_PATH", rootPath + "/usr/share/vulkan/implicit_layer.d:" + rootPath + "/usr/share/vulkan/explicit_layer.d");
            envVars.put("WRAPPER_LAYER_PATH", rootPath + "/usr/lib");
            envVars.put("WRAPPER_CACHE_PATH", rootPath + "/usr/var/cache");
            envVars.put("WINE_NO_DUPLICATE_EXPLORER", "1");
            envVars.put("PREFIX", rootPath + "/usr");
            envVars.put("DISPLAY", ":0");
            envVars.put("WINE_DISABLE_FULLSCREEN_HACK", "1");
            envVars.put("GST_PLUGIN_FEATURE_RANK", "ximagesink:3000");
            envVars.put("ALSA_CONFIG_PATH", rootPath + "/usr/share/alsa/alsa.conf:" + rootPath + "/usr/etc/alsa/conf.d/android_aserver.conf");
            envVars.put("ALSA_PLUGIN_DIR", rootPath + "/usr/lib/alsa-lib");
            envVars.put("OPENSSL_CONF", rootPath + "/usr/etc/tls/openssl.cnf");
            envVars.put("SSL_CERT_FILE", rootPath + "/usr/etc/tls/cert.pem");
            envVars.put("SSL_CERT_DIR", rootPath + "/usr/etc/tls/certs");
            envVars.put("WINE_X11FORCEGLX", "1");
            envVars.put("WINE_GST_NO_GL", "1");
            envVars.put("SteamGameId", "0");
            envVars.put("PROTON_AUDIO_CONVERT", "0");
            envVars.put("PROTON_VIDEO_CONVERT", "0");
            envVars.put("PROTON_DEMUX", "0");

            envVars.put("PATH", wineBinPath + ":" + rootPath + "/usr/bin");
            envVars.put(
                    "LD_LIBRARY_PATH",
                    rootPath + "/usr/lib" + ":/system/lib64"
            );
        } else {
            envVars.put("PATH", wineBinPath + ":/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin");
            envVars.put("LD_LIBRARY_PATH", "/usr/lib:/usr/lib/aarch64-linux-gnu:/usr/lib/arm-linux-gnueabihf");
        }
        envVars.put("ANDROID_SYSVSHM_SERVER", UnixSocketConfig.SYSVSHM_SERVER_PATH);
        envVars.put("WINE_NEW_NDIS", "1");

        String dnsOverride = "";
        ConnectivityManager connectivityManager =
                (ConnectivityManager) context.getSystemService(Context.CONNECTIVITY_SERVICE);
        if (connectivityManager != null) {
            Network activeNetwork = connectivityManager.getActiveNetwork();
            if (activeNetwork != null) {
                LinkProperties linkProperties = connectivityManager.getLinkProperties(activeNetwork);
                if (linkProperties != null) {
                    List<InetAddress> dnsServers = linkProperties.getDnsServers();
                    if (dnsServers != null && !dnsServers.isEmpty()) {
                        dnsOverride = dnsServers.get(0).getHostAddress();
                    }
                }
            }
        }
        if (!dnsOverride.isEmpty()) {
            envVars.put("ANDROID_RESOLV_DNS", dnsOverride);
        } else {
            envVars.put("ANDROID_RESOLV_DNS", "8.8.4.4");
        }

        String ldPreload = "";
        File sysvshmLib = new File(imageFs.getLibDir(), "libandroid-sysvshm.so");
        if (sysvshmLib.isFile()) {
            ldPreload = sysvshmLib.getAbsolutePath();
        }
        envVars.put("LD_PRELOAD", ldPreload);

        if (this.envVars != null) {
            if (this.envVars.has("MANGOHUD")) this.envVars.remove("MANGOHUD");
            if (this.envVars.has("MANGOHUD_CONFIG")) this.envVars.remove("MANGOHUD_CONFIG");
            envVars.putAll(this.envVars);
        }

        // ARM64EC/WoW64 quirk profile (Win-on-ARM style app profile):
        // Some titles (WoW is a known repro) do SMC/patching and/or hit tricky atomic patterns during startup.
        // On Windows this is typically handled via an app profile. In our "FEX-only" direction, prefer
        // correctness for WoW64 sessions unless the user explicitly overrides these knobs.
        //
        // Note: We can't reliably detect "wow.exe" here because the container starts with wfm.exe and games
        // are typically launched from inside Explorer. Apply these defaults for WoW64 sessions globally.
        final boolean userSpecifiedSMCChecks = this.envVars != null && this.envVars.has("FEX_SMC_CHECKS");
        final boolean userSpecifiedMultiblock = this.envVars != null && this.envVars.has("FEX_MULTIBLOCK");
        if (isArm64ecWine && wow64Mode) {
            if (!userSpecifiedSMCChecks) {
                // See FEX upstream discussion around Win-on-ARM app profiles (e.g. issue #5133).
                envVars.put("FEX_SMC_CHECKS", "full");
            }
            if (!userSpecifiedMultiblock) {
                // Multiblock can interact poorly with SMC-heavy apps; keep it conservative by default.
                envVars.put("FEX_MULTIBLOCK", "0");
            }
        }

        // Ensure FEX logs are actually emitted for debugging. FEX's Windows bridge defaults to silent logging.
        // Route logs through Wine's __wine_dbg_output so they end up in our captured wine.log.
        boolean userSpecifiedSilentLog = this.envVars != null && this.envVars.has("FEX_SILENTLOG");
        if (isArm64ecWine && wow64Mode && !userSpecifiedSilentLog) {
            envVars.put("FEX_SILENTLOG", "0");
        }

        // FEX + WoW64: Some 32-bit titles (WoW/TurtleWoW is a concrete repro) hit
        // STATUS_ILLEGAL_INSTRUCTION on the first x87 instruction when reduced-precision
        // mode is enabled. If the user didn't explicitly override this variable, force
        // full x87 handling for WoW64 runs.
        boolean userSpecifiedX87ReducedPrecision =
                this.envVars != null && this.envVars.has("FEX_X87REDUCEDPRECISION");
        if (isArm64ecWine && wow64Mode && !userSpecifiedX87ReducedPrecision) {
            String x87Reduced = envVars.get("FEX_X87REDUCEDPRECISION");
            if ("1".equals(x87Reduced)) envVars.put("FEX_X87REDUCEDPRECISION", "0");
        }

        // Anti-cheat/VM detection: By default FEX sets the CPUID hypervisor bit and exposes
        // 0x4000_0000 leaves. Many titles will treat that as "running in VM" and may refuse
        // to run or disconnect (Warden-style checks). Hide it unless the user explicitly opts in.
        final boolean userSpecifiedHideHypervisorBit =
                this.envVars != null && this.envVars.has("FEX_HIDEHYPERVISORBIT");
        if (isArm64ecWine && wow64Mode && !userSpecifiedHideHypervisorBit) {
            envVars.put("FEX_HIDEHYPERVISORBIT", "1");
        }

        if (isArm64ecWine) {
            envVars.put("HOME", rootPath + ImageFs.HOME_PATH);
            envVars.put("WINEPREFIX", rootPath + ImageFs.WINEPREFIX);
            envVars.put("TMPDIR", new File(rootDir, "/usr/tmp").getAbsolutePath());
            envVars.put("ANDROID_SYSVSHM_SERVER", rootPath + UnixSocketConfig.SYSVSHM_SERVER_PATH);
            envVars.put("ANDROID_ALSA_SERVER", rootPath + UnixSocketConfig.ALSA_SERVER_PATH);
            envVars.put("LD_PRELOAD", ldPreload);
            envVars.put("LD_LIBRARY_PATH", rootPath + "/usr/lib" + ":/system/lib64");
            envVars.put("PATH", wineBinPath + ":" + rootPath + "/usr/bin");
            // Allow overriding WoW64 backend via env. Default is FEX's WoW64 bridge.
            // If the user sets HODLL (e.g. wowbox64.dll), don't clobber it.
            if (!envVars.has("HODLL") || envVars.get("HODLL") == null || envVars.get("HODLL").isEmpty()) {
                envVars.put("HODLL", "libwow64fex.dll");
            }
            envVars.remove("HODLL64");
            if (!envVars.has("WINEDEBUG") || "-all".equals(envVars.get("WINEDEBUG"))) {
                envVars.put("WINEDEBUG", "+loaddll,+err,+warn,+process");
            }

            // Ensure we always capture useful exception context in wine.log.
            // WoW's "ILLEGAL_INSTRUCTION" is often handled internally, so without +seh
            // we don't see the original exception address/module.
            if (wow64Mode) {
                String wineDebug = envVars.get("WINEDEBUG");
                wineDebug = ensureWineDebugChannels(wineDebug, "seh", "unwind");
                envVars.put("WINEDEBUG", wineDebug);
            }

            // When DXVK is enabled, add Vulkan channel so wine.log contains loader/instance errors.
            // This is low-noise compared to full traces and is extremely helpful for crash triage.
            if (envVars.has("DXVK_LOG_LEVEL") || envVars.has("DXVK_LOG_PATH")) {
                String wineDebug = envVars.get("WINEDEBUG");
                // Never default to "+vulkan" (trace), it will spam wine.log and hide the real
                // failure signal. Keep this at warn level.
                if (wineDebug != null && !wineDebug.contains("vulkan")) {
                    envVars.put("WINEDEBUG", wineDebug + ",warn+vulkan");
                }
            }
        }

        boolean bindSHM = envVars.get("WINEESYNC").equals("1");

        if (isArm64ecWine) {
            String command = wineBinPath + "/" + guestExecutable;
            Log.i(TAG, "Launching guest command: " + command);
            Log.i(TAG, "Guest env (arm64ec): " + envVars.toString());
            File externalLogDir = new File("/storage/emulated/0/Download/Winlator");
            if (!externalLogDir.isDirectory()) externalLogDir.mkdirs();
            File wineLogFile = new File(externalLogDir, "wine.log");
            final BufferedWriter[] wineLogWriter = new BufferedWriter[1];
            final Callback<String>[] wineLogCallback = new Callback[1];
            try {
                // Always keep a persistent log on disk for FEX/arm64ec debugging.
                // Rotate on every container launch so reproductions are easy to diff.
                // Keep writing to wine.log (latest) so users always know where to look.
                if (wineLogFile.isFile() && wineLogFile.length() > 0) {
                    String ts = new java.text.SimpleDateFormat("yyyyMMdd-HHmmss", java.util.Locale.US)
                            .format(new java.util.Date());
                    File rotated = new File(externalLogDir, "wine-" + ts + ".log");
                    // Best-effort rotation. If rename fails, we'll just overwrite wine.log.
                    //noinspection ResultOfMethodCallIgnored
                    wineLogFile.renameTo(rotated);
                }
                wineLogWriter[0] = new BufferedWriter(new FileWriter(wineLogFile, false));
                synchronized (wineLogWriter) {
                    wineLogWriter[0].write("----- Winlator arm64ec wine session: " + new java.util.Date().toString() + " -----");
                    wineLogWriter[0].newLine();
                    wineLogWriter[0].write("ENV: " + envVars.toString());
                    wineLogWriter[0].newLine();
                    wineLogWriter[0].flush();
                }
                wineLogCallback[0] = line -> {
                    if (wineLogWriter[0] == null) return;
                    synchronized (wineLogWriter) {
                        try {
                            wineLogWriter[0].write(line);
                            wineLogWriter[0].newLine();
                            wineLogWriter[0].flush();
                        }
                        catch (IOException ignored) {}
                    }
                };
                ProcessHelper.addDebugCallback(wineLogCallback[0]);
            }
            catch (IOException ignored) {
                wineLogWriter[0] = null;
            }
            return ProcessHelper.exec(command, envVars.toStringArray(), rootDir, (status) -> {
                synchronized (lock) {
                    pid = -1;
                }
                if (wineLogCallback[0] != null) {
                    ProcessHelper.removeDebugCallback(wineLogCallback[0]);
                }
                if (wineLogWriter[0] != null) {
                    synchronized (wineLogWriter) {
                        try {
                            wineLogWriter[0].close();
                        }
                        catch (IOException ignored) {}
                    }
                }
                Log.i(TAG, "Guest process terminated with status: " + status);
                if (terminationCallback != null) terminationCallback.call(status);
            });
        }

        String command = nativeLibraryDir+"/libproot.so";
        command += " --kill-on-exit";
        command += " --rootfs="+rootDir;
        command += " --cwd="+ImageFs.HOME_PATH;
        command += " --bind=/dev";

        if (bindSHM) {
            File shmDir = new File(rootDir, "/tmp/shm");
            shmDir.mkdirs();
            command += " --bind="+shmDir.getAbsolutePath()+":/dev/shm";
        }

        command += " --bind=/proc";
        command += " --bind=/sys";

        // Box64 is a bionic binary and needs the Android linker/runtime.
        File systemDir = new File(rootDir, "/system");
        if (!systemDir.isDirectory()) systemDir.mkdirs();
        File apexDir = new File(rootDir, "/apex");
        if (!apexDir.isDirectory()) apexDir.mkdirs();
        if (new File("/system").isDirectory()) command += " --bind=/system";
        if (new File("/apex").isDirectory()) command += " --bind=/apex";

        // Expose host log directory to the guest for Vulkan/DXVK/Box64 logs.
        File externalLogDir = new File("/storage/emulated/0/Download/Winlator");
        if (!externalLogDir.isDirectory()) externalLogDir.mkdirs();
        command += " --bind=" + externalLogDir.getAbsolutePath();

        // Provide legacy rootfs path expected by some Wine builds.
        File legacyRootfsParent = new File(rootDir, "/data/data/com.winlator/files");
        if (!legacyRootfsParent.isDirectory()) legacyRootfsParent.mkdirs();
        File hostRootfs = new File(environment.getContext().getFilesDir(), "rootfs");
        if (hostRootfs.exists()) {
            command += " --bind=" + hostRootfs.getPath() + ":/data/data/com.winlator/files/rootfs";
        }

        if (bindingPaths != null) {
            for (String path : bindingPaths) command += " --bind="+(new File(path)).getAbsolutePath();
        }

        command += " /usr/bin/env "+envVars.toEscapedString()+" "+guestExecutable;
        Log.i(TAG, "Launching guest command: " + command);

        envVars.clear();
        envVars.put("PROOT_TMP_DIR", tmpDir);
        envVars.put("PROOT_LOADER", nativeLibraryDir+"/libproot-loader.so");
        if (!wow64Mode) envVars.put("PROOT_LOADER_32", nativeLibraryDir+"/libproot-loader32.so");

        return ProcessHelper.exec(command, envVars.toStringArray(), rootDir, (status) -> {
            synchronized (lock) {
                pid = -1;
            }
            Log.i(TAG, "Guest process terminated with status: " + status);
            if (terminationCallback != null) terminationCallback.call(status);
        });
    }

    private void extractFexcoreFiles() {
        ImageFs imageFs = environment.getImageFs();
        Context context = environment.getContext();
        SharedPreferences preferences = PreferenceManager.getDefaultSharedPreferences(context);
        String currentFexcoreVersion = preferences.getString("current_fexcore_version", "");
        String requestedVersion = fexcoreVersion != null ? fexcoreVersion : DefaultVersion.FEXCORE;
        File system32Dir = new File(imageFs.getRootDir(), ImageFs.WINEPREFIX + "/drive_c/windows/system32");
        if (!system32Dir.isDirectory() && !system32Dir.mkdirs()) return;

        File wow64Dll = new File(system32Dir, "libwow64fex.dll");
        File arm64ecDll = new File(system32Dir, "libarm64ecfex.dll");
        File wowbox64Dll = new File(system32Dir, "wowbox64.dll");
        // Development-oriented behavior: always overwrite the FEX bridge DLLs on container start.
        // We intentionally don't rely on versioning here, because during active FEX iteration
        // we may rebuild the same "version" and still need the new DLLs to be picked up.
        if (wow64Dll.isFile()) wow64Dll.delete();
        if (arm64ecDll.isFile()) arm64ecDll.delete();
        TarCompressorUtils.extract(
                TarCompressorUtils.Type.ZSTD,
                context,
                "fexcore/fexcore-" + requestedVersion + ".tzst",
                system32Dir
        );
        preferences.edit().putString("current_fexcore_version", requestedVersion).apply();

        // Optional WoW64 CPU backend used by Winlator-Ludashi for x86-heavy titles (e.g. WoW).
        // We ship it to keep parity, but only use it if the user sets HODLL=wowbox64.dll.
        if (!wowbox64Dll.isFile()) {
            TarCompressorUtils.extract(
                    TarCompressorUtils.Type.ZSTD,
                    context,
                    "wowbox64/wowbox64-0.3.7.tzst",
                    system32Dir
            );
        }
    }


    public void suspendProcess() {
        synchronized (lock) {
            if (pid != -1) ProcessHelper.suspendProcess(pid);
        }
    }

    public void resumeProcess() {
        synchronized (lock) {
            if (pid != -1) ProcessHelper.resumeProcess(pid);
        }
    }
}
