#include "program.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
int main(void) {
    uint64_t a=0,b=0,c=0,d=0,stale=0; int32_t n=0; double v=123.0;
    assert(lorenz_create(NULL)==-3);
    assert(lorenz_create(&a)==0 && lorenz_create(&b)==0 && a!=b);
    assert(lorenz_point(0,1,1,&v)==-1 && v==123.0);
    assert(lorenz_point(a,1,1,NULL)==-3);
    assert(lorenz_point(a,0,1,&v)==-4 && v==123.0);
    const double params[2][4]={{10,28,8.0/3.0,1},{12,30,2.5,1.25}};
    const uint64_t handles[2]={a,b};
    puts("[");
    double saved=0;
    for(int j=0;j<2;j++) {
        assert(lorenz_solve(handles[j],params[j][0],params[j][1],params[j][2],params[j][3],&n)==0);
        assert(n==401); printf("%s[",j?",":"");
        for(int i=1;i<=n;i++) {
            printf("%s[",i>1?",":"");
            for(int k=1;k<=3;k++) {
                assert(lorenz_point(handles[j],i,k,&v)==0);
                assert(isfinite(v)); printf("%s%.17g",k>1?",":"",v);
                if(j==0 && i==101 && k==1) saved=v;
            }
            printf("]");
        }
        printf("]");
    }
    puts("]");
    assert(lorenz_point(a,101,1,&v)==0 && v==saved);
    stale=a; assert(lorenz_destroy(a)==0 && lorenz_destroy(a)==-1);
    assert(lorenz_create(&a)==0 && a!=stale && (uint32_t)a==(uint32_t)stale);
    assert(lorenz_point(stale,1,1,&v)==-1);
    assert(lorenz_point(a,1,1,&v)==0 && v==1);
    assert(lorenz_create(&c)==0 && lorenz_create(&d)==0);
    uint64_t untouched=123; assert(lorenz_create(&untouched)==-2 && untouched==123);
    assert(lorenz_point(UINT64_C(0x100000005),1,1,&v)==-1);
    assert(lorenz_point(UINT64_C(1),1,1,&v)==-1);
    assert(lorenz_destroy(a)==0 && lorenz_destroy(b)==0 && lorenz_destroy(c)==0 && lorenz_destroy(d)==0);
    for(int i=0;i<1000;i++) assert(lorenz_create(&a)==0 && lorenz_destroy(a)==0);
    fflush(stdout);
    fputs("C lifecycle, null/exception, isolation, 1000 reuse cycles passed\n",stderr);
    return 0;
}
