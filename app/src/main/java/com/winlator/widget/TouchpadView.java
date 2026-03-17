package com.winlator.widget;

import android.content.Context;
import android.graphics.Color;
import android.graphics.drawable.ColorDrawable;
import android.graphics.drawable.StateListDrawable;
import android.view.InputDevice;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewGroup;
import android.util.Log;
import android.widget.FrameLayout;

import com.winlator.core.AppUtils;
import com.winlator.math.Mathf;
import com.winlator.math.XForm;
import com.winlator.renderer.ViewTransformation;
import com.winlator.winhandler.MouseEventFlags;
import com.winlator.winhandler.WinHandler;
import com.winlator.xserver.Pointer;
import com.winlator.xserver.XServer;

public class TouchpadView extends View {
    private static final String TAG_ICP = "ICP_GESTURE";
    private static final boolean ICP_DEBUG_LOG = true;
    private static final byte MAX_FINGERS = 4;
    private static final short MAX_TWO_FINGERS_SCROLL_DISTANCE = 350;
    public static final byte MAX_TAP_TRAVEL_DISTANCE = 10;
    public static final short MAX_TAP_MILLISECONDS = 200;
    public static final float CURSOR_ACCELERATION = 1.25f;
    public static final byte CURSOR_ACCELERATION_THRESHOLD = 6;
    private static final float RIGHT_DRAG_SENSITIVITY = 0.65f;
    private static final float LEFT_DRAG_SENSITIVITY = 0.65f;
    private static final float PINCH_SCROLL_DEADZONE = 24.0f;
    private static final int PINCH_SCROLL_CLICKS = 3;
    private static final long PINCH_MIN_DURATION_MS = 60L;
    private static final float TWO_FINGER_DRAG_THRESHOLD = 18.0f;
    private static final float TWO_FINGER_PINCH_GUARD = 12.0f;
    private static final float TWO_FINGER_DRAG_DOMINANCE = 2.2f;
    private static final float TWO_FINGER_PINCH_DOMINANCE = 1.2f;
    private static final float TWO_FINGER_PINCH_ENTER_DEADZONE = 44.0f;
    private static final float TWO_FINGER_PINCH_ENTER_DOMINANCE = 1.45f;
    private static final float TWO_FINGER_PINCH_FORCE_DEADZONE = 72.0f;
    private static final float TWO_FINGER_PINCH_TO_DRAG_DOMINANCE = 1.35f;
    private static final int TWO_FINGER_MODE_UNDECIDED = 0;
    private static final int TWO_FINGER_MODE_PINCH = 1;
    private static final int TWO_FINGER_MODE_DRAG = 2;
    private final Finger[] fingers = new Finger[MAX_FINGERS];
    private byte numFingers = 0;
    private float sensitivity = 1.0f;
    private boolean pointerButtonLeftEnabled = true;
    private boolean pointerButtonRightEnabled = true;
    private Finger fingerPointerButtonLeft;
    private Finger fingerPointerButtonRight;
    private boolean tapDragMouseModeEnabled = false;
    private int tapDragPointerId = -1;
    private int tapDragSecondPointerId = -1;
    private int tapDragDownX = 0;
    private int tapDragDownY = 0;
    private int tapDragLastX = 0;
    private int tapDragLastY = 0;
    private int tapDragTwoFingerDownCenterX = 0;
    private int tapDragTwoFingerDownCenterY = 0;
    private int tapDragTwoFingerLastCenterX = 0;
    private int tapDragTwoFingerLastCenterY = 0;
    private float tapDragTwoFingerStartDistance = 0.0f;
    private float tapDragTwoFingerCurrentDistance = 0.0f;
    private long tapDragTwoFingerStartTimeMs = 0L;
    private int tapDragTwoFingerMode = TWO_FINGER_MODE_UNDECIDED;
    private long tapDragDownTimeMs = 0L;
    private boolean tapDragRightDragActive = false;
    private boolean tapDragLeftDragActive = false;
    private float scrollAccumY = 0;
    private boolean scrolling = false;
    private final XServer xServer;
    private Runnable fourFingersTapCallback;
    private final float[] xform = XForm.getInstance();

