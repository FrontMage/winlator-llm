package com.winlator.core;

import java.io.BufferedWriter;
import java.io.File;
import java.io.FileWriter;
import java.io.IOException;

public class SessionLogWriter implements Callback<String> {
    private final File logFile;
    private final Object lock = new Object();
    private BufferedWriter writer;
    private int pendingLines = 0;
    private long lastFlushMs = 0;

    public SessionLogWriter(File logFile) {
        this.logFile = logFile;
    }

    @Override
    public void call(String line) {
        appendLine(line);
    }

    public void appendLine(String line) {
        synchronized (lock) {
            ensureWriter();
            if (writer == null) return;
            try {
                writer.write(line);
                writer.newLine();
                pendingLines++;
                long now = System.currentTimeMillis();
                // External storage flush per line can stall the guest under heavy debug output.
                // Flush periodically, but keep it responsive for important lines.
                boolean important =
                        line.startsWith("err:") ||
                        line.contains("Unhandled exception") ||
                        line.contains("FATAL") ||
                        line.contains("EXCEPTION");
                if (important || pendingLines >= 64 || (now - lastFlushMs) >= 250) {
                    writer.flush();
                    pendingLines = 0;
                    lastFlushMs = now;
                }
            }
            catch (IOException e) {
                // Ignore write failures to avoid crashing the app.
            }
        }
    }

    public void close() {
        synchronized (lock) {
            if (writer != null) {
                try {
                    writer.flush();
                    writer.close();
                }
                catch (IOException e) {
                    // Ignore close failures.
                }
                writer = null;
            }
        }
    }

    private void ensureWriter() {
        if (writer != null) return;
        File parent = logFile.getParentFile();
        if (parent != null && !parent.exists()) parent.mkdirs();
        try {
            writer = new BufferedWriter(new FileWriter(logFile, true));
            pendingLines = 0;
            lastFlushMs = System.currentTimeMillis();
        }
        catch (IOException e) {
            writer = null;
        }
    }
}
