#include <windows.h>
#include <stdio.h>

int main(void) {
  printf("[entry] stage0: main entered\n");
  fflush(stdout);

  SYSTEM_INFO si = {0};
  GetSystemInfo(&si);
  printf("[entry] stage1: arch=%u page_size=%lu\n",
         (unsigned)si.wProcessorArchitecture,
         (unsigned long)si.dwPageSize);
  fflush(stdout);

  printf("[entry] stage2: done\n");
  fflush(stdout);
  return 0;
}
