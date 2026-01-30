package com.winlator.alsaserver;

import android.content.Context;
import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioTrack;
import android.util.Log;

import com.winlator.core.KeyValueSet;
import com.winlator.math.Mathf;
import com.winlator.sysvshm.SysVSharedMemory;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;

public class ALSAClient {
    private static final String TAG = "WinlatorALSA";
    private static boolean debugEnabled = false;
    private static boolean useShm = true;

    public enum DataType {
        U8(1), S16LE(2), S16BE(2), FLOATLE(4), FLOATBE(4);
        public final byte byteCount;

        DataType(int byteCount) {
            this.byteCount = (byte)byteCount;
        }
    }

    public static class Options {
        public short latencyMillis = 16;
        public byte performanceMode = 1;
        public float volume = 1.0f;

        public static Options fromKeyValueSet(KeyValueSet keyValueSet) {
            Options options = new Options();
            if (keyValueSet == null || keyValueSet.isEmpty()) return options;
            options.performanceMode = (byte)keyValueSet.getInt("performanceMode", options.performanceMode);
            options.volume = keyValueSet.getFloat("volume", options.volume);
            options.latencyMillis = (short)keyValueSet.getInt("latencyMillis", options.latencyMillis);
            return options;
        }
    }

    private static short framesPerBuffer = 0;
    AudioTrack audioTrack;
    ByteBuffer auxBuffer;
    ByteBuffer sharedBuffer;
    DataType dataType = DataType.U8;
    byte channels = 2;
    int bufferCapacity;
    int bufferSize;
    int sampleRate;
    byte frameBytes;
    int position;
    short previousUnderrunCount;
    final Options options;
    private long lastWriteLogTimeMs = 0;

    public ALSAClient(Options options) {
        this.options = options != null ? options : new Options();
    }

    public static void setDebug(boolean enabled) {
        debugEnabled = enabled;
    }

    public static boolean isDebugEnabled() {
        return debugEnabled;
    }

    public static void setUseShm(boolean enabled) {
        useShm = enabled;
    }

    public static boolean isUseShm() {
        return useShm;
    }

    public static void assignFramesPerBuffer(Context context) {
        if (framesPerBuffer > 0 || context == null) return;
        try {
            AudioManager audioManager = (AudioManager)context.getSystemService(Context.AUDIO_SERVICE);
            String value = audioManager != null ? audioManager.getProperty(AudioManager.PROPERTY_OUTPUT_FRAMES_PER_BUFFER) : null;
            if (value != null && !value.isEmpty()) {
                framesPerBuffer = (short)Math.max(1, Integer.parseInt(value));
            }
        }
        catch (Exception ignored) {
            framesPerBuffer = 0;
        }

        if (framesPerBuffer <= 0) framesPerBuffer = 256;
    }

    public void release() {
        if (sharedBuffer != null) {
            SysVSharedMemory.unmapSHMSegment(sharedBuffer, sharedBuffer.capacity());
            sharedBuffer = null;
        }

        if (audioTrack != null) {
            try {
                audioTrack.pause();
                audioTrack.flush();
                audioTrack.release();
            }
            catch (Exception e) {
                logDebug("release: " + e.getMessage());
            }
            audioTrack = null;
        }
    }

    public void prepare() {
        position = 0;
        previousUnderrunCount = 0;
        frameBytes = (byte)(channels * dataType.byteCount);
        if (debugEnabled) {
            logDebug("prepare: channels=" + channels
                + " dataType=" + dataType
                + " sampleRate=" + sampleRate
                + " bufferSize=" + bufferSize
                + " frameBytes=" + frameBytes
                + " perfMode=" + options.performanceMode
                + " volume=" + options.volume);
        }
        release();

        if (!isValidBufferSize()) {
            logDebug("prepare: invalid buffer size (" + bufferSize + "), frameBytes=" + frameBytes);
            return;
        }

        AudioFormat format = new AudioFormat.Builder()
            .setEncoding(getPCMEncoding(dataType))
            .setSampleRate(sampleRate)
            .setChannelMask(getChannelConfig(channels))
            .build();

        audioTrack = new AudioTrack.Builder()
            .setPerformanceMode(options.performanceMode)
            .setAudioFormat(format)
            .setBufferSizeInBytes(getBufferSizeInBytes())
            .build();

        if (audioTrack.getState() != AudioTrack.STATE_INITIALIZED) {
            logDebug("prepare: AudioTrack state=" + audioTrack.getState()
                + " sampleRate=" + sampleRate
                + " channels=" + channels
                + " encoding=" + getPCMEncoding(dataType)
                + " bufferBytes=" + getBufferSizeInBytes());
        }
        bufferCapacity = audioTrack.getBufferCapacityInFrames();
        if (options.volume != 1.0f) {
            audioTrack.setVolume(options.volume);
        }
        audioTrack.play();
        if (debugEnabled) {
            logDebug("prepare: AudioTrack initialized. bufferCapacity=" + bufferCapacity
                + " playState=" + audioTrack.getPlayState());
        }
    }

    public void start() {
        if (audioTrack != null && audioTrack.getPlayState() != AudioTrack.PLAYSTATE_PLAYING) {
            audioTrack.play();
        }
    }

