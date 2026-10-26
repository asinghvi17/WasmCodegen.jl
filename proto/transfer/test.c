#include "program.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>

static void value_is(uint64_t h, double want) {
    double got = -999;
    assert(transfer_value(h, &got) == 0);
    assert(fabs(got - want) < 1e-12);
}

int main(void) {
    uint64_t h[4], out = UINT64_C(0xfeed);
    double v = 123.5;
    int32_t checked = 77;
    assert(transfer_create(NULL) == -3);
    for (int i=0; i<4; ++i) {
        assert(transfer_create(&h[i]) == 0);
        assert(h[i] != 0);
        value_is(h[i], 0);
    }
    assert(transfer_create(&out) == -2 && out == UINT64_C(0xfeed));
    assert(transfer_step(h[0], 2.0, &v) == 0 && v == 2.0);
    assert(transfer_step(h[0], 2.0, &v) == 0 && v == 3.0);
    value_is(h[1], 0);
    assert(transfer_value(h[0], NULL) == -3);
    assert(transfer_step(h[0], 100.0, NULL) == -3);
    value_is(h[0], 3);
    v = 123.5;
    assert(transfer_value(0, &v) == -1 && v == 123.5);
    assert(transfer_value(UINT64_C(0x100000005), &v) == -1 && v == 123.5);
    assert(transfer_value(h[0] + (UINT64_C(1)<<32), &v) == -1 && v == 123.5);
    assert(transfer_checked(h[0], -1, &checked) == -4 && checked == 77);
    assert(transfer_checked(h[0], 9, &checked) == 0 && checked == 9);
    assert(transfer_clear(h[0], &checked) == 0 && checked == 0);
    value_is(h[0], 0);
    uint64_t stale = h[0];
    assert(transfer_destroy(stale) == 0);
    assert(transfer_destroy(stale) == -1);
    assert(transfer_value(stale, &v) == -1 && v == 123.5);
    assert(transfer_create(&h[0]) == 0 && h[0] != stale);
    value_is(h[0], 0);
    for (int i=0; i<1000; ++i) {
        assert(transfer_destroy(h[0]) == 0);
        assert(transfer_create(&h[0]) == 0);
    }
    for (int i=0; i<4; ++i) assert(transfer_destroy(h[i]) == 0);
    puts("PASS native ABI: pool, independence, statuses, null, exception, reset, reuse");
    return 0;
}
