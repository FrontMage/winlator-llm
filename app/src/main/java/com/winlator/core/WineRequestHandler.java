package com.winlator.core;

import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.util.Log;

import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.IOException;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public class WineRequestHandler {
    private static final String TAG = "WineRequestHandler";
    private static final int SERVER_PORT = 20000;

    private static final class RequestCodes {
        private static final int GET_WINE_CLIPBOARD = 2;
        private static final int SET_WINE_CLIPBAORD = 3;
    }

    private final Context context;
    private ServerSocket serverSocket;
    private ExecutorService executor;
    private volatile boolean running;

    public WineRequestHandler(Context context) {
        this.context = context.getApplicationContext();
    }

    public synchronized void start() {
        if (running) return;
        running = true;
        executor = Executors.newSingleThreadExecutor();
        executor.execute(() -> {
            try {
                serverSocket = new ServerSocket(SERVER_PORT);
                Log.i(TAG, "Listening on port " + SERVER_PORT);
                while (running) {
                    Socket socket = serverSocket.accept();
                    handleConnection(socket);
                }
            } catch (IOException e) {
                if (running) Log.e(TAG, "Server loop failed", e);
            } finally {
                closeServerSocket();
            }
        });
    }

    public synchronized void stop() {
        running = false;
        closeServerSocket();
        if (executor != null) {
            executor.shutdownNow();
            executor = null;
        }
    }

    private void closeServerSocket() {
        if (serverSocket != null) {
            try {
                serverSocket.close();
            } catch (IOException ignored) {}
            serverSocket = null;
        }
    }

    private void handleConnection(Socket socket) {
        try (Socket s = socket;
             DataInputStream inputStream = new DataInputStream(s.getInputStream());
             DataOutputStream outputStream = new DataOutputStream(s.getOutputStream())) {
            int requestCode = inputStream.readInt();
            switch (requestCode) {
                case RequestCodes.GET_WINE_CLIPBOARD:
                    getWineClipboard(inputStream);
                    break;
                case RequestCodes.SET_WINE_CLIPBAORD:
                    setWineClipboard(outputStream);
                    break;
                default:
                    Log.w(TAG, "Unknown request code: " + requestCode);
                    break;
            }
        } catch (IOException e) {
            if (running) Log.e(TAG, "Connection handler failed", e);
        }
    }

    // Wine -> Android clipboard
    private void getWineClipboard(DataInputStream inputStream) throws IOException {
        int format = inputStream.readInt();
        int size = inputStream.readInt();
        byte[] data = new byte[size];
        inputStream.readFully(data);

        if (format == 13) {
            String clipboardData = new String(data, StandardCharsets.UTF_16LE).replace("\0", "");
            ClipboardManager clipboardManager = (ClipboardManager)context.getSystemService(Context.CLIPBOARD_SERVICE);
            if (clipboardManager != null) {
                clipboardManager.setPrimaryClip(ClipData.newPlainText("", clipboardData));
                Log.i(TAG, "GET_WINE_CLIPBOARD updated Android clipboard len=" + clipboardData.length());
            }
        }
    }

    // Android -> Wine clipboard
    private void setWineClipboard(DataOutputStream outputStream) throws IOException {
        int format = 13;
        String clipText = "";
        ClipboardManager clipboardManager = (ClipboardManager)context.getSystemService(Context.CLIPBOARD_SERVICE);
        if (clipboardManager != null) {
            ClipData clipData = clipboardManager.getPrimaryClip();
            if (clipData != null && clipData.getItemCount() > 0) {
                CharSequence text = clipData.getItemAt(0).getText();
                if (text != null) clipText = text.toString();
            }
        }

        clipText = clipText + "\0";
        byte[] dataByte = clipText.getBytes(StandardCharsets.UTF_16LE);
        outputStream.writeInt(format);
        outputStream.writeInt(dataByte.length);
        outputStream.write(dataByte);
        Log.i(TAG, "SET_WINE_CLIPBOARD served len=" + clipText.length());
    }
}
