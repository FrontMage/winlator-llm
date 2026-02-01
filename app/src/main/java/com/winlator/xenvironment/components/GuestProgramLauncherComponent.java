package com.winlator.xenvironment.components;

import android.content.Context;
import android.content.SharedPreferences;
import android.os.Process;
import android.util.Log;

import androidx.preference.PreferenceManager;

import com.winlator.box86_64.Box86_64Preset;
import com.winlator.box86_64.Box86_64PresetManager;
import com.winlator.core.Callback;
import com.winlator.core.DefaultVersion;
import com.winlator.core.EnvVars;
import com.winlator.core.FileUtils;
import com.winlator.core.ProcessHelper;
import com.winlator.core.TarCompressorUtils;
import com.winlator.xconnector.UnixSocketConfig;
import com.winlator.xenvironment.EnvironmentComponent;
import com.winlator.xenvironment.ImageFs;

import java.io.File;

public class GuestProgramLauncherComponent extends EnvironmentComponent {
    private static final String TAG = "GuestLauncher";
    private String guestExecutable;
    private static int pid = -1;
    private String[] bindingPaths;
    private EnvVars envVars;
    private String box86Preset = Box86_64Preset.COMPATIBILITY;
    private String box64Preset = Box86_64Preset.COMPATIBILITY;
    private Callback<Integer> terminationCallback;
    private static final Object lock = new Object();
    private boolean wow64Mode = true;

