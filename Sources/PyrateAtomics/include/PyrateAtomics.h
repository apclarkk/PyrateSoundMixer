#ifndef PYRATE_ATOMICS_H
#define PYRATE_ATOMICS_H

#include <stdbool.h>

/// Lock-free triple buffer index exchange, used to hand parameter sets from the
/// main thread to the realtime audio thread without locks or allocation.
///
/// Three slots exist. The writer owns `back`, the reader owns `front`, and shared
/// atomic state holds the middle slot plus a "fresh" flag. Neither side ever
/// touches a slot the other side owns. All functions are wait-free.
typedef struct pyr_triple_buffer pyr_triple_buffer;

pyr_triple_buffer *pyr_tb_create(void);
void pyr_tb_destroy(pyr_triple_buffer *tb);
/// Writer: the slot to fill next.
int pyr_tb_back(const pyr_triple_buffer *tb);
/// Writer: publish the filled back slot. Returns the new back slot.
int pyr_tb_publish(pyr_triple_buffer *tb);
/// Reader: the slot currently in use.
int pyr_tb_front(const pyr_triple_buffer *tb);
/// Reader: true when a fresh slot is waiting (does not take it).
bool pyr_tb_has_fresh(pyr_triple_buffer *tb);
/// Reader: if a fresh slot was published, take it. Returns true when front changed.
bool pyr_tb_acquire(pyr_triple_buffer *tb);

/// A float readable and writable from any thread (release/acquire ordering).
typedef struct pyr_atomic_float pyr_atomic_float;

pyr_atomic_float *pyr_atomic_float_create(float value);
void pyr_atomic_float_destroy(pyr_atomic_float *p);
void pyr_store_float(pyr_atomic_float *p, float value);
float pyr_load_float(pyr_atomic_float *p);

/// A pointer readable and swappable from any thread (release/acquire ordering).
typedef struct pyr_atomic_ptr pyr_atomic_ptr;

pyr_atomic_ptr *pyr_atomic_ptr_create(void *value);
void pyr_atomic_ptr_destroy(pyr_atomic_ptr *p);
void *pyr_atomic_ptr_load(pyr_atomic_ptr *p);
/// Stores a new value and returns the previous one.
void *pyr_atomic_ptr_exchange(pyr_atomic_ptr *p, void *value);

#endif
