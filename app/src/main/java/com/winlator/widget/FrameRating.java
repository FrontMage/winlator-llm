package com.winlator.widget;

import android.app.ActivityManager;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.RectF;
import android.graphics.Typeface;
import android.os.BatteryManager;
import android.os.SystemClock;
import android.util.AttributeSet;
import android.util.TypedValue;
import android.view.View;

import androidx.annotation.Nullable;

import java.io.BufferedReader;
import java.io.FileReader;
import java.io.IOException;
import java.util.ArrayDeque;
import java.util.Locale;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.ScheduledFuture;
import java.util.concurrent.TimeUnit;

public class FrameRating extends View implements Runnable {
    private static final int MAX_FRAME_SAMPLES = 60;
    private static final int FRAME_UPDATE_INTERVAL_MS = 500;
    private static final int STAT_UPDATE_INTERVAL_MS = 1000;

    private final ActivityManager activityManager;
    private final BatteryManager batteryManager;
    private final Paint backgroundPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint separatorPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint graphPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint graphGridPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint valuePaint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint valueStrokePaint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint enginePaint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint engineStrokePaint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint labelGpuPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint labelCpuPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint labelRamPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint labelPowerPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint labelFpsPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final RectF tempRect = new RectF();
    private final ArrayDeque<Float> frameTimes = new ArrayDeque<>(MAX_FRAME_SAMPLES);

    private ScheduledExecutorService scheduler;
    private ScheduledFuture<?> statsFuture;
    private long lastStatsTotal = -1L;
    private long lastStatsIdle = -1L;
    private long lastFrameCounterTime = 0L;
    private long lastFrameSampleTime = 0L;
    private int frameCount = 0;
    private float fps = 0.0f;
    private int gpuUsage = -1;
    private int cpuUsage = 0;
    private int ramUsage = 0;
    private float powerWatts = Float.NaN;
    private String powerText = "--";
    private String engineLabel = "DXVK";

    public FrameRating(Context context) {
        this(context, null);
    }

    public FrameRating(Context context, @Nullable AttributeSet attrs) {
        this(context, attrs, 0);
    }

    public FrameRating(Context context, @Nullable AttributeSet attrs, int defStyleAttr) {
        super(context, attrs, defStyleAttr);
        activityManager = (ActivityManager) context.getSystemService(Context.ACTIVITY_SERVICE);
        batteryManager = (BatteryManager) context.getSystemService(Context.BATTERY_SERVICE);

        float labelSize = sp(11.0f);
        float valueSize = sp(11.5f);
        float engineSize = sp(12.0f);

        backgroundPaint.setColor(Color.argb(190, 0, 0, 0));
        separatorPaint.setColor(Color.rgb(220, 220, 220));
        separatorPaint.setStrokeWidth(dp(1.0f));

        graphPaint.setColor(Color.rgb(0, 255, 0));
        graphPaint.setStyle(Paint.Style.STROKE);
        graphPaint.setStrokeWidth(dp(2.5f));

        graphGridPaint.setColor(Color.argb(110, 220, 220, 220));
        graphGridPaint.setStyle(Paint.Style.STROKE);
        graphGridPaint.setStrokeWidth(dp(1.0f));

        Typeface monospace = Typeface.MONOSPACE;

        valuePaint.setColor(Color.WHITE);
        valuePaint.setTextSize(valueSize);
        valuePaint.setFakeBoldText(true);
        valuePaint.setTypeface(monospace);

        valueStrokePaint.set(valuePaint);
        valueStrokePaint.setStyle(Paint.Style.STROKE);
        valueStrokePaint.setStrokeWidth(dp(3.0f));
        valueStrokePaint.setColor(Color.BLACK);

        enginePaint.setColor(Color.rgb(255, 80, 91));
        enginePaint.setTextSize(engineSize);
        enginePaint.setFakeBoldText(true);

        engineStrokePaint.set(enginePaint);
        engineStrokePaint.setStyle(Paint.Style.STROKE);
        engineStrokePaint.setStrokeWidth(dp(3.0f));
        engineStrokePaint.setColor(Color.BLACK);

        configureLabelPaint(labelGpuPaint, Color.rgb(100, 255, 100), labelSize);
        configureLabelPaint(labelCpuPaint, Color.rgb(255, 175, 0), labelSize);
        configureLabelPaint(labelRamPaint, Color.rgb(80, 200, 255), labelSize);
        configureLabelPaint(labelPowerPaint, Color.rgb(200, 120, 255), labelSize);
        configureLabelPaint(labelFpsPaint, Color.rgb(255, 255, 80), labelSize);

        setWillNotDraw(false);
        setVisibility(GONE);
        setClickable(false);
        setImportantForAccessibility(IMPORTANT_FOR_ACCESSIBILITY_NO);
        setPadding(dp(8.0f), dp(6.0f), dp(8.0f), dp(6.0f));
    }