    @Override
    public void start() {
        synchronized (lock) {
            stop();
            extractBox86_64Files();
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

    public String getBox86Preset() {
        return box86Preset;
    }

    public void setBox86Preset(String box86Preset) {
        this.box86Preset = box86Preset;
    }

    public String getBox64Preset() {
        return box64Preset;
    }

    public void setBox64Preset(String box64Preset) {
        this.box64Preset = box64Preset;
    }

    private int execGuestProgram() {
        Context context = environment.getContext();
        ImageFs imageFs = environment.getImageFs();
        File rootDir = imageFs.getRootDir();
        File tmpDir = environment.getTmpDir();
        String nativeLibraryDir = context.getApplicationInfo().nativeLibraryDir;

        SharedPreferences preferences = PreferenceManager.getDefaultSharedPreferences(context);
        boolean enableBox86_64Logs = preferences.getBoolean("enable_box86_64_logs", true);

        EnvVars envVars = new EnvVars();
        if (!wow64Mode) addBox86EnvVars(envVars, enableBox86_64Logs);
        addBox64EnvVars(envVars, enableBox86_64Logs);
        envVars.put("HOME", ImageFs.HOME_PATH);
        envVars.put("USER", ImageFs.USER);
        envVars.put("TMPDIR", "/tmp");
        envVars.put("LC_ALL", "en_US.utf8");
        envVars.put("DISPLAY", ":0");
        envVars.put("PATH", imageFs.getWinePath()+"/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin");
        String defaultLdLibraryPath = "/usr/lib:/usr/lib/aarch64-linux-gnu:/usr/lib/arm-linux-gnueabihf";
        String sambaLdLibraryPath = "/usr/lib/samba:/usr/lib/samba/private";
        envVars.put("LD_LIBRARY_PATH", sambaLdLibraryPath + ":" + defaultLdLibraryPath);
        envVars.put("ANDROID_SYSVSHM_SERVER", UnixSocketConfig.SYSVSHM_SERVER_PATH);

        if ((new File(imageFs.getLib64Dir(), "libandroid-sysvshm.so")).exists() ||
            (new File(imageFs.getLib32Dir(), "libandroid-sysvshm.so")).exists()) envVars.put("LD_PRELOAD", "libandroid-sysvshm.so");
        if (this.envVars != null) envVars.putAll(this.envVars);

        String currentLdLibraryPath = envVars.get("LD_LIBRARY_PATH");
        if (!currentLdLibraryPath.contains("/usr/lib/samba")) {
            if (currentLdLibraryPath.isEmpty()) {
                envVars.put("LD_LIBRARY_PATH", sambaLdLibraryPath + ":" + defaultLdLibraryPath);
            } else {
                envVars.put("LD_LIBRARY_PATH", sambaLdLibraryPath + ":" + currentLdLibraryPath);
            }
        }

        boolean bindSHM = envVars.get("WINEESYNC").equals("1");

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

        command += " /usr/bin/env "+envVars.toEscapedString()+" box64 "+guestExecutable;
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

    private void extractBox86_64Files() {
        ImageFs imageFs = environment.getImageFs();
        Context context = environment.getContext();
        SharedPreferences preferences = PreferenceManager.getDefaultSharedPreferences(context);
        String box86Version = preferences.getString("box86_version", DefaultVersion.BOX86);
        String box64Version = preferences.getString("box64_version", DefaultVersion.BOX64);
        String currentBox86Version = preferences.getString("current_box86_version", "");
        String currentBox64Version = preferences.getString("current_box64_version", "");
        File rootDir = imageFs.getRootDir();

        File box86File = new File(rootDir, "/usr/local/bin/box86");
        File box64File = new File(rootDir, "/usr/local/bin/box64");

        if (wow64Mode) {
            if (box86File.isFile()) {
                box86File.delete();
                preferences.edit().putString("current_box86_version", "").apply();
            }
        }
        else if (!box86File.isFile() || !box86Version.equals(currentBox86Version)) {
            TarCompressorUtils.extract(TarCompressorUtils.Type.ZSTD, context, "box86_64/box86-" + box86Version + ".tzst", rootDir);
            preferences.edit().putString("current_box86_version", box86Version).apply();
        }

        if (!box64File.isFile() || !box64Version.equals(currentBox64Version)) {
            TarCompressorUtils.extract(TarCompressorUtils.Type.ZSTD, context, "box86_64/box64-" + box64Version + ".tzst", rootDir);
            preferences.edit().putString("current_box64_version", box64Version).apply();
        }

        ensureLdLinuxSymlink(rootDir);
    }

    private void ensureLdLinuxSymlink(File rootDir) {
        File usrLd = new File(rootDir, "usr/lib/ld-linux-aarch64.so.1");
        File libLd = new File(rootDir, "lib/ld-linux-aarch64.so.1");
        if (!libLd.exists() && usrLd.exists()) {
            FileUtils.symlink("/usr/lib/ld-linux-aarch64.so.1", libLd.getAbsolutePath());
        }
    }

    private void addBox86EnvVars(EnvVars envVars, boolean enableLogs) {
        envVars.put("BOX86_NOBANNER", ProcessHelper.PRINT_DEBUG && enableLogs ? "0" : "1");
        envVars.put("BOX86_DYNAREC", "1");

        if (enableLogs) {
            envVars.put("BOX86_LOG", "1");
            envVars.put("BOX86_DYNAREC_MISSING", "1");
        }

        envVars.putAll(Box86_64PresetManager.getEnvVars("box86", environment.getContext(), box86Preset));
        envVars.put("BOX86_X11GLX", "1");
        envVars.put("BOX86_NORCFILES", "1");
    }

    private void addBox64EnvVars(EnvVars envVars, boolean enableLogs) {
        envVars.put("BOX64_NOBANNER", ProcessHelper.PRINT_DEBUG && enableLogs ? "0" : "1");
        if (wow64Mode) envVars.put("BOX64_MMAP32", "1");

        if (enableLogs) {
            envVars.put("BOX64_LOG", "1");
            envVars.put("BOX64_DYNAREC_MISSING", "1");
        }

        envVars.putAll(Box86_64PresetManager.getEnvVars("box64", environment.getContext(), box64Preset));
        applyBox64Overrides(envVars);
        envVars.put("BOX64_X11GLX", "1");
        envVars.put("BOX64_NORCFILES", "1");
    }

    private void applyBox64Overrides(EnvVars envVars) {
        envVars.put("BOX64_DYNAREC", "1");
        envVars.put("BOX64_DYNAREC_SAFEFLAGS", "2");
        envVars.put("BOX64_DYNAREC_FASTNAN", "1");
        envVars.put("BOX64_DYNAREC_FASTROUND", "0");
        envVars.put("BOX64_DYNAREC_X87DOUBLE", "1");
        envVars.put("BOX64_DYNAREC_BIGBLOCK", "2");
        envVars.put("BOX64_DYNAREC_STRONGMEM", "0");
        envVars.put("BOX64_DYNAREC_FORWARD", "128");
        envVars.put("BOX64_DYNAREC_CALLRET", "0");
        envVars.put("BOX64_DYNAREC_WAIT", "1");
        envVars.put("BOX64_DYNAREC_NATIVEFLAGS", "0");
        envVars.put("BOX64_DYNAREC_WEAKBARRIER", "2");
        envVars.put("BOX64_DLSYM_ERROR", "1");
        envVars.put("BOX64_SHOWSEGV", "1");
        envVars.put("BOX64_UNITYPLAYER", "0");

        File hostRootfs = new File(environment.getContext().getFilesDir(), "rootfs");
        envVars.put("BOX64_RCFILE", new File(hostRootfs, "etc/config.box64rc").getPath());
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