    public TouchpadView(Context context, XServer xServer) {
        super(context);
        this.xServer = xServer;
        setLayoutParams(new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
        setBackground(createTransparentBg());
        setClickable(true);
        setFocusable(true);
        setFocusableInTouchMode(false);
        updateXform(AppUtils.getScreenWidth(), AppUtils.getScreenHeight(), xServer.screenInfo.width, xServer.screenInfo.height);
    }

    @Override
    protected void onSizeChanged(int w, int h, int oldw, int oldh) {
        super.onSizeChanged(w, h, oldw, oldh);
        updateXform(w, h, xServer.screenInfo.width, xServer.screenInfo.height);
    }

    private void updateXform(int outerWidth, int outerHeight, int innerWidth, int innerHeight) {
        ViewTransformation viewTransformation = new ViewTransformation();
        viewTransformation.update(outerWidth, outerHeight, innerWidth, innerHeight);

        float invAspect = 1.0f / viewTransformation.aspect;
        if (!xServer.getRenderer().isFullscreen()) {
            XForm.makeTranslation(xform, -viewTransformation.viewOffsetX, -viewTransformation.viewOffsetY);
            XForm.scale(xform, invAspect, invAspect);
        }
        else XForm.makeScale(xform, invAspect, invAspect);
    }

    private class Finger {
        private int x;
        private int y;
        private final int startX;
        private final int startY;
        private int lastX;
        private int lastY;
        private final long touchTime;

        public Finger(float x, float y) {
            float[] transformedPoint = XForm.transformPoint(xform, x, y);
            this.x = this.startX = this.lastX = (int)transformedPoint[0];
            this.y = this.startY = this.lastY = (int)transformedPoint[1];
            touchTime = System.currentTimeMillis();
        }

        public void update(float x, float y) {
            lastX = this.x;
            lastY = this.y;
            float[] transformedPoint = XForm.transformPoint(xform, x, y);
            this.x = (int)transformedPoint[0];
            this.y = (int)transformedPoint[1];
        }

        private int deltaX() {
            float dx = (x - lastX) * sensitivity;
            if (Math.abs(dx) > CURSOR_ACCELERATION_THRESHOLD) dx *= CURSOR_ACCELERATION;
            return Mathf.roundPoint(dx);
        }

        private int deltaY() {
            float dy = (y - lastY) * sensitivity;
            if (Math.abs(dy) > CURSOR_ACCELERATION_THRESHOLD) dy *= CURSOR_ACCELERATION;
            return Mathf.roundPoint(dy);
        }

        private boolean isTap() {
            return (System.currentTimeMillis() - touchTime) < MAX_TAP_MILLISECONDS && travelDistance() < MAX_TAP_TRAVEL_DISTANCE;
        }

        private float travelDistance() {
            return (float)Math.hypot(x - startX, y - startY);
        }
    }

    @Override
    public boolean onTouchEvent(MotionEvent event) {
        if (tapDragMouseModeEnabled && !event.isFromSource(InputDevice.SOURCE_MOUSE)) {
            return handleTapDragMouseEvent(event);
        }

        int actionIndex = event.getActionIndex();
        int pointerId = event.getPointerId(actionIndex);
        int actionMasked = event.getActionMasked();
        if (pointerId >= MAX_FINGERS) return true;

        switch (actionMasked) {
            case MotionEvent.ACTION_DOWN:
            case MotionEvent.ACTION_POINTER_DOWN:
                if (event.isFromSource(InputDevice.SOURCE_MOUSE)) return true;
                scrollAccumY = 0;
                scrolling = false;
                fingers[pointerId] = new Finger(event.getX(actionIndex), event.getY(actionIndex));
                numFingers++;
                break;
            case MotionEvent.ACTION_MOVE:
                if (event.isFromSource(InputDevice.SOURCE_MOUSE)) {
                    float[] transformedPoint = XForm.transformPoint(xform, event.getX(), event.getY());
                    xServer.injectPointerMove((int)transformedPoint[0], (int)transformedPoint[1]);
                }
                else {
                    for (byte i = 0; i < MAX_FINGERS; i++) {
                        if (fingers[i] != null) {
                            int pointerIndex = event.findPointerIndex(i);
                            if (pointerIndex >= 0) {
                                fingers[i].update(event.getX(pointerIndex), event.getY(pointerIndex));
                                handleFingerMove(fingers[i]);
                            }
                            else {
                                handleFingerUp(fingers[i]);
                                fingers[i] = null;
                                numFingers--;
                            }
                        }
                    }
                }
                break;
            case MotionEvent.ACTION_UP:
            case MotionEvent.ACTION_POINTER_UP:
                if (fingers[pointerId] != null) {
                    fingers[pointerId].update(event.getX(actionIndex), event.getY(actionIndex));
                    handleFingerUp(fingers[pointerId]);
                    fingers[pointerId] = null;
                    numFingers--;
                }
                break;
            case MotionEvent.ACTION_CANCEL:
                for (byte i = 0; i < MAX_FINGERS; i++) fingers[i] = null;
                numFingers = 0;
                break;
        }

        return true;
    }

    private boolean handleTapDragMouseEvent(MotionEvent event) {
        int actionMasked = event.getActionMasked();
        int actionIndex = event.getActionIndex();
        int pointerId = event.getPointerId(actionIndex);

        if (ICP_DEBUG_LOG) {
            Log.i(TAG_ICP, "action=" + actionMasked + " index=" + actionIndex + " pid=" + pointerId +
                    " count=" + event.getPointerCount() + " mode=" + tapDragTwoFingerMode +
                    " p1=" + tapDragPointerId + " p2=" + tapDragSecondPointerId +
                    " dragL=" + tapDragLeftDragActive + " dragR=" + tapDragRightDragActive);
        }

        switch (actionMasked) {
            case MotionEvent.ACTION_DOWN: {
                float[] transformedPoint = XForm.transformPoint(xform, event.getX(actionIndex), event.getY(actionIndex));
                tapDragPointerId = pointerId;
                tapDragSecondPointerId = -1;
                tapDragDownX = (int) transformedPoint[0];
                tapDragDownY = (int) transformedPoint[1];
                tapDragLastX = tapDragDownX;
                tapDragLastY = tapDragDownY;
                tapDragDownTimeMs = System.currentTimeMillis();
                tapDragRightDragActive = false;
                tapDragLeftDragActive = false;
                resetTwoFingerState();
                if (ICP_DEBUG_LOG) {
                    Log.i(TAG_ICP, "DOWN set p1=" + tapDragPointerId + " x=" + tapDragDownX + " y=" + tapDragDownY);
                }
                break;
            }
            case MotionEvent.ACTION_POINTER_DOWN:
                if (tapDragSecondPointerId == -1 && tapDragPointerId != -1) {
                    tapDragSecondPointerId = pointerId;
                    int firstIndex = event.findPointerIndex(tapDragPointerId);
                    int secondIndex = event.findPointerIndex(tapDragSecondPointerId);
                    if (firstIndex >= 0 && secondIndex >= 0) {
                        float[] p1 = XForm.transformPoint(xform, event.getX(firstIndex), event.getY(firstIndex));
                        float[] p2 = XForm.transformPoint(xform, event.getX(secondIndex), event.getY(secondIndex));
                        tapDragTwoFingerDownCenterX = Math.round((p1[0] + p2[0]) * 0.5f);
                        tapDragTwoFingerDownCenterY = Math.round((p1[1] + p2[1]) * 0.5f);
                        tapDragTwoFingerLastCenterX = tapDragTwoFingerDownCenterX;
                        tapDragTwoFingerLastCenterY = tapDragTwoFingerDownCenterY;
                        tapDragTwoFingerStartDistance = (float)Math.hypot(p1[0] - p2[0], p1[1] - p2[1]);
                        tapDragTwoFingerCurrentDistance = tapDragTwoFingerStartDistance;
                        tapDragTwoFingerStartTimeMs = System.currentTimeMillis();
                        tapDragTwoFingerMode = TWO_FINGER_MODE_UNDECIDED;
                        if (ICP_DEBUG_LOG) {
                            Log.i(TAG_ICP, "POINTER_DOWN p1=" + tapDragPointerId + " p2=" + tapDragSecondPointerId +
                                    " startDist=" + tapDragTwoFingerStartDistance +
                                    " center=(" + tapDragTwoFingerDownCenterX + "," + tapDragTwoFingerDownCenterY + ")");
                        }
                    }
                }
                if (tapDragRightDragActive && xServer.pointer.isButtonPressed(Pointer.Button.BUTTON_RIGHT)) {
                    xServer.injectPointerButtonRelease(Pointer.Button.BUTTON_RIGHT);
                }
                tapDragRightDragActive = false;
                break;
            case MotionEvent.ACTION_MOVE: {
                if (tapDragPointerId == -1) break;

                if (tapDragSecondPointerId != -1) {
                    int firstIndex = event.findPointerIndex(tapDragPointerId);
                    int secondIndex = event.findPointerIndex(tapDragSecondPointerId);
                    if (firstIndex < 0 || secondIndex < 0) break;

                    float[] p1 = XForm.transformPoint(xform, event.getX(firstIndex), event.getY(firstIndex));
                    float[] p2 = XForm.transformPoint(xform, event.getX(secondIndex), event.getY(secondIndex));
                    int centerX = Math.round((p1[0] + p2[0]) * 0.5f);
                    int centerY = Math.round((p1[1] + p2[1]) * 0.5f);
                    tapDragTwoFingerCurrentDistance = (float)Math.hypot(p1[0] - p2[0], p1[1] - p2[1]);
                    float pinchDelta = tapDragTwoFingerCurrentDistance - tapDragTwoFingerStartDistance;
                    float centerTravel = (float) Math.hypot(
                            centerX - tapDragTwoFingerDownCenterX,
                            centerY - tapDragTwoFingerDownCenterY
                    );

                    float absPinchDelta = Math.abs(pinchDelta);
                    int prevMode = tapDragTwoFingerMode;

                    // Prefer dominant intent:
                    // - If center travel is much larger than distance delta, treat as drag.
                    // - If distance delta is much larger than center travel, treat as pinch.
                    if (tapDragTwoFingerMode == TWO_FINGER_MODE_UNDECIDED) {
                        if (centerTravel >= TWO_FINGER_DRAG_THRESHOLD &&
                                centerTravel >= absPinchDelta * TWO_FINGER_DRAG_DOMINANCE) {
                            tapDragTwoFingerMode = TWO_FINGER_MODE_DRAG;
                        } else if (absPinchDelta >= TWO_FINGER_PINCH_ENTER_DEADZONE &&
                                absPinchDelta >= centerTravel * TWO_FINGER_PINCH_ENTER_DOMINANCE) {
                            tapDragTwoFingerMode = TWO_FINGER_MODE_PINCH;
                        } else if (absPinchDelta >= TWO_FINGER_PINCH_FORCE_DEADZONE) {
                            tapDragTwoFingerMode = TWO_FINGER_MODE_PINCH;
                        } else if (centerTravel >= TWO_FINGER_DRAG_THRESHOLD * 2.0f &&
                                absPinchDelta <= PINCH_SCROLL_DEADZONE) {
                            tapDragTwoFingerMode = TWO_FINGER_MODE_DRAG;
                        }
                    }

                    // Allow drag -> pinch switch only when pinch intent clearly dominates.
                    if (tapDragTwoFingerMode == TWO_FINGER_MODE_DRAG &&
                            absPinchDelta >= PINCH_SCROLL_DEADZONE * 1.5f &&
                            absPinchDelta >= centerTravel * TWO_FINGER_PINCH_DOMINANCE) {
                        if (tapDragTwoFingerMode == TWO_FINGER_MODE_DRAG &&
                                tapDragLeftDragActive &&
                                xServer.pointer.isButtonPressed(Pointer.Button.BUTTON_LEFT)) {
                            xServer.injectPointerButtonRelease(Pointer.Button.BUTTON_LEFT);
                            tapDragLeftDragActive = false;
                        }
                        tapDragTwoFingerMode = TWO_FINGER_MODE_PINCH;
                    }
                    if (tapDragTwoFingerMode == TWO_FINGER_MODE_PINCH &&
                            centerTravel >= TWO_FINGER_DRAG_THRESHOLD * 2.0f &&
                            centerTravel >= absPinchDelta * TWO_FINGER_PINCH_TO_DRAG_DOMINANCE) {
                        tapDragTwoFingerMode = TWO_FINGER_MODE_DRAG;
                    }

                    if (ICP_DEBUG_LOG && (prevMode != tapDragTwoFingerMode || tapDragTwoFingerMode != TWO_FINGER_MODE_UNDECIDED)) {
                        Log.i(TAG_ICP, "MOVE2 mode=" + tapDragTwoFingerMode +
                                " pinchDelta=" + pinchDelta + " centerTravel=" + centerTravel +
                                " dist=" + tapDragTwoFingerCurrentDistance);
                    }

                    if (tapDragTwoFingerMode == TWO_FINGER_MODE_DRAG && !tapDragLeftDragActive) {
                        if (centerTravel >= TWO_FINGER_DRAG_THRESHOLD) {
                            xServer.injectPointerMove(tapDragTwoFingerDownCenterX, tapDragTwoFingerDownCenterY);
                            xServer.injectPointerButtonPress(Pointer.Button.BUTTON_LEFT);
                            tapDragLeftDragActive = true;
                            if (ICP_DEBUG_LOG) {
                                Log.i(TAG_ICP, "MOVE2 drag-start");
                            }
                        }
                    }

                    if (tapDragTwoFingerMode == TWO_FINGER_MODE_DRAG && tapDragLeftDragActive) {
                        int rawDx = centerX - tapDragTwoFingerLastCenterX;
                        int rawDy = centerY - tapDragTwoFingerLastCenterY;
                        int scaledDx = Math.round(rawDx * LEFT_DRAG_SENSITIVITY);
                        int scaledDy = Math.round(rawDy * LEFT_DRAG_SENSITIVITY);
                        if (scaledDx != 0 || scaledDy != 0) {
                            xServer.injectPointerMoveDelta(scaledDx, scaledDy);
                        }
                    }

                    tapDragTwoFingerLastCenterX = centerX;
                    tapDragTwoFingerLastCenterY = centerY;
                    break;
                }

                int idx = event.findPointerIndex(tapDragPointerId);
                if (idx < 0) break;

                float[] transformedPoint = XForm.transformPoint(xform, event.getX(idx), event.getY(idx));
                int currentX = (int) transformedPoint[0];
                int currentY = (int) transformedPoint[1];

                if (!tapDragRightDragActive) {
                    float travelDistance = (float) Math.hypot(currentX - tapDragDownX, currentY - tapDragDownY);
                    if (travelDistance >= MAX_TAP_TRAVEL_DISTANCE) {
                        xServer.injectPointerMove(tapDragDownX, tapDragDownY);
                        xServer.injectPointerButtonPress(Pointer.Button.BUTTON_RIGHT);
                        tapDragLastX = tapDragDownX;
                        tapDragLastY = tapDragDownY;
                        tapDragRightDragActive = true;
                    }
                }

                if (tapDragRightDragActive) {
                    int rawDx = currentX - tapDragLastX;
                    int rawDy = currentY - tapDragLastY;
                    int scaledDx = Math.round(rawDx * RIGHT_DRAG_SENSITIVITY);
                    int scaledDy = Math.round(rawDy * RIGHT_DRAG_SENSITIVITY);
                    if (scaledDx != 0 || scaledDy != 0) {
                        xServer.injectPointerMoveDelta(scaledDx, scaledDy);
                    }
                    tapDragLastX = currentX;
                    tapDragLastY = currentY;
                }
                break;
            }
            case MotionEvent.ACTION_UP:
            case MotionEvent.ACTION_POINTER_UP: {
                if (tapDragSecondPointerId != -1 &&
                        (pointerId == tapDragPointerId || pointerId == tapDragSecondPointerId)) {
                    if (tapDragTwoFingerMode == TWO_FINGER_MODE_UNDECIDED) {
                        float pinchDelta = tapDragTwoFingerCurrentDistance - tapDragTwoFingerStartDistance;
                        float centerTravel = (float) Math.hypot(
                                tapDragTwoFingerLastCenterX - tapDragTwoFingerDownCenterX,
                                tapDragTwoFingerLastCenterY - tapDragTwoFingerDownCenterY
                        );
                        if (Math.abs(pinchDelta) >= TWO_FINGER_PINCH_ENTER_DEADZONE &&
                                Math.abs(pinchDelta) >= centerTravel * TWO_FINGER_PINCH_ENTER_DOMINANCE) {
                            tapDragTwoFingerMode = TWO_FINGER_MODE_PINCH;
                        }
                    }
                    if (tapDragTwoFingerMode == TWO_FINGER_MODE_DRAG &&
                            tapDragLeftDragActive &&
                            xServer.pointer.isButtonPressed(Pointer.Button.BUTTON_LEFT)) {
                        xServer.injectPointerButtonRelease(Pointer.Button.BUTTON_LEFT);
                        if (ICP_DEBUG_LOG) {
                            Log.i(TAG_ICP, "POINTER_UP drag-end");
                        }
                    } else if (tapDragTwoFingerMode == TWO_FINGER_MODE_PINCH) {
                        long pinchDuration = System.currentTimeMillis() - tapDragTwoFingerStartTimeMs;
                        float pinchDelta = tapDragTwoFingerCurrentDistance - tapDragTwoFingerStartDistance;
                        if (ICP_DEBUG_LOG) {
                            Log.i(TAG_ICP, "POINTER_UP pinch duration=" + pinchDuration + " delta=" + pinchDelta);
                        }
                        if (pinchDuration >= PINCH_MIN_DURATION_MS) {
                            if (pinchDelta >= PINCH_SCROLL_DEADZONE) {
                                injectScrollClicks(Pointer.Button.BUTTON_SCROLL_UP, PINCH_SCROLL_CLICKS);
                                if (ICP_DEBUG_LOG) {
                                    Log.i(TAG_ICP, "PINCH->SCROLL_UP clicks=" + PINCH_SCROLL_CLICKS);
                                }
                            } else if (pinchDelta <= -PINCH_SCROLL_DEADZONE) {
                                injectScrollClicks(Pointer.Button.BUTTON_SCROLL_DOWN, PINCH_SCROLL_CLICKS);
                                if (ICP_DEBUG_LOG) {
                                    Log.i(TAG_ICP, "PINCH->SCROLL_DOWN clicks=" + PINCH_SCROLL_CLICKS);
                                }
                            }
                        }
                    }
                    tapDragPointerId = -1;
                    tapDragSecondPointerId = -1;
                    tapDragLeftDragActive = false;
                    tapDragRightDragActive = false;
                    resetTwoFingerState();
                    break;
                }

                if (pointerId != tapDragPointerId) break;
                float[] transformedPoint = XForm.transformPoint(xform, event.getX(actionIndex), event.getY(actionIndex));
                int upX = (int) transformedPoint[0];
                int upY = (int) transformedPoint[1];

                if (tapDragRightDragActive) {
                    int rawDx = upX - tapDragLastX;
                    int rawDy = upY - tapDragLastY;
                    int scaledDx = Math.round(rawDx * RIGHT_DRAG_SENSITIVITY);
                    int scaledDy = Math.round(rawDy * RIGHT_DRAG_SENSITIVITY);
                    if (scaledDx != 0 || scaledDy != 0) {
                        xServer.injectPointerMoveDelta(scaledDx, scaledDy);
                    }
                    if (xServer.pointer.isButtonPressed(Pointer.Button.BUTTON_RIGHT)) {
                        xServer.injectPointerButtonRelease(Pointer.Button.BUTTON_RIGHT);
                    }
                    if (ICP_DEBUG_LOG) {
                        Log.i(TAG_ICP, "UP right-drag-end");
                    }
                } else {
                    boolean isTap = (System.currentTimeMillis() - tapDragDownTimeMs) < MAX_TAP_MILLISECONDS &&
                            Math.hypot(upX - tapDragDownX, upY - tapDragDownY) < MAX_TAP_TRAVEL_DISTANCE;
                    if (isTap) {
                        xServer.injectPointerMove(upX, upY);
                        xServer.injectPointerButtonPress(Pointer.Button.BUTTON_LEFT);
                        xServer.injectPointerButtonRelease(Pointer.Button.BUTTON_LEFT);
                        if (ICP_DEBUG_LOG) {
                            Log.i(TAG_ICP, "UP tap->left-click");
                        }
                    }
                }

                tapDragPointerId = -1;
                tapDragSecondPointerId = -1;
                tapDragLeftDragActive = false;
                tapDragRightDragActive = false;
                resetTwoFingerState();
                break;
            }
            case MotionEvent.ACTION_CANCEL:
                if (tapDragLeftDragActive && xServer.pointer.isButtonPressed(Pointer.Button.BUTTON_LEFT)) {
                    xServer.injectPointerButtonRelease(Pointer.Button.BUTTON_LEFT);
                }
                if (tapDragRightDragActive && xServer.pointer.isButtonPressed(Pointer.Button.BUTTON_RIGHT)) {
                    xServer.injectPointerButtonRelease(Pointer.Button.BUTTON_RIGHT);
                }
                tapDragPointerId = -1;
                tapDragSecondPointerId = -1;
                tapDragLeftDragActive = false;
                tapDragRightDragActive = false;
                resetTwoFingerState();
                if (ICP_DEBUG_LOG) {
                    Log.i(TAG_ICP, "CANCEL reset");
                }
                break;
        }

        return true;
    }

    private void resetTwoFingerState() {
        tapDragTwoFingerDownCenterX = 0;
        tapDragTwoFingerDownCenterY = 0;
        tapDragTwoFingerLastCenterX = 0;
        tapDragTwoFingerLastCenterY = 0;
        tapDragTwoFingerStartDistance = 0.0f;
        tapDragTwoFingerCurrentDistance = 0.0f;
        tapDragTwoFingerStartTimeMs = 0L;
        tapDragTwoFingerMode = TWO_FINGER_MODE_UNDECIDED;
    }

    private void injectScrollClicks(Pointer.Button button, int clicks) {
        for (int i = 0; i < clicks; i++) {
            xServer.injectPointerButtonPress(button);
            xServer.injectPointerButtonRelease(button);
        }
    }

    private void handleFingerUp(Finger finger1) {
        switch (numFingers) {
            case 1:
                if (finger1.isTap()) pressPointerButtonLeft(finger1);
                break;
            case 2:
                Finger finger2 = findSecondFinger(finger1);
                if (finger2 != null && finger1.isTap()) pressPointerButtonRight(finger1);
                break;
            case 4:
                if (fourFingersTapCallback != null) {
                    for (byte i = 0; i < 4; i++) {
                        if (fingers[i] != null && !fingers[i].isTap()) return;
                    }
                    fourFingersTapCallback.run();
                }
                break;
        }

        releasePointerButtonLeft(finger1);
        releasePointerButtonRight(finger1);
    }

    private void handleFingerMove(Finger finger1) {
        boolean skipPointerMove = false;

        Finger finger2 = numFingers == 2 ? findSecondFinger(finger1) : null;
        if (finger2 != null) {
            final float resolutionScale = 1000.0f / Math.min(xServer.screenInfo.width, xServer.screenInfo.height);
            float currDistance = (float)Math.hypot(finger1.x - finger2.x, finger1.y - finger2.y) * resolutionScale;

            if (currDistance < MAX_TWO_FINGERS_SCROLL_DISTANCE) {
                scrollAccumY += ((finger1.y + finger2.y) * 0.5f) - (finger1.lastY + finger2.lastY) * 0.5f;

                if (scrollAccumY < -100) {
                    xServer.injectPointerButtonPress(Pointer.Button.BUTTON_SCROLL_DOWN);
                    xServer.injectPointerButtonRelease(Pointer.Button.BUTTON_SCROLL_DOWN);
                    scrollAccumY = 0;
                }
                else if (scrollAccumY > 100) {
                    xServer.injectPointerButtonPress(Pointer.Button.BUTTON_SCROLL_UP);
                    xServer.injectPointerButtonRelease(Pointer.Button.BUTTON_SCROLL_UP);
                    scrollAccumY = 0;
                }
                scrolling = true;
            }
            else if (currDistance >= MAX_TWO_FINGERS_SCROLL_DISTANCE && !xServer.pointer.isButtonPressed(Pointer.Button.BUTTON_LEFT) &&
                     finger2.travelDistance() < MAX_TAP_TRAVEL_DISTANCE) {
                pressPointerButtonLeft(finger1);
                skipPointerMove = true;
            }
        }

        if (!scrolling && numFingers <= 2 && !skipPointerMove) {
            int dx = finger1.deltaX();
            int dy = finger1.deltaY();

            if (xServer.isRelativeMouseMovement()) {
                WinHandler winHandler = xServer.getWinHandler();
                winHandler.mouseEvent(MouseEventFlags.MOVE, dx, dy, 0);
            }
            else xServer.injectPointerMoveDelta(dx, dy);
        }
    }

    private Finger findSecondFinger(Finger finger) {
        for (byte i = 0; i < MAX_FINGERS; i++) {
            if (fingers[i] != null && fingers[i] != finger) return fingers[i];
        }
        return null;
    }

    private void pressPointerButtonLeft(Finger finger) {
        if (pointerButtonLeftEnabled && !xServer.pointer.isButtonPressed(Pointer.Button.BUTTON_LEFT)) {
            xServer.injectPointerButtonPress(Pointer.Button.BUTTON_LEFT);
            fingerPointerButtonLeft = finger;
        }
    }

    private void pressPointerButtonRight(Finger finger) {
        if (pointerButtonRightEnabled && !xServer.pointer.isButtonPressed(Pointer.Button.BUTTON_RIGHT)) {
            xServer.injectPointerButtonPress(Pointer.Button.BUTTON_RIGHT);
            fingerPointerButtonRight = finger;
        }
    }

    private void releasePointerButtonLeft(final Finger finger) {
        if (pointerButtonLeftEnabled && finger == fingerPointerButtonLeft && xServer.pointer.isButtonPressed(Pointer.Button.BUTTON_LEFT)) {
            postDelayed(() -> {
                xServer.injectPointerButtonRelease(Pointer.Button.BUTTON_LEFT);
                fingerPointerButtonLeft = null;
            }, 30);
        }
    }

    private void releasePointerButtonRight(final Finger finger) {
        if (pointerButtonRightEnabled && finger == fingerPointerButtonRight && xServer.pointer.isButtonPressed(Pointer.Button.BUTTON_RIGHT)) {
            postDelayed(() -> {
                xServer.injectPointerButtonRelease(Pointer.Button.BUTTON_RIGHT);
                fingerPointerButtonRight = null;
            }, 30);
        }
    }

    public void setSensitivity(float sensitivity) {
        this.sensitivity = sensitivity;
    }

    public boolean isPointerButtonLeftEnabled() {
        return pointerButtonLeftEnabled;
    }

    public void setPointerButtonLeftEnabled(boolean pointerButtonLeftEnabled) {
        this.pointerButtonLeftEnabled = pointerButtonLeftEnabled;
    }

    public boolean isPointerButtonRightEnabled() {
        return pointerButtonRightEnabled;
    }

    public void setPointerButtonRightEnabled(boolean pointerButtonRightEnabled) {
        this.pointerButtonRightEnabled = pointerButtonRightEnabled;
    }

    public void setTapDragMouseModeEnabled(boolean tapDragMouseModeEnabled) {
        this.tapDragMouseModeEnabled = tapDragMouseModeEnabled;
        if (!tapDragMouseModeEnabled) {
            if (tapDragRightDragActive && xServer.pointer.isButtonPressed(Pointer.Button.BUTTON_RIGHT)) {
                xServer.injectPointerButtonRelease(Pointer.Button.BUTTON_RIGHT);
            }
            if (tapDragLeftDragActive && xServer.pointer.isButtonPressed(Pointer.Button.BUTTON_LEFT)) {
                xServer.injectPointerButtonRelease(Pointer.Button.BUTTON_LEFT);
            }
            tapDragPointerId = -1;
            tapDragSecondPointerId = -1;
            tapDragLeftDragActive = false;
            tapDragRightDragActive = false;
            resetTwoFingerState();
        }
    }

    public boolean isTapDragMouseModeEnabled() {
        return tapDragMouseModeEnabled;
    }

    public void setFourFingersTapCallback(Runnable fourFingersTapCallback) {
        this.fourFingersTapCallback = fourFingersTapCallback;
    }

    public boolean onExternalMouseEvent(MotionEvent event) {
        boolean handled = false;
        if (event.isFromSource(InputDevice.SOURCE_MOUSE)) {
            int actionButton = event.getActionButton();
            switch (event.getAction()) {
                case MotionEvent.ACTION_BUTTON_PRESS:
                    if (actionButton == MotionEvent.BUTTON_PRIMARY) {
                        xServer.injectPointerButtonPress(Pointer.Button.BUTTON_LEFT);
                    }
                    else if (actionButton == MotionEvent.BUTTON_SECONDARY) {
                        xServer.injectPointerButtonPress(Pointer.Button.BUTTON_RIGHT);
                    }
                    handled = true;
                    break;
                case MotionEvent.ACTION_BUTTON_RELEASE:
                    if (actionButton == MotionEvent.BUTTON_PRIMARY) {
                        xServer.injectPointerButtonRelease(Pointer.Button.BUTTON_LEFT);
                    }
                    else if (actionButton == MotionEvent.BUTTON_SECONDARY) {
                        xServer.injectPointerButtonRelease(Pointer.Button.BUTTON_RIGHT);
                    }
                    handled = true;
                    break;
                case MotionEvent.ACTION_HOVER_MOVE:
                    float[] transformedPoint = XForm.transformPoint(xform, event.getX(), event.getY());
                    xServer.injectPointerMove((int)transformedPoint[0], (int)transformedPoint[1]);
                    handled = true;
                    break;
                case MotionEvent.ACTION_SCROLL:
                    float scrollY = event.getAxisValue(MotionEvent.AXIS_VSCROLL);
                    if (scrollY <= -1.0f) {
                        xServer.injectPointerButtonPress(Pointer.Button.BUTTON_SCROLL_DOWN);
                        xServer.injectPointerButtonRelease(Pointer.Button.BUTTON_SCROLL_DOWN);
                    }
                    else if (scrollY >= 1.0f) {
                        xServer.injectPointerButtonPress(Pointer.Button.BUTTON_SCROLL_UP);
                        xServer.injectPointerButtonRelease(Pointer.Button.BUTTON_SCROLL_UP);
                    }
                    handled = true;
                    break;
            }
        }
        return handled;
    }

    public float[] computeDeltaPoint(float lastX, float lastY, float x, float y) {
        final float[] result = {0, 0};

        XForm.transformPoint(xform, lastX, lastY, result);
        lastX = result[0];
        lastY = result[1];

        XForm.transformPoint(xform, x, y, result);
        x = result[0];
        y = result[1];

        result[0] = x - lastX;
        result[1] = y - lastY;
        return result;
    }

    private StateListDrawable createTransparentBg() {
        StateListDrawable stateListDrawable = new StateListDrawable();

        ColorDrawable focusedDrawable = new ColorDrawable(Color.TRANSPARENT);
        ColorDrawable defaultDrawable = new ColorDrawable(Color.TRANSPARENT);

        stateListDrawable.addState(new int[]{android.R.attr.state_focused}, focusedDrawable);
        stateListDrawable.addState(new int[]{}, defaultDrawable);

        return stateListDrawable;
    }
}
