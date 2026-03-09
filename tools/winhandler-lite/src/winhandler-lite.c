#include <winsock2.h>
#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#pragma comment(lib, "ws2_32")

#define LISTEN_PORT 7952
#define HOST_PORT 7947

#define PKT_LITE_READY 0x70
#define PKT_LITE_LOG 0x71
#define PKT_LITE_LOG_TEXT 0x72
#define PKT_LITE_FOCUS 0x73
#define PKT_REQ_TEXT 0x01

#define BRIDGE_PORT 38442

#define STAGE_RECV_TEXT 1
#define STAGE_DONE 4
#define STAGE_INVALID_PACKET 5
#define STAGE_TARGET_RESOLVE 20
#define STAGE_MSG_INJECT_BEGIN 21
#define STAGE_MSG_INJECT_END 22
#define STAGE_MSG_INJECT_FAILED 23
#define STAGE_MSG_INJECT_MODE 24
#define STAGE_CTX_ATTACH_FOCUS_OK 44
#define STAGE_CTX_ATTACH_FOCUS_ERR 45
#define STAGE_CTX_FG_HWND 46
#define STAGE_CTX_FOCUS_HWND 47
#define STAGE_CLIP_OPEN_BEGIN 50
#define STAGE_CLIP_OPEN_OK 51
#define STAGE_CLIP_OPEN_FAIL 52
#define STAGE_CLIP_SET_OK 53
#define STAGE_CLIP_SET_FAIL 54
#define STAGE_PASTE_SENDINPUT_BEGIN 55
#define STAGE_PASTE_SENDINPUT_OK 56
#define STAGE_PASTE_SENDINPUT_FAIL 57
#define STAGE_CLIP_RESTORE_OK 58
#define STAGE_CLIP_RESTORE_FAIL 59
#define STAGE_TARGET_PARENT 60
#define STAGE_WM_PASTE_BEGIN 61
#define STAGE_WM_PASTE_OK 62
#define STAGE_WM_PASTE_FAIL 63
#define STAGE_CLIP_RESTORE_DELAY 64

static SOCKET g_socket = INVALID_SOCKET;
static struct sockaddr_in g_host_addr;
static struct sockaddr_in g_bridge_addr;
static int g_wow_ime_focus = 0;

static void send_ready(void) {
  uint8_t b = PKT_LITE_READY;
  sendto(g_socket, (const char *)&b, 1, 0, (const struct sockaddr *)&g_host_addr, sizeof(g_host_addr));
}

static void send_log(int32_t req_id, uint8_t stage, int32_t winerr, int32_t aux) {
  // Fixed wire format, no struct packing/padding:
  // [1B code][4B req_id LE][1B stage][4B winerr LE][4B aux LE]
  uint8_t payload[14];
  payload[0] = PKT_LITE_LOG;
  payload[1] = (uint8_t)(req_id & 0xFF);
  payload[2] = (uint8_t)((req_id >> 8) & 0xFF);
  payload[3] = (uint8_t)((req_id >> 16) & 0xFF);
  payload[4] = (uint8_t)((req_id >> 24) & 0xFF);
  payload[5] = stage;
  payload[6] = (uint8_t)(winerr & 0xFF);
  payload[7] = (uint8_t)((winerr >> 8) & 0xFF);
  payload[8] = (uint8_t)((winerr >> 16) & 0xFF);
  payload[9] = (uint8_t)((winerr >> 24) & 0xFF);
  payload[10] = (uint8_t)(aux & 0xFF);
  payload[11] = (uint8_t)((aux >> 8) & 0xFF);
  payload[12] = (uint8_t)((aux >> 16) & 0xFF);
  payload[13] = (uint8_t)((aux >> 24) & 0xFF);
  sendto(g_socket, (const char *)payload, sizeof(payload), 0,
         (const struct sockaddr *)&g_host_addr, sizeof(g_host_addr));
}

