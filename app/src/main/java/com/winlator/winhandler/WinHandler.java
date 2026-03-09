package com.winlator.winhandler;

import android.util.Log;
import android.view.KeyEvent;
import android.view.MotionEvent;

import com.winlator.XServerDisplayActivity;
import com.winlator.core.StringUtils;
import com.winlator.inputcontrols.ControlsProfile;
import com.winlator.inputcontrols.ExternalController;
import com.winlator.xserver.XServer;

import java.io.IOException;
import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.UnknownHostException;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.util.ArrayDeque;
import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicInteger;

public class WinHandler {
    private static final String TAG = "WinHandler";
    private static final short SERVER_PORT = 7947;
    private static final short CLIENT_PORT = 7946;
    private static final short LITE_PORT = 7952;
    private static final byte LITE_READY = 0x70;
    private static final byte LITE_LOG = 0x71;
    private static final byte LITE_LOG_TEXT = 0x72;
    private static final byte LITE_FOCUS = 0x73;
    private static final byte LITE_REQUEST_TEXT = 0x01;
    private static final int LITE_MAX_UTF16_BYTES = 4096;
    private static final int RX_PACKET_MAX = 2048;
    public static final byte DINPUT_MAPPER_TYPE_STANDARD = 0;
    public static final byte DINPUT_MAPPER_TYPE_XINPUT = 1;
    private DatagramSocket socket;
    private final ByteBuffer sendData = ByteBuffer.allocate(64).order(ByteOrder.LITTLE_ENDIAN);
    private final ByteBuffer receiveData = ByteBuffer.allocate(RX_PACKET_MAX).order(ByteOrder.LITTLE_ENDIAN);
    private final DatagramPacket sendPacket = new DatagramPacket(sendData.array(), 64);
    private final DatagramPacket receivePacket = new DatagramPacket(receiveData.array(), RX_PACKET_MAX);
    private final ArrayDeque<Runnable> actions = new ArrayDeque<>();
    private boolean initReceived = false;
    private boolean liteReady = false;
    private boolean running = false;
    private final AtomicInteger liteReqSeq = new AtomicInteger(1);
    private OnGetProcessInfoListener onGetProcessInfoListener;
    private OnImeFocusListener onImeFocusListener;
    private ExternalController currentController;
    private InetAddress localhost;
    private byte dinputMapperType = DINPUT_MAPPER_TYPE_XINPUT;
    private final XServerDisplayActivity activity;
    private final List<Integer> gamepadClients = new CopyOnWriteArrayList<>();

    public WinHandler(XServerDisplayActivity activity) {
        this.activity = activity;
    }

    private boolean sendPacket(int port) {
        try {
            int size = sendData.position();
            if (size == 0) return false;
            sendPacket.setAddress(localhost);
            sendPacket.setPort(port);
            socket.send(sendPacket);
            return true;
        }
        catch (IOException e) {
            return false;
        }
    }

    public void exec(String command) {
        command = command.trim();
        if (command.isEmpty()) return;
        String[] cmdList = command.split(" ", 2);
        final String filename = cmdList[0];
        final String parameters = cmdList.length > 1 ? cmdList[1] : "";

        Log.i(TAG, "exec enqueue filename=" + filename + " params=" + parameters + " initReceived=" + initReceived);

        addAction(() -> {
            byte[] filenameBytes = filename.getBytes();
            byte[] parametersBytes = parameters.getBytes();

            sendData.rewind();
            sendData.put(RequestCodes.EXEC);
            sendData.putInt(filenameBytes.length + parametersBytes.length + 8);
            sendData.putInt(filenameBytes.length);
            sendData.putInt(parametersBytes.length);
            sendData.put(filenameBytes);
            sendData.put(parametersBytes);
            boolean ok = sendPacket(CLIENT_PORT);
            Log.i(TAG, "exec send filename=" + filename + " ok=" + ok + " clientPort=" + CLIENT_PORT);
        });
    }

    public void killProcess(final String processName) {
        addAction(() -> {
            sendData.rewind();
            sendData.put(RequestCodes.KILL_PROCESS);
            byte[] bytes = processName.getBytes();
            sendData.putInt(bytes.length);
            sendData.put(bytes);
            sendPacket(CLIENT_PORT);
        });
    }

