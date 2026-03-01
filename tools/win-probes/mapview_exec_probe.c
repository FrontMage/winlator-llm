#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static const uint8_t CODE_RET_42[] = {0xB8, 0x2A, 0x00, 0x00, 0x00, 0xC3};

static const char *mem_type_to_str(DWORD t) {
  switch (t) {
    case MEM_IMAGE: return "MEM_IMAGE";
    case MEM_MAPPED: return "MEM_MAPPED";
    case MEM_PRIVATE: return "MEM_PRIVATE";
    default: return "MEM_UNKNOWN";
  }
}

int main(void) {
  printf("[mapview] stage0: main entered\n");
  fflush(stdout);

  HANDLE mapping = CreateFileMappingA(
    INVALID_HANDLE_VALUE,
    NULL,
    PAGE_EXECUTE_READWRITE,
    0,
    0x1000,
    NULL);
  if (mapping == NULL) {
    printf("[mapview] stage1_fail: CreateFileMappingA failed: %lu\n", GetLastError());
    fflush(stdout);
    return 2;
  }

  void *view = MapViewOfFile(
    mapping,
    FILE_MAP_READ | FILE_MAP_WRITE | FILE_MAP_EXECUTE,
    0,
    0,
    0x1000);
  if (view == NULL) {
    printf("[mapview] stage1_fail: MapViewOfFile failed: %lu\n", GetLastError());
    fflush(stdout);
    CloseHandle(mapping);
    return 3;
  }

  MEMORY_BASIC_INFORMATION mbi = {0};
  SIZE_T q = VirtualQuery(view, &mbi, sizeof(mbi));
  if (q == sizeof(mbi)) {
    printf(
      "[mapview] stage1: base=%p type=%s(0x%lx) protect=0x%lx state=0x%lx allocProtect=0x%lx size=0x%Ix\n",
      view,
      mem_type_to_str(mbi.Type),
      (unsigned long)mbi.Type,
      (unsigned long)mbi.Protect,
      (unsigned long)mbi.State,
      (unsigned long)mbi.AllocationProtect,
      (size_t)mbi.RegionSize);
  } else {
    printf("[mapview] stage1_fail: VirtualQuery failed: %lu\n", GetLastError());
  }
  fflush(stdout);

  memcpy(view, CODE_RET_42, sizeof(CODE_RET_42));
  FlushInstructionCache(GetCurrentProcess(), view, sizeof(CODE_RET_42));

  printf("[mapview] stage2: invoking code at %p\n", view);
  fflush(stdout);
  int (__cdecl *fn)(void) = (int (__cdecl *)(void))view;
  int result = fn();
  printf("[mapview] stage2: returned: %d\n", result);
  fflush(stdout);

  UnmapViewOfFile(view);
  CloseHandle(mapping);
  printf("[mapview] stage3: done\n");
  fflush(stdout);
  return 0;
}
