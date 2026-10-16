#include "PyrateAtomics.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#define PYR_FRESH 4

struct pyr_triple_buffer {
    _Atomic int state;   // middle index | PYR_FRESH
    int back;            // writer-owned
    int front;           // reader-owned
};

pyr_triple_buffer *pyr_tb_create(void) {
    pyr_triple_buffer *tb = calloc(1, sizeof(pyr_triple_buffer));
    tb->front = 0;
    atomic_init(&tb->state, 1);
    tb->back = 2;
    return tb;
}

void pyr_tb_destroy(pyr_triple_buffer *tb) { free(tb); }

int pyr_tb_back(const pyr_triple_buffer *tb) { return tb->back; }

int pyr_tb_publish(pyr_triple_buffer *tb) {
    int previous = atomic_exchange_explicit(&tb->state, tb->back | PYR_FRESH, memory_order_acq_rel);
    tb->back = previous & 3;
    return tb->back;
}

int pyr_tb_front(const pyr_triple_buffer *tb) { return tb->front; }

bool pyr_tb_has_fresh(pyr_triple_buffer *tb) {
    return (atomic_load_explicit(&tb->state, memory_order_acquire) & PYR_FRESH) != 0;
}

bool pyr_tb_acquire(pyr_triple_buffer *tb) {
    if (!pyr_tb_has_fresh(tb)) return false;
    int previous = atomic_exchange_explicit(&tb->state, tb->front, memory_order_acq_rel);
    tb->front = previous & 3;
    return true;
}

struct pyr_atomic_float {
    _Atomic unsigned int bits;
};

static unsigned int to_bits(float f) { unsigned int u; memcpy(&u, &f, sizeof u); return u; }
static float from_bits(unsigned int u) { float f; memcpy(&f, &u, sizeof f); return f; }

pyr_atomic_float *pyr_atomic_float_create(float value) {
    pyr_atomic_float *p = malloc(sizeof(pyr_atomic_float));
    atomic_init(&p->bits, to_bits(value));
    return p;
}

void pyr_atomic_float_destroy(pyr_atomic_float *p) { free(p); }

void pyr_store_float(pyr_atomic_float *p, float value) {
    atomic_store_explicit(&p->bits, to_bits(value), memory_order_release);
}

float pyr_load_float(pyr_atomic_float *p) {
    return from_bits(atomic_load_explicit(&p->bits, memory_order_acquire));
}

struct pyr_atomic_ptr {
    _Atomic(void *) value;
};

pyr_atomic_ptr *pyr_atomic_ptr_create(void *value) {
    pyr_atomic_ptr *p = malloc(sizeof(pyr_atomic_ptr));
    atomic_init(&p->value, value);
    return p;
}

void pyr_atomic_ptr_destroy(pyr_atomic_ptr *p) { free(p); }

void *pyr_atomic_ptr_load(pyr_atomic_ptr *p) {
    return atomic_load_explicit(&p->value, memory_order_acquire);
}

void *pyr_atomic_ptr_exchange(pyr_atomic_ptr *p, void *value) {
    return atomic_exchange_explicit(&p->value, value, memory_order_acq_rel);
}