    public void listProcesses() {
        addAction(() -> {
            sendData.rewind();
            sendData.put(RequestCodes.LIST_PROCESSES);
            sendData.putInt(0);

            if (!sendPacket(CLIENT_PORT) && onGetProcessInfoListener != null) {
                onGetProcessInfoListener.onGetProcessInfo(0, 0, null);
            }
        });
    }

    public void setProcessAffinity(final String processName, final int affinityMask) {
        addAction(() -> {
            byte[] bytes = processName.getBytes();
            sendData.rewind();
            sendData.put(RequestCodes.SET_PROCESS_AFFINITY);
            sendData.putInt(9 + bytes.length);
            sendData.putInt(0);
            sendData.putInt(affinityMask);
            sendData.put((byte)bytes.length);
            sendData.put(bytes);
            sendPacket(CLIENT_PORT);
        });
    }

    public void setProcessAffinity(final int pid, final int affinityMask) {
        addAction(() -> {
            sendData.rewind();
            sendData.put(RequestCodes.SET_PROCESS_AFFINITY);
            sendData.putInt(9);
            sendData.putInt(pid);
            sendData.putInt(affinityMask);
            sendData.put((byte)0);
            sendPacket(CLIENT_PORT);
        });
    }

    public void mouseEvent(int flags, int dx, int dy, int wheelDelta) {
        if (!initReceived) return;
        addAction(() -> {
            sendData.rewind();
            sendData.put(RequestCodes.MOUSE_EVENT);
            sendData.putInt(10);
            sendData.putInt(flags);
            sendData.putShort((short)dx);
            sendData.putShort((short)dy);
            sendData.putShort((short)wheelDelta);
            sendData.put((byte)((flags & MouseEventFlags.MOVE) != 0 ? 1 : 0)); // cursor pos feedback
            sendPacket(CLIENT_PORT);
        });
    }

    public boolean keyboardEvent(byte vkey, int flags) {
        if (!initReceived) return false;
        addAction(() -> {
            sendData.rewind();
            sendData.put(RequestCodes.KEYBOARD_EVENT);
            sendData.put(vkey);
            sendData.putInt(flags);
            sendPacket(CLIENT_PORT);
        });
        return true;
    }

    public boolean imeCommitText(String text) {
        if (!initReceived || !liteReady || text == null || text.isEmpty()) return false;

        byte[] utf16Bytes = text.getBytes(StandardCharsets.UTF_16LE);
        if (utf16Bytes.length == 0) return false;

        final int textBytes = Math.min(utf16Bytes.length, LITE_MAX_UTF16_BYTES);
        final int reqId = liteReqSeq.getAndIncrement();
        final byte[] payload = new byte[1 + 4 + 4 + textBytes];
        ByteBuffer.wrap(payload).order(ByteOrder.LITTLE_ENDIAN)
                .put(LITE_REQUEST_TEXT)
                .putInt(reqId)
                .putInt(textBytes)
                .put(utf16Bytes, 0, textBytes);

        addAction(() -> {
            if (socket == null || localhost == null) return;
            try {
                DatagramPacket packet = new DatagramPacket(payload, payload.length, localhost, LITE_PORT);
                socket.send(packet);
            }
            catch (IOException e) {
                Log.w(TAG, "Failed to send IME payload to winhandler-lite", e);
            }
        });
        Log.i(TAG, "winhandler-lite submit reqId=" + reqId + " chars=" + text.length());
        return true;
    }

    public boolean isReady() {
        return initReceived;
    }

    public void bringToFront(final String processName) {
        bringToFront(processName, 0);
    }

    public void bringToFront(final String processName, final long handle) {
        addAction(() -> {
            sendData.rewind();
            sendData.put(RequestCodes.BRING_TO_FRONT);
            byte[] bytes = processName.getBytes();
            sendData.putInt(bytes.length);
            sendData.put(bytes);
            sendData.putLong(handle);
            sendPacket(CLIENT_PORT);
        });
    }