    private void configureLabelPaint(Paint paint, int color, float textSize) {
        paint.setColor(color);
        paint.setTextSize(textSize);
        paint.setFakeBoldText(true);
    }

    private int dp(float value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }

    private float sp(float value) {
        return TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, value, getResources().getDisplayMetrics());
    }

    public void setEngineLabel(@Nullable String engineLabel) {
        String value = engineLabel != null && !engineLabel.trim().isEmpty() ? engineLabel.trim() : "DXVK";
        if (!value.equals(this.engineLabel)) {
            this.engineLabel = value;
            postInvalidateOnAnimation();
        }
    }

    public void startMonitoring() {
        if (statsFuture != null && !statsFuture.isCancelled()) return;
        if (scheduler == null || scheduler.isShutdown()) {
            scheduler = Executors.newSingleThreadScheduledExecutor();
        }
        statsFuture = scheduler.scheduleAtFixedRate(this::updateSystemStats, 0L, STAT_UPDATE_INTERVAL_MS, TimeUnit.MILLISECONDS);
    }

    public void stopMonitoring() {
        if (statsFuture != null) {
            statsFuture.cancel(true);
            statsFuture = null;
        }
        if (scheduler != null) {
            scheduler.shutdownNow();
            scheduler = null;
        }
    }

    public void update() {
        long now = SystemClock.elapsedRealtime();
        if (lastFrameCounterTime == 0L) {
            lastFrameCounterTime = now;
        }
        if (lastFrameSampleTime != 0L) {
            float frameTimeMs = now - lastFrameSampleTime;
            if (frameTimeMs > 0.0f) {
                synchronized (frameTimes) {
                    if (frameTimes.size() >= MAX_FRAME_SAMPLES) {
                        frameTimes.removeFirst();
                    }
                    frameTimes.addLast(frameTimeMs);
                }
            }
        }
        lastFrameSampleTime = now;

        if (now >= lastFrameCounterTime + FRAME_UPDATE_INTERVAL_MS) {
            fps = (frameCount * 1000.0f) / Math.max(1L, now - lastFrameCounterTime);
            frameCount = 0;
            lastFrameCounterTime = now;
            post(this);
        }

        frameCount++;
    }

    private void updateSystemStats() {
        gpuUsage = readGpuUsage();
        cpuUsage = readCpuUsage();
        ramUsage = readRamUsage();
        powerWatts = readPowerWatts();
        powerText = Float.isNaN(powerWatts) ? "--" : String.format(Locale.ENGLISH, "%.1fW", powerWatts);
        post(this);
    }

    private int readRamUsage() {
        if (activityManager == null) return 0;
        ActivityManager.MemoryInfo memoryInfo = new ActivityManager.MemoryInfo();
        activityManager.getMemoryInfo(memoryInfo);
        if (memoryInfo.totalMem <= 0L) return 0;
        long usedMem = memoryInfo.totalMem - memoryInfo.availMem;
        return Math.max(0, Math.min(100, (int) Math.round((usedMem * 100.0) / memoryInfo.totalMem)));
    }

    private int readCpuUsage() {
        try (BufferedReader reader = new BufferedReader(new FileReader("/proc/stat"))) {
            String line = reader.readLine();
            if (line == null || !line.startsWith("cpu ")) return cpuUsage;
            String[] parts = line.trim().split("\\s+");
            if (parts.length < 8) return cpuUsage;

            long user = Long.parseLong(parts[1]);
            long nice = Long.parseLong(parts[2]);
            long system = Long.parseLong(parts[3]);
            long idle = Long.parseLong(parts[4]);
            long iowait = Long.parseLong(parts[5]);
            long irq = Long.parseLong(parts[6]);
            long softirq = Long.parseLong(parts[7]);
            long steal = parts.length > 8 ? Long.parseLong(parts[8]) : 0L;

            long idleAll = idle + iowait;
            long total = user + nice + system + idle + iowait + irq + softirq + steal;

            if (lastStatsTotal < 0L || lastStatsIdle < 0L) {
                lastStatsTotal = total;
                lastStatsIdle = idleAll;
                return cpuUsage;
            }

            long totalDelta = total - lastStatsTotal;
            long idleDelta = idleAll - lastStatsIdle;
            lastStatsTotal = total;
            lastStatsIdle = idleAll;
            if (totalDelta <= 0L) return cpuUsage;

            int usage = (int) Math.round(((totalDelta - idleDelta) * 100.0) / totalDelta);
            return Math.max(0, Math.min(100, usage));
        }
        catch (IOException | NumberFormatException ignored) {
            return cpuUsage;
        }
    }

    private int readGpuUsage() {
        try (BufferedReader reader = new BufferedReader(new FileReader("/sys/class/kgsl/kgsl-3d0/gpubusy"))) {
            String line = reader.readLine();
            if (line == null || line.trim().isEmpty()) return -1;

            String[] parts = line.trim().split("\\s+");
            if (parts.length < 2) return -1;

            long busy = Long.parseLong(parts[0]);
            long total = Long.parseLong(parts[1]);
            if (total <= 0L) return -1;

            int usage = (int) Math.round((busy * 100.0) / total);
            return Math.max(0, Math.min(100, usage));
        }
        catch (IOException | NumberFormatException ignored) {
            return -1;
        }
    }

    private float readPowerWatts() {
        if (batteryManager == null) return Float.NaN;

        Intent batteryIntent = getContext().registerReceiver(null, new IntentFilter(Intent.ACTION_BATTERY_CHANGED));
        int voltageMv = batteryIntent != null ? batteryIntent.getIntExtra(BatteryManager.EXTRA_VOLTAGE, -1) : -1;
        if (voltageMv <= 0) return Float.NaN;

        int currentUa = batteryManager.getIntProperty(BatteryManager.BATTERY_PROPERTY_CURRENT_NOW);
        if (currentUa == Integer.MIN_VALUE || currentUa == 0) return Float.NaN;

        return Math.abs((currentUa / 1_000_000.0f) * (voltageMv / 1000.0f));
    }

    @Override
    public void run() {
        if (getVisibility() == GONE) setVisibility(VISIBLE);
        invalidate();
    }

    @Override
    protected void onDetachedFromWindow() {
        stopMonitoring();
        removeCallbacks(this);
        super.onDetachedFromWindow();
    }

    @Override
    protected void onMeasure(int widthMeasureSpec, int heightMeasureSpec) {
        float engineWidth = enginePaint.measureText(engineLabel);
        float labelWidth = Math.max(
                Math.max(labelGpuPaint.measureText("GPU"), labelCpuPaint.measureText("CPU")),
                Math.max(labelRamPaint.measureText("RAM"),
                        Math.max(labelPowerPaint.measureText("PWR"), labelFpsPaint.measureText("FPS"))));
        float valueWidth = valuePaint.measureText("100%");
        float powerWidth = valuePaint.measureText("00.0W");
        float fpsWidth = valuePaint.measureText("000.0");

        float textHeight = valuePaint.getFontMetrics().descent - valuePaint.getFontMetrics().ascent;
        int contentHeight = Math.round(Math.max(textHeight, dp(20.0f)));
        int graphWidth = dp(128.0f);
        int totalWidth = getPaddingLeft() + getPaddingRight()
                + Math.round(engineWidth)
                + dp(6.0f)
                + dp(8.0f)
                + Math.round(labelWidth + dp(4.0f) + valueWidth)
                + dp(8.0f)
                + Math.round(labelWidth + dp(6.0f) + valueWidth)
                + dp(8.0f)
                + Math.round(labelWidth + dp(6.0f) + valueWidth)
                + dp(8.0f)
                + Math.round(labelWidth + dp(6.0f) + powerWidth)
                + dp(8.0f)
                + Math.round(labelWidth + dp(6.0f) + fpsWidth)
                + dp(10.0f)
                + graphWidth;
        int totalHeight = getPaddingTop() + getPaddingBottom() + contentHeight;

        setMeasuredDimension(resolveSize(totalWidth, widthMeasureSpec), resolveSize(totalHeight, heightMeasureSpec));
    }

    @Override
    protected void onDraw(Canvas canvas) {
        super.onDraw(canvas);

        float width = getWidth();
        float height = getHeight();
        float corner = dp(4.0f);
        tempRect.set(0.0f, 0.0f, width, height);
        canvas.drawRoundRect(tempRect, corner, corner, backgroundPaint);

        Paint.FontMetrics valueMetrics = valuePaint.getFontMetrics();
        float textBaseline = (height / 2.0f) - ((valueMetrics.ascent + valueMetrics.descent) / 2.0f);
        float x = getPaddingLeft();

        x = drawTextPair(canvas, x, textBaseline, engineLabel, null, enginePaint, engineStrokePaint, true) + dp(6.0f);
        x = drawSeparator(canvas, x, height);
        x = drawMetric(canvas, x, textBaseline, "GPU", formatPercentValue(gpuUsage), labelGpuPaint);
        x = drawSeparator(canvas, x, height);
        x = drawMetric(canvas, x, textBaseline, "CPU", formatPercentValue(cpuUsage), labelCpuPaint);
        x = drawSeparator(canvas, x, height);
        x = drawMetric(canvas, x, textBaseline, "RAM", formatPercentValue(ramUsage), labelRamPaint);
        x = drawSeparator(canvas, x, height);
        x = drawMetric(canvas, x, textBaseline, "PWR", powerText, labelPowerPaint);
        x = drawSeparator(canvas, x, height);
        x = drawMetric(canvas, x, textBaseline, "FPS", String.format(Locale.ENGLISH, "%.1f", fps), labelFpsPaint);
        x = drawSeparator(canvas, x, height);
        drawGraph(canvas, x + dp(6.0f), getPaddingTop() + dp(3.0f), getWidth() - getPaddingRight() - dp(3.0f), getHeight() - getPaddingBottom() - dp(3.0f));
    }

    private float drawMetric(Canvas canvas, float x, float baseline, String label, String value, Paint labelPaint) {
        x = drawTextPair(canvas, x, baseline, label, value, labelPaint, null, false);
        return x + dp(6.0f);
    }

    private float drawTextPair(Canvas canvas, float x, float baseline, String label, @Nullable String value, Paint labelPaint, @Nullable Paint labelStrokePaint, boolean largeGap) {
        if (labelStrokePaint != null) {
            canvas.drawText(label, x, baseline, labelStrokePaint);
        }
        canvas.drawText(label, x, baseline, labelPaint);
        x += labelPaint.measureText(label);
        if (value != null) {
            x += largeGap ? dp(8.0f) : dp(4.0f);
            canvas.drawText(value, x, baseline, valueStrokePaint);
            canvas.drawText(value, x, baseline, valuePaint);
            x += valuePaint.measureText(value);
        }
        return x;
    }

    private float drawSeparator(Canvas canvas, float x, float height) {
        float lineX = x + dp(1.0f);
        float lineTop = dp(6.0f);
        float lineBottom = height - dp(6.0f);
        canvas.drawLine(lineX, lineTop, lineX, lineBottom, separatorPaint);
        return lineX + dp(6.0f);
    }

    private String formatPercentValue(int value) {
        if (value < 0) {
            return "  0%";
        }
        return String.format(Locale.ENGLISH, "%3d%%", value);
    }

    private void drawGraph(Canvas canvas, float left, float top, float right, float bottom) {
        if (right <= left || bottom <= top) return;

        float midY = top + ((bottom - top) / 2.0f);
        canvas.drawLine(left, midY, right, midY, graphGridPaint);

        Float[] samples;
        synchronized (frameTimes) {
            samples = frameTimes.toArray(new Float[0]);
        }
        if (samples.length < 2) return;

        float min = Float.MAX_VALUE;
        float max = Float.MIN_VALUE;
        for (Float sample : samples) {
            if (sample == null) continue;
            min = Math.min(min, sample);
            max = Math.max(max, sample);
        }
        if (min == Float.MAX_VALUE || max == Float.MIN_VALUE) return;
        float span = Math.max(4.0f, max - min);
        float low = min - 1.0f;
        Path path = new Path();
        float step = (right - left) / (samples.length - 1);
        for (int i = 0; i < samples.length; i++) {
            float normalized = (samples[i] - low) / span;
            normalized = Math.max(0.0f, Math.min(1.0f, normalized));
            float x = left + (i * step);
            float y = bottom - (normalized * (bottom - top));
            if (i == 0) {
                path.moveTo(x, y);
            }
            else {
                path.lineTo(x, y);
            }
        }
        canvas.drawPath(path, graphPaint);
    }
}
