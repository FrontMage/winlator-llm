package com.winlator.core;

import java.io.BufferedWriter;
import java.io.File;
import java.io.FileWriter;
import java.io.IOException;

public class SessionLogWriter implements Callback<String> {
    private final File logFile;
    private final Object lock = new Object();
    private BufferedWriter writer;

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
                writer.flush();
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
        }
        catch (IOException e) {
            writer = null;
        }
    }
}