    private void addAction(Runnable action) {
        synchronized (actions) {
            actions.add(action);
            actions.notify();
        }
    }

    public OnGetProcessInfoListener getOnGetProcessInfoListener() {
        return onGetProcessInfoListener;
    }

    public void setOnGetProcessInfoListener(OnGetProcessInfoListener onGetProcessInfoListener) {
        synchronized (actions) {
            this.onGetProcessInfoListener = onGetProcessInfoListener;
        }
    }

    public void setOnImeFocusListener(OnImeFocusListener listener) {
        synchronized (actions) {
            this.onImeFocusListener = listener;
        }
    }

    private void startSendThread() {
        Executors.newSingleThreadExecutor().execute(() -> {
            while (running) {
                synchronized (actions) {
                    while (initReceived && !actions.isEmpty()) actions.poll().run();
                    try {
                        actions.wait();
                    }
                    catch (InterruptedException e) {}
                }
            }
        });
    }

    public void stop() {
        running = false;

        if (socket != null) {
            socket.close();
            socket = null;
        }

        synchronized (actions) {
            actions.notify();
        }
    }

    private void handleRequest(byte requestCode, final int port, final int packetLen) {
        int req = requestCode & 0xff;
        Log.i(TAG, "handleRequest code=" + req + " fromPort=" + port + " len=" + packetLen + " initReceived=" + initReceived);
        switch (requestCode) {
            case RequestCodes.INIT: {
                initReceived = true;
                Log.i(TAG, "INIT received fromPort=" + port + ", actions queued=" + actions.size());

                synchronized (actions) {
                    actions.notify();
                }
                break;
            }
            case RequestCodes.GET_PROCESS: {
                if (onGetProcessInfoListener == null) return;
                receiveData.position(receiveData.position() + 4);
                int numProcesses = receiveData.getShort();
                int index = receiveData.getShort();
                int pid = receiveData.getInt();
                long memoryUsage = receiveData.getLong();
                int affinityMask = receiveData.getInt();
                boolean wow64Process = receiveData.get() == 1;

                byte[] bytes = new byte[32];
                receiveData.get(bytes);
                String name = StringUtils.fromANSIString(bytes);

                onGetProcessInfoListener.onGetProcessInfo(index, numProcesses, new ProcessInfo(pid, name, memoryUsage, affinityMask, wow64Process));
                break;
            }
            case RequestCodes.GET_GAMEPAD: {
                boolean isXInput = receiveData.get() == 1;
                boolean notify = receiveData.get() == 1;
                final ControlsProfile profile = activity.getInputControlsView().getProfile();
                boolean useVirtualGamepad = profile != null && profile.isVirtualGamepad();

                if (!useVirtualGamepad && (currentController == null || !currentController.isConnected())) {
                    currentController = ExternalController.getController(0);
                }

                final boolean enabled = currentController != null || useVirtualGamepad;

                if (enabled && notify) {
                    if (!gamepadClients.contains(port)) gamepadClients.add(port);
                }
                else gamepadClients.remove(Integer.valueOf(port));

                addAction(() -> {
                    sendData.rewind();
                    sendData.put(RequestCodes.GET_GAMEPAD);

                    if (enabled) {
                        sendData.putInt(!useVirtualGamepad ? currentController.getDeviceId() : profile.id);
                        sendData.put(dinputMapperType);
                        byte[] bytes = (useVirtualGamepad ? profile.getName() : currentController.getName()).getBytes();
                        sendData.putInt(bytes.length);
                        sendData.put(bytes);
                    }
                    else sendData.putInt(0);

                    sendPacket(port);
                });
                break;
            }
            case RequestCodes.GET_GAMEPAD_STATE: {
                int gamepadId = receiveData.getInt();
                final ControlsProfile profile = activity.getInputControlsView().getProfile();
                boolean useVirtualGamepad = profile != null && profile.isVirtualGamepad();
                final boolean enabled = currentController != null || useVirtualGamepad;

                if (currentController != null && currentController.getDeviceId() != gamepadId) currentController = null;

                addAction(() -> {
                    sendData.rewind();
                    sendData.put(RequestCodes.GET_GAMEPAD_STATE);
                    sendData.put((byte)(enabled ? 1 : 0));

                    if (enabled) {
                        sendData.putInt(gamepadId);
                        if (useVirtualGamepad) {
                            profile.getGamepadState().writeTo(sendData);
                        }
                        else currentController.state.writeTo(sendData);
                    }

                    sendPacket(port);
                });
                break;
            }
            case RequestCodes.RELEASE_GAMEPAD: {
                currentController = null;
                gamepadClients.clear();
                break;
            }
            case RequestCodes.CURSOR_POS_FEEDBACK: {
                short x = receiveData.getShort();
                short y = receiveData.getShort();
                XServer xServer = activity.getXServer();
                xServer.pointer.setX(x);
                xServer.pointer.setY(y);
                activity.getXServerView().requestRender();
                break;
            }
            case LITE_READY: {
                liteReady = true;
                Log.i(TAG, "winhandler-lite ready");
                break;
            }
            case LITE_LOG: {
                if (packetLen < 14) {
                    Log.w(TAG, "winhandler-lite log packet too short len=" + packetLen);
                    break;
                }
                int reqId = receiveData.getInt();
                int stage = receiveData.get() & 0xff;
                int winerr = receiveData.getInt();
                int aux = receiveData.getInt();
                Log.i(TAG, "winhandler-lite reqId=" + reqId + " stage=" + stageToString(stage)
                        + " winerr=" + winerr + " aux=" + aux);
                break;
            }
            case LITE_LOG_TEXT: {
                if (packetLen < 8) {
                    Log.w(TAG, "winhandler-lite text packet too short len=" + packetLen);
                    break;
                }
                int reqId = receiveData.getInt();
                int stage = receiveData.get() & 0xff;
                int textLen = receiveData.getShort() & 0xffff;
                int remain = Math.max(0, packetLen - 8);
                int n = Math.min(textLen, remain);
                byte[] bytes = new byte[n];
                receiveData.get(bytes);
                String text = new String(bytes, StandardCharsets.UTF_8);
                Log.i(TAG, "winhandler-lite reqId=" + reqId + " stage=" + stageToString(stage)
                        + " text=" + text);
                break;
            }
            case LITE_FOCUS: {
                if (packetLen < 4) {
                    Log.w(TAG, "winhandler-lite focus packet too short len=" + packetLen);
                    break;
                }
                boolean focused = receiveData.get() != 0;
                int textLen = receiveData.getShort() & 0xffff;
                int remain = Math.max(0, packetLen - 4);
                int n = Math.min(textLen, remain);
                byte[] bytes = new byte[n];
                receiveData.get(bytes);
                String boxName = new String(bytes, StandardCharsets.UTF_8);
                Log.i(TAG, "winhandler-lite focus focused=" + focused + " box=" + boxName);
                if (onImeFocusListener != null) {
                    onImeFocusListener.onImeFocusChanged(focused, boxName);
                }
                break;
            }
            default: {
                Log.i(TAG, "Unhandled request code=" + req + " fromPort=" + port);
                break;
            }
        }
    }

