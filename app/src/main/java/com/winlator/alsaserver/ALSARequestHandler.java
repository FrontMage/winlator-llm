package com.winlator.alsaserver;

import com.winlator.sysvshm.SysVSharedMemory;
import com.winlator.xconnector.Client;
import com.winlator.xconnector.RequestHandler;
import com.winlator.xconnector.XConnectorEpoll;
import com.winlator.xconnector.XInputStream;
import com.winlator.xconnector.XOutputStream;
import com.winlator.xconnector.XStreamLock;
import android.util.Log;

import java.io.IOException;
import java.nio.ByteBuffer;

public class ALSARequestHandler implements RequestHandler {
    private static final String TAG = "WinlatorALSA";
    private int maxSHMemoryId = 0;

    @Override
    public boolean handleRequest(Client client) throws IOException {
        ALSAClient alsaClient = (ALSAClient)client.getTag();
        XInputStream inputStream = client.getInputStream();
        XOutputStream outputStream = client.getOutputStream();

        if (inputStream.available() < 5) return false;
        byte requestCode = inputStream.readByte();
        int requestLength = inputStream.readInt();

        try {
            switch (requestCode) {
            case RequestCodes.CLOSE:
                alsaClient.release();
                break;
            case RequestCodes.START:
                alsaClient.start();
                break;
            case RequestCodes.STOP:
                alsaClient.stop();
                break;
            case RequestCodes.PAUSE:
                alsaClient.pause();
                break;
            case RequestCodes.PREPARE:
                if (inputStream.available() < requestLength) return false;

                alsaClient.setChannels(inputStream.readByte());
                alsaClient.setDataType(ALSAClient.DataType.values()[inputStream.readByte()]);
                alsaClient.setSampleRate(inputStream.readInt());
                alsaClient.setBufferSize(inputStream.readInt());
                alsaClient.prepare();

                if (ALSAClient.isUseShm()) {
                    createSharedMemory(alsaClient, outputStream);
                }
                break;
            case RequestCodes.WRITE:
                ByteBuffer buffer = ALSAClient.isUseShm() ? alsaClient.getSharedBuffer() : null;
                if (buffer != null) {
                    if (copySharedBuffer(alsaClient, requestLength, outputStream)) {
                        ByteBuffer auxBuffer = alsaClient.getAuxBuffer();
                        if (auxBuffer != null) alsaClient.writeDataToStream(auxBuffer);
                        buffer.putInt(0, alsaClient.pointer());
                    }
                }
                else {
                    if (inputStream.available() < requestLength) return false;
                    alsaClient.writeDataToStream(inputStream.readByteBuffer(requestLength));
                }
                break;
            case RequestCodes.DRAIN:
                alsaClient.drain();
                break;
            case RequestCodes.POINTER:
                try (XStreamLock lock = outputStream.lock()) {
                    outputStream.writeInt(alsaClient.pointer());
                }
                break;
            case RequestCodes.GET_BUFFER_SIZE:
                byte channels = inputStream.readByte();
                ALSAClient.DataType dataType = ALSAClient.DataType.values()[inputStream.readByte()];
                int sampleRate = inputStream.readInt();
                int minBufferSize = ALSAClient.latencyMillisToBufferSize(
                    alsaClient.options.latencyMillis,
                    channels,
                    dataType,
                    sampleRate
                );
                try (XStreamLock lock = outputStream.lock()) {
                    outputStream.writeInt(minBufferSize);
                }
                break;
            }
        }
        catch (Throwable t) {
            Log.e(TAG, "ALSA request failed code=" + requestCode + " len=" + requestLength, t);
        }
        return true;
    }

    private boolean copySharedBuffer(ALSAClient alsaClient, int requestLength, XOutputStream outputStream) throws IOException {
        ByteBuffer sharedBuffer = alsaClient.getSharedBuffer();
        ByteBuffer auxBuffer = alsaClient.getAuxBuffer();
        if (sharedBuffer == null || auxBuffer == null) {
            if (ALSAClient.isDebugEnabled()) {
                Log.w(TAG, "ALSA write skipped: sharedBuffer or auxBuffer is null");
            }
            return false;
        }
        int maxShared = Math.max(0, sharedBuffer.capacity() - 4);
        int maxAux = auxBuffer.capacity();
        if (requestLength <= 0 || requestLength > maxShared || requestLength > maxAux) {
            if (ALSAClient.isDebugEnabled()) {
                Log.w(TAG, "ALSA write skipped: requestLength=" + requestLength
                    + " maxShared=" + maxShared + " maxAux=" + maxAux);
            }
            return false;
        }
        auxBuffer.position(0).limit(requestLength);
        sharedBuffer.position(4).limit(requestLength + 4);
        auxBuffer.put(sharedBuffer);

        try (XStreamLock lock = outputStream.lock()) {
            outputStream.writeByte((byte)1);
        }
        return true;
    }

    private void createSharedMemory(ALSAClient alsaClient, XOutputStream outputStream) throws IOException {
        int size = alsaClient.getBufferSizeInBytes() + 4;
        int fd = SysVSharedMemory.createMemoryFd("alsa-shm"+(++maxSHMemoryId), size);

        if (fd >= 0) {
            ByteBuffer buffer = SysVSharedMemory.mapSHMSegment(fd, size, 0, false);
            if (buffer != null) alsaClient.setSharedBuffer(buffer);
        }

        try (XStreamLock lock = outputStream.lock()) {
            outputStream.writeByte((byte)0);
            outputStream.setAncillaryFd(fd);
        }
        finally {
            if (fd >= 0) XConnectorEpoll.closeFd(fd);
        }
    }
}
