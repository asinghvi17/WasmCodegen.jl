#ifndef LORENZ_PROGRAM_H
#define LORENZ_PROGRAM_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Single host thread. Julia entrypoints initialize the runtime.
 * Out pointers must be aligned/writable; null pointers are checked.
 * Outputs remain unchanged on failure. Exceptions may mutate state.
 * Handle = generation << 32 | one-based slot; zero is invalid. */
enum { lorenz_OK=0, lorenz_INVALID=-1, lorenz_EXHAUSTED=-2, lorenz_NULL=-3, lorenz_EXCEPTION=-4 };
int32_t lorenz_create(uint64_t *out);
int32_t lorenz_destroy(uint64_t h);
int32_t lorenz_solve(uint64_t h, double a1, double a2, double a3, double a4, int32_t *out);
int32_t lorenz_point(uint64_t h, int32_t a1, int32_t a2, double *out);
#ifdef __cplusplus
}
#endif
#endif