static void send_focus_to_host(int focus, const char *box_name) {
  uint16_t n = (uint16_t)strnlen(box_name ? box_name : "", 255);
  uint8_t payload[1 + 1 + 2 + 255];
  payload[0] = PKT_LITE_FOCUS;
  payload[1] = (uint8_t)(focus ? 1 : 0);
  payload[2] = (uint8_t)(n & 0xff);
  payload[3] = (uint8_t)((n >> 8) & 0xff);
  if (n > 0) memcpy(payload + 4, box_name, n);
  sendto(g_socket, (const char *)payload, 4 + n, 0,
         (const struct sockaddr *)&g_host_addr, sizeof(g_host_addr));
}

static int json_get_int(const char *s, const char *key, int *out) {
  char needle[64];
  const char *p;
  char *endptr = NULL;
  long v;
  if (!s || !key || !out) return 0;
  _snprintf(needle, sizeof(needle), "\"%s\"", key);
  p = strstr(s, needle);
  if (!p) return 0;
  p = strchr(p, ':');
  if (!p) return 0;
  ++p;
  while (*p == ' ' || *p == '\t') ++p;
  v = strtol(p, &endptr, 10);
  if (p == endptr) return 0;
  *out = (int)v;
  return 1;
}

static int json_get_string(const char *s, const char *key, char *out, size_t out_cap) {
  char needle[64];
  const char *p;
  const char *q;
  size_t w = 0;
  if (!s || !key || !out || out_cap < 2) return 0;
  _snprintf(needle, sizeof(needle), "\"%s\"", key);
  p = strstr(s, needle);
  if (!p) return 0;
  p = strchr(p, ':');
  if (!p) return 0;
  p = strchr(p, '"');
  if (!p) return 0;
  ++p;
  q = p;
  while (*q && !(*q == '"' && q[-1] != '\\')) ++q;
  if (!*q) return 0;
  while (p < q && w + 1 < out_cap) {
    char c = *p++;
    if (c == '\\' && p < q) {
      char e = *p++;
      switch (e) {
        case '\\': c = '\\'; break;
        case '"': c = '"'; break;
        case 'n': c = '\n'; break;
        case 'r': c = '\r'; break;
        case 't': c = '\t'; break;
        default: c = e; break;
      }
    }
    out[w++] = c;
  }
  out[w] = '\0';
  return 1;
}

static int utf16le_to_utf8(const WCHAR *wtext, int wlen, char *out, int out_cap) {
  if (!wtext || wlen <= 0 || !out || out_cap <= 1) return 0;
  int n = WideCharToMultiByte(CP_UTF8, 0, wtext, wlen, out, out_cap - 1, NULL, NULL);
  if (n <= 0) return 0;
  out[n] = '\0';
  return n;
}

