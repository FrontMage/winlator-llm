package com.winlator.alsaserver;

import com.winlator.xconnector.Client;
import com.winlator.xconnector.ConnectionHandler;
import android.util.Log;

public class ALSAClientConnectionHandler implements ConnectionHandler {
    private static final String TAG = "WinlatorALSA";
    private final ALSAClient.Options options;

    public ALSAClientConnectionHandler(ALSAClient.Options options) {
        this.options = options;
    }

    @Override
    public void handleNewConnection(Client client) {
        client.createIOStreams();
        client.setTag(new ALSAClient(options));
        if (ALSAClient.isDebugEnabled()) {
            Log.i(TAG, "ALSA client connected");
        }
    }

    @Override
    public void handleConnectionShutdown(Client client) {
        ((ALSAClient)client.getTag()).release();
        if (ALSAClient.isDebugEnabled()) {
            Log.i(TAG, "ALSA client disconnected");
        }
    }
}
