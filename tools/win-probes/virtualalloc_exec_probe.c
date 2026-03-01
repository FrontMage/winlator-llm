#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static const uint8_t CODE_RET_43[] = {0xB8, 0x2B, 0x00, 0x00, 0x00, 0xC3};

static const char *mem_type_to_str(DWORD t) {
  switch (t) {
    case MEM_IMAGE: return "MEM_IMAGE";
    case MEM_MAPPED: return "MEM_MAPPED";
    case MEM_PRIVATE: return "MEM_PRIVATE";
    default: return "MEM_UNKNOWN";
  }
}

int main(void) {
  printf("[valloc] stage0: main entered\n");
  fflush(stdout);

  void *buf = VirtualAlloc(NULL, 0x1000, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
  if (buf == NULL) {
    printf("[valloc] stage1_fail: VirtualAlloc failed: %lu\n", GetLastError());
    fflush(stdout);
    return 2;
  }

  memcpy(buf, CODE_RET_43, sizeof(CODE_RET_43));

  DWORD old_protect = 0;
  if (!VirtualProtect(buf, 0x1000, PAGE_EXECUTE_READ, &old_protect)) {
    printf("[valloc] stage1_fail: VirtualProtect failed: %lu\n", GetLastError());
    fflush(stdout);
    VirtualFree(buf, 0, MEM_RELEASE);
    return 3;
  }

  MEMORY_BASIC_INFORMATION mbi = {0};
  SIZE_T q = VirtualQuery(buf, &mbi, sizeof(mbi));
  if (q == sizeof(mbi)) {
    printf(
      "[valloc] stage1: base=%p type=%s(0x%lx) protect=0x%lx state=0x%lx allocProtect=0x%lx size=0x%Ix oldProtect=0x%lx\n",
      buf,
      mem_type_to_str(mbi.Type),
      (unsigned long)mbi.Type,
      (unsigned long)mbi.Protect,
      (unsigned long)mbi.State,
      (unsigned long)mbi.AllocationProtect,
      (size_t)mbi.RegionSize,
      (unsigned long)old_protect);
  } else {
    printf("[valloc] stage1_fail: VirtualQuery failed: %lu\n", GetLastError());
  }
  fflush(stdout);

  FlushInstructionCache(GetCurrentProcess(), buf, sizeof(CODE_RET_43));
  printf("[valloc] stage2: invoking code at %p\n", buf);
  fflush(stdout);
  int (__cdecl *fn)(void) = (int (__cdecl *)(void))buf;
  int result = fn();
  printf("[valloc] stage2: returned: %d\n", result);
  fflush(stdout);

  VirtualFree(buf, 0, MEM_RELEASE);
  printf("[valloc] stage3: done\n");
  fflush(stdout);
  return 0;
}