    private String stageToString(int stage) {
        switch (stage) {
            case 1: return "recv_text";
            case 2: return "unicode_inject_begin";
            case 3: return "unicode_inject_end";
            case 4: return "done";
            case 5: return "invalid_packet";
            case 20: return "target_resolve";
            case 21: return "msg_inject_begin";
            case 22: return "msg_inject_end";
            case 23: return "msg_inject_failed";
            case 24: return "msg_inject_mode";
            case 30: return "bridge_ping_begin";
            case 31: return "bridge_ping_ok";
            case 32: return "bridge_ping_fail";
            case 33: return "bridge_submit_begin";
            case 34: return "bridge_submit_ok";
            case 35: return "bridge_submit_fail";
            case 36: return "bridge_debug_flags";
            case 37: return "bridge_debug_err_set";
            case 38: return "bridge_debug_err_notify";
            case 39: return "bridge_debug_comp_len";
            case 40: return "bridge_ctx_hwnd_fg_focus";
            case 41: return "bridge_ctx_hwnd_target_oldfocus";
            case 42: return "bridge_ctx_tid_self_fg";
            case 43: return "bridge_ctx_tid_pid_target";
            case 44: return "bridge_ctx_attach_focus_ok";
            case 45: return "bridge_ctx_attach_focus_err";
            case 46: return "ctx_fg_hwnd";
            case 47: return "ctx_focus_hwnd";
            case 50: return "clip_open_begin";
            case 51: return "clip_open_ok";
            case 52: return "clip_open_fail";
            case 53: return "clip_set_ok";
            case 54: return "clip_set_fail";
            case 55: return "paste_sendinput_begin";
            case 56: return "paste_sendinput_ok";
            case 57: return "paste_sendinput_fail";
            case 58: return "clip_restore_ok";
            case 59: return "clip_restore_fail";
            case 60: return "target_parent";
            case 61: return "wm_paste_begin";
            case 62: return "wm_paste_ok";
            case 63: return "wm_paste_fail";
            case 64: return "clip_restore_delay";
            default: return "unknown_" + stage;
        }
    }