static int b64_encode(const uint8_t *src, int src_len, char *dst, int dst_cap) {
  static const char table[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  int si = 0, di = 0;
  if (!src || src_len < 0 || !dst || dst_cap <= 0) return 0;
  while (si < src_len) {
    int b0 = src[si++];
    int b1 = (si < src_len) ? src[si++] : -1;
    int b2 = (si < src_len) ? src[si++] : -1;
    if (di + 4 >= dst_cap) return 0;
    dst[di++] = table[(b0 >> 2) & 0x3f];
    dst[di++] = table[((b0 & 0x3) << 4) | ((b1 >= 0 ? b1 : 0) >> 4)];
    dst[di++] = (b1 >= 0) ? table[((b1 & 0xf) << 2) | ((b2 >= 0 ? b2 : 0) >> 6)] : '=';
    dst[di++] = (b2 >= 0) ? table[b2 & 0x3f] : '=';
  }
  if (di >= dst_cap) return 0;
  dst[di] = '\0';
  return di;
}

static void send_log_text_utf8(int32_t req_id, uint8_t stage, const char *text) {
  if (!text) return;
  uint16_t n = (uint16_t)strnlen(text, 1023);
  uint8_t payload[1 + 4 + 1 + 2 + 1023];
  payload[0] = PKT_LITE_LOG_TEXT;
  payload[1] = (uint8_t)(req_id & 0xFF);
  payload[2] = (uint8_t)((req_id >> 8) & 0xFF);
  payload[3] = (uint8_t)((req_id >> 16) & 0xFF);
  payload[4] = (uint8_t)((req_id >> 24) & 0xFF);
  payload[5] = stage;
  payload[6] = (uint8_t)(n & 0xFF);
  payload[7] = (uint8_t)((n >> 8) & 0xFF);
  memcpy(payload + 8, text, n);
  sendto(g_socket, (const char *)payload, 8 + n, 0,
         (const struct sockaddr *)&g_host_addr, sizeof(g_host_addr));
}

static void send_log_hwnd_desc(int32_t req_id, uint8_t stage, HWND hwnd) {
  char class_name[128] = {0};
  WCHAR title_w[256] = {0};
  char title_u8[512] = {0};
  HWND parent = GetParent(hwnd);

  if (hwnd) {
    GetClassNameA(hwnd, class_name, (int)sizeof(class_name));
    GetWindowTextW(hwnd, title_w, (int)(sizeof(title_w) / sizeof(title_w[0])));
    WideCharToMultiByte(CP_UTF8, 0, title_w, -1, title_u8, (int)sizeof(title_u8), NULL, NULL);
  }

  char line[1024];
  _snprintf(line, sizeof(line),
            "hwnd=0x%08lx parent=0x%08lx class=\"%s\" title=\"%s\"",
            (unsigned long)(uintptr_t)hwnd,
            (unsigned long)(uintptr_t)parent,
            class_name,
            title_u8);
  line[sizeof(line) - 1] = '\0';
  send_log_text_utf8(req_id, stage, line);
}

static WCHAR *capture_clipboard_unicode_copy(int *out_wchars) {
  *out_wchars = 0;
  HANDLE h = GetClipboardData(CF_UNICODETEXT);
  if (!h) return NULL;

  const WCHAR *src = (const WCHAR *)GlobalLock(h);
  if (!src) return NULL;

  size_t n = wcslen(src);
  WCHAR *copy = (WCHAR *)malloc((n + 1) * sizeof(WCHAR));
  if (copy) {
    memcpy(copy, src, (n + 1) * sizeof(WCHAR));
    *out_wchars = (int)n;
  }
  GlobalUnlock(h);
  return copy;
}

static int set_clipboard_unicode(const WCHAR *text, int wchar_count) {
  if (!text || wchar_count < 0) return 0;
  SIZE_T bytes = (SIZE_T)(wchar_count + 1) * sizeof(WCHAR);
  HGLOBAL hmem = GlobalAlloc(GMEM_MOVEABLE, bytes);
  if (!hmem) return 0;

  WCHAR *dst = (WCHAR *)GlobalLock(hmem);
  if (!dst) {
    GlobalFree(hmem);
    return 0;
  }

  memcpy(dst, text, (SIZE_T)wchar_count * sizeof(WCHAR));
  dst[wchar_count] = L'\0';
  GlobalUnlock(hmem);

  if (!SetClipboardData(CF_UNICODETEXT, hmem)) {
    GlobalFree(hmem);
    return 0;
  }
  return 1;
}

static int send_ctrl_v_input(void) {
  INPUT in[4];
  ZeroMemory(in, sizeof(in));

  in[0].type = INPUT_KEYBOARD;
  in[0].ki.wVk = VK_CONTROL;

  in[1].type = INPUT_KEYBOARD;
  in[1].ki.wVk = 'V';

  in[2].type = INPUT_KEYBOARD;
  in[2].ki.wVk = 'V';
  in[2].ki.dwFlags = KEYEVENTF_KEYUP;

  in[3].type = INPUT_KEYBOARD;
  in[3].ki.wVk = VK_CONTROL;
  in[3].ki.dwFlags = KEYEVENTF_KEYUP;

  UINT sent = SendInput(4, in, sizeof(INPUT));
  return sent == 4 ? 1 : 0;
}

static int send_wm_paste(HWND hwnd, int32_t *out_err) {
  SetLastError(0);
  SendMessageW(hwnd, WM_PASTE, 0, 0);
  DWORD err = GetLastError();
  if (out_err) *out_err = (int32_t)err;
  return err == 0 ? 1 : 0;
}

static HWND resolve_target_window(int32_t req_id) {
  HWND hwnd_fg = GetForegroundWindow();
  HWND hwnd_focus = NULL;
  HWND target = hwnd_fg;

  send_log(req_id, STAGE_CTX_FG_HWND, 0, (int32_t)(uintptr_t)hwnd_fg);

  DWORD self_tid = GetCurrentThreadId();
  DWORD fg_tid = 0;
  if (hwnd_fg) {
    fg_tid = GetWindowThreadProcessId(hwnd_fg, NULL);
  }

  BOOL attached = FALSE;
  if (fg_tid && fg_tid != self_tid) {
    attached = AttachThreadInput(self_tid, fg_tid, TRUE);
    send_log(req_id, attached ? STAGE_CTX_ATTACH_FOCUS_OK : STAGE_CTX_ATTACH_FOCUS_ERR,
             attached ? 0 : (int32_t)GetLastError(), attached ? 1 : 0);
  }

  hwnd_focus = GetFocus();
  if (!hwnd_focus && fg_tid) {
    GUITHREADINFO gti;
    ZeroMemory(&gti, sizeof(gti));
    gti.cbSize = sizeof(gti);
    if (GetGUIThreadInfo(fg_tid, &gti)) {
      hwnd_focus = gti.hwndFocus;
    }
  }

  if (attached) {
    AttachThreadInput(self_tid, fg_tid, FALSE);
  }

  send_log(req_id, STAGE_CTX_FOCUS_HWND, 0, (int32_t)(uintptr_t)hwnd_focus);

  if (hwnd_focus) {
    target = hwnd_focus;
  }

  return target;
}

static int try_activate_target(HWND target, int32_t req_id) {
  if (!target) return 0;
  HWND root = GetAncestor(target, GA_ROOT);
  if (!root) root = target;

  DWORD self_tid = GetCurrentThreadId();
  DWORD target_tid = GetWindowThreadProcessId(target, NULL);

  BOOL attached = FALSE;
  if (target_tid && target_tid != self_tid) {
    attached = AttachThreadInput(self_tid, target_tid, TRUE);
    send_log(req_id, attached ? STAGE_CTX_ATTACH_FOCUS_OK : STAGE_CTX_ATTACH_FOCUS_ERR,
             attached ? 0 : (int32_t)GetLastError(), attached ? 2 : 0);
  }

  if (IsIconic(root)) {
    ShowWindow(root, SW_RESTORE);
  }
  SetForegroundWindow(root);
  SetFocus(target);
  SetActiveWindow(root);
  SetWindowPos(root, HWND_TOP, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE);

  if (attached) {
    AttachThreadInput(self_tid, target_tid, FALSE);
  }
  return 1;
}

static int send_bridge_commit(int32_t req_id, const WCHAR *wide, int wchar_count, int submit) {
  char utf8[4096];
  char b64[6144];
  char json[6400];
  int utf8_len;
  int b64_len;
  int n;

  utf8_len = utf16le_to_utf8(wide, wchar_count, utf8, (int)sizeof(utf8));
  if (utf8_len <= 0) {
    send_log(req_id, STAGE_MSG_INJECT_FAILED, (int32_t)GetLastError(), -11);
    return 0;
  }
  b64_len = b64_encode((const uint8_t *)utf8, utf8_len, b64, (int)sizeof(b64));
  if (b64_len <= 0) {
    send_log(req_id, STAGE_MSG_INJECT_FAILED, ERROR_INSUFFICIENT_BUFFER, -12);
    return 0;
  }

  n = _snprintf(
      json, sizeof(json) - 1,
      "{\"type\":\"ime_commit\",\"seq\":%d,\"submit\":%d,\"text_b64\":\"%s\"}",
      req_id,
      submit ? 1 : 0,
      b64);
  if (n <= 0) {
    send_log(req_id, STAGE_MSG_INJECT_FAILED, ERROR_INVALID_DATA, -13);
    return 0;
  }
  if (n > (int)sizeof(json) - 1) n = (int)sizeof(json) - 1;
  json[n] = '\0';

  sendto(g_socket, json, n, 0, (const struct sockaddr *)&g_bridge_addr, sizeof(g_bridge_addr));
  return 1;
}

static void handle_bridge_json_packet(const char *packet, int packet_len) {
  int focus = 0;
  char box[256];
  (void)packet_len;
  box[0] = '\0';

  if (!packet || packet[0] != '{') return;
  if (!strstr(packet, "\"type\":\"ime_focus\"")) return;

  if (!json_get_int(packet, "focus", &focus)) {
    focus = 0;
  }
  (void)json_get_string(packet, "box", box, sizeof(box));
  g_wow_ime_focus = focus ? 1 : 0;
  send_focus_to_host(g_wow_ime_focus, box);
}

static void handle_text_request(const char *packet, int packet_len) {
  if (packet_len < 9) {
    send_log(0, STAGE_INVALID_PACKET, ERROR_INVALID_DATA, packet_len);
    return;
  }

  const uint8_t req_type = (uint8_t)packet[0];
  const int32_t req_id = *(const int32_t *)(packet + 1);
  const int32_t text_bytes = *(const int32_t *)(packet + 5);

  if (req_type != PKT_REQ_TEXT || text_bytes <= 0 || text_bytes > 4096 || packet_len < 9 + text_bytes) {
    send_log(req_id, STAGE_INVALID_PACKET, ERROR_INVALID_DATA, text_bytes);
    return;
  }

  send_log(req_id, STAGE_RECV_TEXT, 0, text_bytes);

  WCHAR wide[2049];
  int wchar_count = text_bytes / 2;
  if (wchar_count > 2048) {
    wchar_count = 2048;
  }
  memcpy(wide, packet + 9, wchar_count * sizeof(WCHAR));
  wide[wchar_count] = L'\0';

  if (g_wow_ime_focus) {
    send_log(req_id, STAGE_MSG_INJECT_BEGIN, 0, 901);
    if (send_bridge_commit(req_id, wide, wchar_count, 1)) {
      send_log(req_id, STAGE_MSG_INJECT_END, 0, 901);
      send_log(req_id, STAGE_MSG_INJECT_MODE, 901, wchar_count);
      send_log(req_id, STAGE_DONE, 0, 0);
    } else {
      send_log(req_id, STAGE_MSG_INJECT_FAILED, (int32_t)GetLastError(), 901);
      send_log(req_id, STAGE_DONE, 0, 0);
    }
    return;
  }

  HWND hwnd = resolve_target_window(req_id);

  if (!hwnd) {
    send_log(req_id, STAGE_MSG_INJECT_FAILED, (int32_t)GetLastError(), 0);
    send_log(req_id, STAGE_DONE, 0, 0);
    return;
  }

  send_log(req_id, STAGE_TARGET_RESOLVE, 0, (int32_t)(uintptr_t)hwnd);
  send_log_hwnd_desc(req_id, STAGE_TARGET_RESOLVE, hwnd);
  send_log(req_id, STAGE_TARGET_PARENT, 0, (int32_t)(uintptr_t)GetParent(hwnd));
  try_activate_target(hwnd, req_id);

  send_log(req_id, STAGE_CLIP_OPEN_BEGIN, 0, 0);
  if (!OpenClipboard(NULL)) {
    send_log(req_id, STAGE_CLIP_OPEN_FAIL, (int32_t)GetLastError(), 0);
    send_log(req_id, STAGE_DONE, 0, 0);
    return;
  }
  send_log(req_id, STAGE_CLIP_OPEN_OK, 0, 0);

  int old_wchars = 0;
  WCHAR *old_text = capture_clipboard_unicode_copy(&old_wchars);

  if (!EmptyClipboard() || !set_clipboard_unicode(wide, wchar_count)) {
    int err = (int32_t)GetLastError();
    send_log(req_id, STAGE_CLIP_SET_FAIL, err, 0);
    CloseClipboard();
    free(old_text);
    send_log(req_id, STAGE_DONE, 0, 0);
    return;
  }
  send_log(req_id, STAGE_CLIP_SET_OK, 0, wchar_count);
  CloseClipboard();

  send_log(req_id, STAGE_WM_PASTE_BEGIN, 0, 0);
  int32_t paste_err = 0;
  if (send_wm_paste(hwnd, &paste_err)) {
    send_log(req_id, STAGE_WM_PASTE_OK, 0, 1);
  } else {
    send_log(req_id, STAGE_WM_PASTE_FAIL, paste_err, 0);
    send_log(req_id, STAGE_PASTE_SENDINPUT_BEGIN, 0, 0);
    if (!send_ctrl_v_input()) {
      send_log(req_id, STAGE_PASTE_SENDINPUT_FAIL, (int32_t)GetLastError(), 0);
    } else {
      send_log(req_id, STAGE_PASTE_SENDINPUT_OK, 0, 4);
    }
  }

  send_log(req_id, STAGE_CLIP_RESTORE_DELAY, 0, 220);
  Sleep(220);

  if (OpenClipboard(NULL)) {
    int restored = 0;
    if (old_text) {
      EmptyClipboard();
      restored = set_clipboard_unicode(old_text, old_wchars);
    } else {
      EmptyClipboard();
      restored = 1;
    }
    send_log(req_id, restored ? STAGE_CLIP_RESTORE_OK : STAGE_CLIP_RESTORE_FAIL,
             restored ? 0 : (int32_t)GetLastError(), old_wchars);
    CloseClipboard();
  } else {
    send_log(req_id, STAGE_CLIP_RESTORE_FAIL, (int32_t)GetLastError(), -1);
  }
  free(old_text);

  send_log(req_id, STAGE_MSG_INJECT_MODE, 600, wchar_count);

  send_log(req_id, STAGE_DONE, 0, 0);
}

int WINAPI WinMain(HINSTANCE hInstance, HINSTANCE hPrevInstance, LPSTR lpCmdLine, int nShowCmd) {
  (void)hInstance;
  (void)hPrevInstance;
  (void)lpCmdLine;
  (void)nShowCmd;

  WSADATA wsa;
  if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) {
    return 1;
  }

  g_socket = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
  if (g_socket == INVALID_SOCKET) {
    WSACleanup();
    return 2;
  }

  struct sockaddr_in local_addr;
  ZeroMemory(&local_addr, sizeof(local_addr));
  local_addr.sin_family = AF_INET;
  local_addr.sin_port = htons(LISTEN_PORT);
  local_addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

  if (bind(g_socket, (const struct sockaddr *)&local_addr, sizeof(local_addr)) != 0) {
    closesocket(g_socket);
    WSACleanup();
    return 3;
  }

  ZeroMemory(&g_host_addr, sizeof(g_host_addr));
  g_host_addr.sin_family = AF_INET;
  g_host_addr.sin_port = htons(HOST_PORT);
  g_host_addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

  ZeroMemory(&g_bridge_addr, sizeof(g_bridge_addr));
  g_bridge_addr.sin_family = AF_INET;
  g_bridge_addr.sin_port = htons(BRIDGE_PORT);
  g_bridge_addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

  send_ready();

  char recv_buf[8192];
  for (;;) {
    int len = recv(g_socket, recv_buf, sizeof(recv_buf), 0);
    if (len <= 0) {
      Sleep(2);
      continue;
    }
    if (recv_buf[0] == '{') {
      if (len >= (int)sizeof(recv_buf)) len = (int)sizeof(recv_buf) - 1;
      recv_buf[len] = '\0';
      handle_bridge_json_packet(recv_buf, len);
    } else {
      handle_text_request(recv_buf, len);
    }
  }

  closesocket(g_socket);
  WSACleanup();
  return 0;
}
