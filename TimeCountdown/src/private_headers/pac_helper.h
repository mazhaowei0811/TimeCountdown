#ifndef TD_PTRAUTH_HELPERS_H
#define TD_PTRAUTH_HELPERS_H

// arm64e 上指针带 PAC，读指令 / 当函数指针调用之前都要先处理，
// 否则要么读到错的字节，要么调用时崩。

#if __arm64e__
#include <ptrauth.h>
#endif

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunused-function"

static void *make_sym_callable(void *ptr) {
#if __arm64e__
    if (!ptr) return ptr;
    ptr = ptrauth_sign_unauthenticated(ptrauth_strip(ptr, ptrauth_key_function_pointer),
                                       ptrauth_key_function_pointer, 0);
#endif
    return ptr;
}

static void *make_sym_readable(void *ptr) {
#if __arm64e__
    if (!ptr) return ptr;
    ptr = ptrauth_strip(ptr, ptrauth_key_function_pointer);
#endif
    return ptr;
}

#pragma clang diagnostic pop
#endif  // TD_PTRAUTH_HELPERS_H
