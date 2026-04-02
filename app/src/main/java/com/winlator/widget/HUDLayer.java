package com.winlator.widget;

import android.content.Context;
import android.content.SharedPreferences;
import android.os.Handler;
import android.os.Looper;
import android.util.AttributeSet;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewConfiguration;
import android.widget.FrameLayout;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.preference.PreferenceManager;

public class HUDLayer extends FrameLayout {
    private static final String PREF_HUD_X = "hud_x";
    private static final String PREF_HUD_Y = "hud_y";

    private final SharedPreferences preferences;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private final Runnable persistPositionRunnable = this::persistPosition;
    private final int touchSlop;
    private final float defaultMarginPx;
    private final FrameRating frameRating;

    private float downRawX;
    private float downRawY;
    private float startX;
    private float startY;
    private boolean dragging = false;
    private boolean positionApplied = false;

    public HUDLayer(@NonNull Context context) {
        this(context, null);
    }

    public HUDLayer(@NonNull Context context, @Nullable AttributeSet attrs) {
        this(context, attrs, 0);
    }

    public HUDLayer(@NonNull Context context, @Nullable AttributeSet attrs, int defStyleAttr) {
        super(context, attrs, defStyleAttr);
        preferences = PreferenceManager.getDefaultSharedPreferences(context);
        touchSlop = ViewConfiguration.get(context).getScaledTouchSlop();
        defaultMarginPx = dp(12.0f);

        setClipToPadding(false);
        setClipChildren(false);

        frameRating = new FrameRating(context);
        frameRating.setVisibility(GONE);
        addView(frameRating, new LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT));
        setVisibility(GONE);

        frameRating.setOnTouchListener(this::handleTouch);
        addOnLayoutChangeListener((v, left, top, right, bottom, oldLeft, oldTop, oldRight, oldBottom) -> {
            if (right - left <= 0 || bottom - top <= 0) return;
            if (!positionApplied) {
                applySavedPosition();
            }
            else {
                clampToParent();
            }
        });
    }

    public FrameRating getFrameRating() {
        return frameRating;
    }

    public void show() {
        if (getVisibility() != VISIBLE) {
            setVisibility(VISIBLE);
        }
        if (frameRating.getVisibility() != VISIBLE) {
            frameRating.setVisibility(VISIBLE);
        }
        post(this::clampToParent);
    }

    public void hide() {
        frameRating.setDragHighlighted(false);
        dragging = false;
        frameRating.setVisibility(GONE);
        setVisibility(GONE);
    }

    public void ensureClamped() {
        post(this::clampToParent);
    }

    private boolean handleTouch(View view, MotionEvent event) {
        switch (event.getActionMasked()) {
            case MotionEvent.ACTION_DOWN:
                downRawX = event.getRawX();
                downRawY = event.getRawY();
                startX = getX();
                startY = getY();
                dragging = false;
                handler.removeCallbacks(persistPositionRunnable);
                return true;
            case MotionEvent.ACTION_MOVE:
                float deltaX = event.getRawX() - downRawX;
                float deltaY = event.getRawY() - downRawY;
                if (!dragging && Math.hypot(deltaX, deltaY) > touchSlop) {
                    dragging = true;
                    frameRating.setDragHighlighted(true);
                }
                if (dragging) {
                    setX(startX + deltaX);
                    setY(startY + deltaY);
                    clampToParent();
                }
                return true;
            case MotionEvent.ACTION_UP:
            case MotionEvent.ACTION_CANCEL:
                if (dragging) {
                    clampToParent();
                    frameRating.setDragHighlighted(false);
                    dragging = false;
                    handler.removeCallbacks(persistPositionRunnable);
                    handler.postDelayed(persistPositionRunnable, 300L);
                }
                return true;
            default:
                return false;
        }
    }

    private void applySavedPosition() {
        float x = preferences.contains(PREF_HUD_X) ? preferences.getFloat(PREF_HUD_X, defaultMarginPx) : defaultMarginPx;
        float y = preferences.contains(PREF_HUD_Y) ? preferences.getFloat(PREF_HUD_Y, defaultMarginPx) : defaultMarginPx;
        setX(x);
        setY(y);
        positionApplied = true;
        clampToParent();
    }

    private void clampToParent() {
        View parent = (View) getParent();
        if (parent == null) return;

        float maxX = Math.max(0.0f, parent.getWidth() - getWidth());
        float maxY = Math.max(0.0f, parent.getHeight() - getHeight());
        float clampedX = Math.max(0.0f, Math.min(getX(), maxX));
        float clampedY = Math.max(0.0f, Math.min(getY(), maxY));
        if (clampedX != getX()) setX(clampedX);
        if (clampedY != getY()) setY(clampedY);
    }

    private void persistPosition() {
        preferences.edit()
                .putFloat(PREF_HUD_X, getX())
                .putFloat(PREF_HUD_Y, getY())
                .apply();
    }

    private float dp(float value) {
        return value * getResources().getDisplayMetrics().density;
    }
}
