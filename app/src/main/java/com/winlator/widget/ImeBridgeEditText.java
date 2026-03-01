package com.winlator.widget;

import android.content.Context;
import android.text.Editable;
import android.text.InputType;
import android.util.AttributeSet;
import android.util.Log;
import android.view.KeyEvent;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputConnection;
import android.view.inputmethod.InputConnectionWrapper;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.appcompat.widget.AppCompatEditText;

public class ImeBridgeEditText extends AppCompatEditText {
    private static final String IME_LOG_TAG = "ImeBridge";
    public interface Listener {
        void onCommitText(CharSequence text);
        void onDeleteSurroundingText(int beforeLength, int afterLength);
        void onSendKeyEvent(KeyEvent event);
        void onEditorAction(int actionCode);
    }

    private Listener listener;

    public ImeBridgeEditText(@NonNull Context context) {
        super(context);
        init();
    }

    public ImeBridgeEditText(@NonNull Context context, @Nullable AttributeSet attrs) {
        super(context, attrs);
        init();
    }

    public ImeBridgeEditText(@NonNull Context context, @Nullable AttributeSet attrs, int defStyleAttr) {
        super(context, attrs, defStyleAttr);
        init();
    }

    private void init() {
        setFocusable(true);
        setFocusableInTouchMode(true);
        setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_FLAG_MULTI_LINE);
    }

    public void setListener(@Nullable Listener listener) {
        this.listener = listener;
    }

    @Override
    public boolean onCheckIsTextEditor() {
        return true;
    }

    @Override
    public InputConnection onCreateInputConnection(EditorInfo outAttrs) {
        final InputConnection base = super.onCreateInputConnection(outAttrs);
        outAttrs.imeOptions |= EditorInfo.IME_FLAG_NO_FULLSCREEN;

        return new InputConnectionWrapper(base, true) {
            @Override
            public boolean commitText(CharSequence text, int newCursorPosition) {
                if (listener != null && text != null && text.length() > 0) {
                    Log.i(IME_LOG_TAG, "[EditText] commitText text=\"" + text + "\" len=" + text.length());
                    listener.onCommitText(text);
                }
                boolean result = super.commitText(text, newCursorPosition);
                Editable editable = getEditableText();
                if (editable != null && editable.length() > 64) {
                    editable.delete(0, editable.length() - 32);
                }
                return result;
            }

            @Override
            public boolean setComposingText(CharSequence text, int newCursorPosition) {
                Log.i(IME_LOG_TAG, "[EditText] setComposingText text=\"" + text + "\" len=" + (text == null ? 0 : text.length()));
                return super.setComposingText(text, newCursorPosition);
            }

            @Override
            public boolean finishComposingText() {
                Log.i(IME_LOG_TAG, "[EditText] finishComposingText");
                return super.finishComposingText();
            }

            @Override
            public boolean deleteSurroundingText(int beforeLength, int afterLength) {
                if (listener != null) {
                    Log.i(IME_LOG_TAG, "[EditText] deleteSurroundingText before=" + beforeLength + " after=" + afterLength);
                    listener.onDeleteSurroundingText(beforeLength, afterLength);
                }
                return true;
            }

            @Override
            public boolean sendKeyEvent(KeyEvent event) {
                if (listener != null && event != null) {
                    Log.i(IME_LOG_TAG, "[EditText] sendKeyEvent action=" + event.getAction() + " keyCode=" + event.getKeyCode());
                    listener.onSendKeyEvent(event);
                }
                return super.sendKeyEvent(event);
            }

            @Override
            public boolean performEditorAction(int actionCode) {
                if (listener != null) {
                    Log.i(IME_LOG_TAG, "[EditText] performEditorAction actionCode=" + actionCode);
                    listener.onEditorAction(actionCode);
                }
                return super.performEditorAction(actionCode);
            }
        };
    }
}
