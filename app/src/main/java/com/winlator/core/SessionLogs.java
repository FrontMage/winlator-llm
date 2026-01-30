package com.winlator.core;

import com.winlator.xenvironment.ImageFs;

import java.io.File;

public final class SessionLogs {
    public static final String CONTAINER_LOG_DIR = "/storage/emulated/0/Download/Winlator";
    private static final String HOST_LOG_DIR = "/storage/emulated/0/Download/Winlator";

    private SessionLogs() {}

    public static File getLogDir(ImageFs imageFs) {
        return new File(HOST_LOG_DIR);
    }

    public static File prepareLogDir(ImageFs imageFs) {
        File logDir = getLogDir(imageFs);
        logDir.mkdirs();
        return logDir;
    }

    public static File getGuestLogFile(ImageFs imageFs) {
        return new File(getLogDir(imageFs), "guest.log");
    }
}