    public void start() {
        initReceived = false;
        liteReady = false;
        try {
            localhost = InetAddress.getLocalHost();
        }
        catch (UnknownHostException e) {
            try {
                localhost = InetAddress.getByName("127.0.0.1");
            }
            catch (UnknownHostException ex) {}
        }

        running = true;
        startSendThread();
        Executors.newSingleThreadExecutor().execute(() -> {
            try {
                socket = new DatagramSocket(null);
                socket.setReuseAddress(true);
                socket.bind(new InetSocketAddress((InetAddress)null, SERVER_PORT));

                while (running) {
                    receivePacket.setLength(receiveData.array().length);
                    socket.receive(receivePacket);
                    int packetLen = receivePacket.getLength();

                    synchronized (actions) {
                        receiveData.rewind();
                        receiveData.limit(packetLen);
                        byte requestCode = receiveData.get();
                        handleRequest(requestCode, receivePacket.getPort(), packetLen);
                    }
                }
            }
            catch (IOException e) {}
        });
    }

    public void sendGamepadState() {
        if (!initReceived || gamepadClients.isEmpty()) return;
        final ControlsProfile profile = activity.getInputControlsView().getProfile();
        final boolean useVirtualGamepad = profile != null && profile.isVirtualGamepad();
        final boolean enabled = currentController != null || useVirtualGamepad;

        for (final int port : gamepadClients) {
            addAction(() -> {
                sendData.rewind();
                sendData.put(RequestCodes.GET_GAMEPAD_STATE);
                sendData.put((byte)(enabled ? 1 : 0));

                if (enabled) {
                    sendData.putInt(!useVirtualGamepad ? currentController.getDeviceId() : profile.id);
                    if (useVirtualGamepad) {
                        profile.getGamepadState().writeTo(sendData);
                    }
                    else currentController.state.writeTo(sendData);
                }

                sendPacket(port);
            });
        }
    }

    public boolean onGenericMotionEvent(MotionEvent event) {
        boolean handled = false;
        if (currentController != null && currentController.getDeviceId() == event.getDeviceId()) {
            handled = currentController.updateStateFromMotionEvent(event);
            if (handled) sendGamepadState();
        }
        return handled;
    }

    public boolean onKeyEvent(KeyEvent event) {
        boolean handled = false;
        if (currentController != null && currentController.getDeviceId() == event.getDeviceId() && event.getRepeatCount() == 0) {
            int action = event.getAction();

            if (action == KeyEvent.ACTION_DOWN) {
                handled = currentController.updateStateFromKeyEvent(event);
            }
            else if (action == KeyEvent.ACTION_UP) {
                handled = currentController.updateStateFromKeyEvent(event);
            }

            if (handled) sendGamepadState();
        }
        return handled;
    }

    public byte getDInputMapperType() {
        return dinputMapperType;
    }

    public void setDInputMapperType(byte dinputMapperType) {
        this.dinputMapperType = dinputMapperType;
    }

    public ExternalController getCurrentController() {
        return currentController;
    }
}