    public void stop() {
        if (audioTrack != null) {
            audioTrack.stop();
            audioTrack.flush();
        }
    }

    public void pause() {
        if (audioTrack != null) {
            audioTrack.pause();
        }
    }

    public void drain() {
        if (audioTrack != null) audioTrack.flush();
    }

    public void writeDataToStream(ByteBuffer data) {
        if (dataType == DataType.S16LE || dataType == DataType.FLOATLE) {
            data.order(ByteOrder.LITTLE_ENDIAN);
        }
        else if (dataType == DataType.S16BE || dataType == DataType.FLOATBE) {
            data.order(ByteOrder.BIG_ENDIAN);
        }

        if (audioTrack != null) {
            data.position(0);
            try {
                while (data.position() != data.limit()) {
                    int bytesWritten = audioTrack.write(data, data.remaining(), AudioTrack.WRITE_BLOCKING);
                    if (bytesWritten < 0) {
                        logDebug("write: error=" + audioTrackErrorToString(bytesWritten)
                            + " playState=" + audioTrack.getPlayState()
                            + " state=" + audioTrack.getState());
                        break;
                    }
                    increaseBufferSizeIfUnderrunOccurs();
                }
            }
            catch (Exception ignored) {
                logDebug("write: exception " + ignored.getClass().getSimpleName() + " " + ignored.getMessage());
            }
            position += data.position();
            data.rewind();
        }
        else {
            logDebug("write: AudioTrack is null");
        }
    }

    public int pointer() {
        if (audioTrack == null) return 0;
        return position / frameBytes;
    }

    public void setDataType(DataType dataType) {
        this.dataType = dataType;
    }

    public void setChannels(int channels) {
        this.channels = (byte)channels;
    }

    public void setSampleRate(int sampleRate) {
        this.sampleRate = sampleRate;
    }

    public void setBufferSize(int bufferSize) {
        this.bufferSize = bufferSize;
    }

    public ByteBuffer getAuxBuffer() {
        return auxBuffer;
    }

    public int getBufferSizeInBytes() {
        return bufferSize * frameBytes;
    }

    public ByteBuffer getSharedBuffer() {
        return sharedBuffer;
    }

    public void setSharedBuffer(ByteBuffer sharedBuffer) {
        if (sharedBuffer != null) {
            auxBuffer = ByteBuffer.allocateDirect(getBufferSizeInBytes()).order(ByteOrder.LITTLE_ENDIAN);
            this.sharedBuffer = sharedBuffer.order(ByteOrder.LITTLE_ENDIAN);
        }
        else {
            auxBuffer = null;
            this.sharedBuffer = null;
        }
    }

    private boolean isValidBufferSize() {
        return (bufferSize % frameBytes == 0) && bufferSize > 0;
    }

    private void increaseBufferSizeIfUnderrunOccurs() {
        if (audioTrack == null) return;
        int underrunCount;
        try {
            underrunCount = audioTrack.getUnderrunCount();
        }
        catch (IllegalStateException e) {
            logDebug("underrun: " + e.getMessage());
            return;
        }
        if (underrunCount <= previousUnderrunCount) return;
        previousUnderrunCount = (short)underrunCount;
        if (bufferCapacity <= 0) return;
        int newBufferSize = Math.min(bufferSize + framesPerBuffer, bufferCapacity);
        if (newBufferSize != bufferSize) {
            bufferSize = newBufferSize;
            audioTrack.setBufferSizeInFrames(bufferSize);
            logDebug("underrun: increased bufferSize=" + bufferSize);
        }
    }

    private int getChannelConfig(int channels) {
        return channels == 1 ? AudioFormat.CHANNEL_OUT_MONO : AudioFormat.CHANNEL_OUT_STEREO;
    }

    private int getPCMEncoding(DataType dataType) {
        switch (dataType) {
            case U8:
                return AudioFormat.ENCODING_PCM_8BIT;
            case FLOATLE:
            case FLOATBE:
                return AudioFormat.ENCODING_PCM_FLOAT;
            default:
                return AudioFormat.ENCODING_PCM_16BIT;
        }
    }

    public static int latencyMillisToBufferSize(int latencyMillis, int channels, DataType dataType, int sampleRate) {
        byte frameBytes = (byte)(dataType.byteCount * channels);
        float frames = (latencyMillis * sampleRate) / 1000f;
        int roundedFrames = (int)Mathf.roundTo(frames, framesPerBuffer, false);
        return roundedFrames * frameBytes;
    }

    private void logDebug(String message) {
        if (!debugEnabled) return;
        long now = System.currentTimeMillis();
        if (now - lastWriteLogTimeMs < 1000 && message.startsWith("write:")) return;
        lastWriteLogTimeMs = now;
        Log.i(TAG, message);
    }

    private String audioTrackErrorToString(int error) {
        switch (error) {
            case AudioTrack.ERROR_BAD_VALUE:
                return "ERROR_BAD_VALUE";
            case AudioTrack.ERROR_INVALID_OPERATION:
                return "ERROR_INVALID_OPERATION";
            case AudioTrack.ERROR_DEAD_OBJECT:
                return "ERROR_DEAD_OBJECT";
            case AudioTrack.ERROR:
                return "ERROR";
            default:
                return String.valueOf(error);
        }
    }
}
