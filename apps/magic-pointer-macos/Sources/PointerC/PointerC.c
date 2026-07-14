#include "PointerC.h"

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define MP_DISCRETE_RING_CAPACITY 128u
#define MP_CALLBACK_BUCKET_COUNT 8u

_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2, "Magic Pointer requires lock-free 64-bit atomics");
_Static_assert(ATOMIC_INT_LOCK_FREE == 2, "Magic Pointer requires lock-free 32-bit atomics");

struct mp_motion_mailbox {
    _Atomic uint64_t version;
    _Atomic uint64_t sequence;
    _Atomic uint64_t event_time_ns;
    _Atomic uint64_t observed_time_ns;
    _Atomic uint64_t quartz_x_bits;
    _Atomic uint64_t quartz_y_bits;
    _Atomic uint64_t appkit_x_bits;
    _Atomic uint64_t appkit_y_bits;
    _Atomic uint64_t flags;
    _Atomic uint32_t buttons;
    _Atomic uint8_t event_kind;
};

struct mp_discrete_ring {
    _Atomic uint32_t head;
    _Atomic uint32_t tail;
    _Atomic uint64_t overflow_epoch;
    mp_discrete_event_t records[MP_DISCRETE_RING_CAPACITY];
};

struct mp_event_metrics {
    _Atomic uint64_t version;
    _Atomic uint64_t callback_count;
    _Atomic uint64_t callback_total_ns;
    _Atomic uint64_t callback_max_ns;
    _Atomic uint64_t callback_buckets[MP_CALLBACK_BUCKET_COUNT];
    _Atomic uint64_t tap_disabled_timeout_count;
    _Atomic uint64_t tap_disabled_user_count;
    _Atomic uint64_t discrete_overflow_count;
};

static uint64_t mp_double_to_bits(double value) {
    uint64_t bits = 0;
    memcpy(&bits, &value, sizeof(bits));
    return bits;
}

static double mp_bits_to_double(uint64_t bits) {
    double value = 0;
    memcpy(&value, &bits, sizeof(value));
    return value;
}

mp_motion_mailbox_t *mp_motion_mailbox_create(void) {
    mp_motion_mailbox_t *mailbox = calloc(1, sizeof(mp_motion_mailbox_t));
    if (mailbox == NULL) {
        return NULL;
    }
    atomic_init(&mailbox->version, 0);
    atomic_init(&mailbox->sequence, 0);
    atomic_init(&mailbox->event_time_ns, 0);
    atomic_init(&mailbox->observed_time_ns, 0);
    atomic_init(&mailbox->quartz_x_bits, 0);
    atomic_init(&mailbox->quartz_y_bits, 0);
    atomic_init(&mailbox->appkit_x_bits, 0);
    atomic_init(&mailbox->appkit_y_bits, 0);
    atomic_init(&mailbox->flags, 0);
    atomic_init(&mailbox->buttons, 0);
    atomic_init(&mailbox->event_kind, 0);
    return mailbox;
}

void mp_motion_mailbox_destroy(mp_motion_mailbox_t *mailbox) {
    free(mailbox);
}

void mp_motion_mailbox_reset(mp_motion_mailbox_t *mailbox) {
    if (mailbox == NULL) {
        return;
    }
    mp_motion_sample_t empty = {0};
    mp_motion_mailbox_write(mailbox, &empty);
}

void mp_motion_mailbox_write(mp_motion_mailbox_t *mailbox, const mp_motion_sample_t *sample) {
    if (mailbox == NULL || sample == NULL) {
        return;
    }

    const uint64_t writing_version =
        atomic_fetch_add_explicit(&mailbox->version, 1, memory_order_seq_cst) + 1;

    atomic_store_explicit(&mailbox->sequence, sample->sequence, memory_order_relaxed);
    atomic_store_explicit(&mailbox->event_time_ns, sample->event_time_ns, memory_order_relaxed);
    atomic_store_explicit(&mailbox->observed_time_ns, sample->observed_time_ns, memory_order_relaxed);
    atomic_store_explicit(&mailbox->quartz_x_bits, mp_double_to_bits(sample->quartz_x), memory_order_relaxed);
    atomic_store_explicit(&mailbox->quartz_y_bits, mp_double_to_bits(sample->quartz_y), memory_order_relaxed);
    atomic_store_explicit(&mailbox->appkit_x_bits, mp_double_to_bits(sample->appkit_x), memory_order_relaxed);
    atomic_store_explicit(&mailbox->appkit_y_bits, mp_double_to_bits(sample->appkit_y), memory_order_relaxed);
    atomic_store_explicit(&mailbox->flags, sample->flags, memory_order_relaxed);
    atomic_store_explicit(&mailbox->buttons, sample->buttons, memory_order_relaxed);
    atomic_store_explicit(&mailbox->event_kind, sample->event_kind, memory_order_relaxed);

    // The full ordering on both version transitions is intentional. A reader must never
    // accept payload fields that became visible before the odd version marker or after its
    // final validation load. This mailbox is written at hardware-event rate, where the
    // extra fence cost is negligible compared with accepting one torn cursor sample.
    atomic_store_explicit(&mailbox->version, writing_version + 1, memory_order_seq_cst);
}

bool mp_motion_mailbox_read(
    const mp_motion_mailbox_t *mailbox,
    uint64_t after_version,
    uint64_t *out_version,
    mp_motion_sample_t *out_sample
) {
    if (mailbox == NULL || out_version == NULL || out_sample == NULL) {
        return false;
    }

    for (unsigned attempt = 0; attempt < 8; ++attempt) {
        const uint64_t before = atomic_load_explicit(&mailbox->version, memory_order_seq_cst);
        if ((before & 1u) != 0u) {
            continue;
        }
        if (before == 0 || before == after_version) {
            return false;
        }

        mp_motion_sample_t sample = {0};
        sample.sequence = atomic_load_explicit(&mailbox->sequence, memory_order_relaxed);
        sample.event_time_ns = atomic_load_explicit(&mailbox->event_time_ns, memory_order_relaxed);
        sample.observed_time_ns = atomic_load_explicit(&mailbox->observed_time_ns, memory_order_relaxed);
        sample.quartz_x = mp_bits_to_double(
            atomic_load_explicit(&mailbox->quartz_x_bits, memory_order_relaxed));
        sample.quartz_y = mp_bits_to_double(
            atomic_load_explicit(&mailbox->quartz_y_bits, memory_order_relaxed));
        sample.appkit_x = mp_bits_to_double(
            atomic_load_explicit(&mailbox->appkit_x_bits, memory_order_relaxed));
        sample.appkit_y = mp_bits_to_double(
            atomic_load_explicit(&mailbox->appkit_y_bits, memory_order_relaxed));
        sample.flags = atomic_load_explicit(&mailbox->flags, memory_order_relaxed);
        sample.buttons = atomic_load_explicit(&mailbox->buttons, memory_order_relaxed);
        sample.event_kind = atomic_load_explicit(&mailbox->event_kind, memory_order_relaxed);

        atomic_thread_fence(memory_order_seq_cst);
        const uint64_t after = atomic_load_explicit(&mailbox->version, memory_order_seq_cst);
        if (before == after && (after & 1u) == 0u) {
            *out_sample = sample;
            *out_version = after;
            return true;
        }
    }

    return false;
}

mp_discrete_ring_t *mp_discrete_ring_create(void) {
    mp_discrete_ring_t *ring = calloc(1, sizeof(mp_discrete_ring_t));
    if (ring == NULL) {
        return NULL;
    }
    atomic_init(&ring->head, 0);
    atomic_init(&ring->tail, 0);
    atomic_init(&ring->overflow_epoch, 0);
    return ring;
}

void mp_discrete_ring_destroy(mp_discrete_ring_t *ring) {
    free(ring);
}

void mp_discrete_ring_reset(mp_discrete_ring_t *ring) {
    if (ring == NULL) {
        return;
    }
    atomic_store_explicit(&ring->tail, 0, memory_order_seq_cst);
    atomic_store_explicit(&ring->head, 0, memory_order_seq_cst);
    atomic_store_explicit(&ring->overflow_epoch, 0, memory_order_seq_cst);
}

bool mp_discrete_ring_push(mp_discrete_ring_t *ring, const mp_discrete_event_t *event) {
    if (ring == NULL || event == NULL) {
        return false;
    }

    const uint32_t head = atomic_load_explicit(&ring->head, memory_order_relaxed);
    const uint32_t tail = atomic_load_explicit(&ring->tail, memory_order_acquire);
    if ((uint32_t)(head - tail) >= MP_DISCRETE_RING_CAPACITY) {
        atomic_fetch_add_explicit(&ring->overflow_epoch, 1, memory_order_relaxed);
        return false;
    }

    ring->records[head % MP_DISCRETE_RING_CAPACITY] = *event;
    atomic_store_explicit(&ring->head, head + 1, memory_order_release);
    return true;
}

bool mp_discrete_ring_pop(mp_discrete_ring_t *ring, mp_discrete_event_t *out_event) {
    if (ring == NULL || out_event == NULL) {
        return false;
    }

    const uint32_t tail = atomic_load_explicit(&ring->tail, memory_order_relaxed);
    const uint32_t head = atomic_load_explicit(&ring->head, memory_order_acquire);
    if (tail == head) {
        return false;
    }

    *out_event = ring->records[tail % MP_DISCRETE_RING_CAPACITY];
    atomic_store_explicit(&ring->tail, tail + 1, memory_order_release);
    return true;
}

uint32_t mp_discrete_ring_count(const mp_discrete_ring_t *ring) {
    if (ring == NULL) {
        return 0;
    }
    const uint32_t head = atomic_load_explicit(&ring->head, memory_order_acquire);
    const uint32_t tail = atomic_load_explicit(&ring->tail, memory_order_acquire);
    return head - tail;
}

uint64_t mp_discrete_ring_overflow_epoch(const mp_discrete_ring_t *ring) {
    if (ring == NULL) {
        return 0;
    }
    return atomic_load_explicit(&ring->overflow_epoch, memory_order_acquire);
}

mp_event_metrics_t *mp_event_metrics_create(void) {
    mp_event_metrics_t *metrics = calloc(1, sizeof(mp_event_metrics_t));
    if (metrics == NULL) {
        return NULL;
    }
    atomic_init(&metrics->version, 0);
    atomic_init(&metrics->callback_count, 0);
    atomic_init(&metrics->callback_total_ns, 0);
    atomic_init(&metrics->callback_max_ns, 0);
    for (unsigned index = 0; index < MP_CALLBACK_BUCKET_COUNT; ++index) {
        atomic_init(&metrics->callback_buckets[index], 0);
    }
    atomic_init(&metrics->tap_disabled_timeout_count, 0);
    atomic_init(&metrics->tap_disabled_user_count, 0);
    atomic_init(&metrics->discrete_overflow_count, 0);
    return metrics;
}

void mp_event_metrics_destroy(mp_event_metrics_t *metrics) {
    free(metrics);
}

static unsigned mp_callback_bucket(uint64_t duration_ns) {
    static const uint64_t limits[MP_CALLBACK_BUCKET_COUNT - 1] = {
        50000, 100000, 250000, 500000, 1000000, 2000000, 5000000
    };
    for (unsigned index = 0; index < MP_CALLBACK_BUCKET_COUNT - 1; ++index) {
        if (duration_ns <= limits[index]) {
            return index;
        }
    }
    return MP_CALLBACK_BUCKET_COUNT - 1;
}

static void mp_event_metrics_begin_write(mp_event_metrics_t *metrics) {
    atomic_fetch_add_explicit(&metrics->version, 1, memory_order_seq_cst);
}

static void mp_event_metrics_end_write(mp_event_metrics_t *metrics) {
    atomic_fetch_add_explicit(&metrics->version, 1, memory_order_seq_cst);
}

void mp_event_metrics_record_callback(mp_event_metrics_t *metrics, uint64_t duration_ns) {
    if (metrics == NULL) {
        return;
    }

    mp_event_metrics_begin_write(metrics);
    atomic_fetch_add_explicit(&metrics->callback_count, 1, memory_order_relaxed);
    atomic_fetch_add_explicit(&metrics->callback_total_ns, duration_ns, memory_order_relaxed);
    atomic_fetch_add_explicit(
        &metrics->callback_buckets[mp_callback_bucket(duration_ns)], 1, memory_order_relaxed);

    uint64_t current = atomic_load_explicit(&metrics->callback_max_ns, memory_order_relaxed);
    while (duration_ns > current &&
           !atomic_compare_exchange_weak_explicit(
               &metrics->callback_max_ns,
               &current,
               duration_ns,
               memory_order_relaxed,
               memory_order_relaxed)) {
    }
    mp_event_metrics_end_write(metrics);
}

void mp_event_metrics_record_tap_disabled_timeout(mp_event_metrics_t *metrics) {
    if (metrics != NULL) {
        mp_event_metrics_begin_write(metrics);
        atomic_fetch_add_explicit(
            &metrics->tap_disabled_timeout_count, 1, memory_order_relaxed);
        mp_event_metrics_end_write(metrics);
    }
}

void mp_event_metrics_record_tap_disabled_user(mp_event_metrics_t *metrics) {
    if (metrics != NULL) {
        mp_event_metrics_begin_write(metrics);
        atomic_fetch_add_explicit(
            &metrics->tap_disabled_user_count, 1, memory_order_relaxed);
        mp_event_metrics_end_write(metrics);
    }
}

void mp_event_metrics_record_discrete_overflow(mp_event_metrics_t *metrics) {
    if (metrics != NULL) {
        mp_event_metrics_begin_write(metrics);
        atomic_fetch_add_explicit(
            &metrics->discrete_overflow_count, 1, memory_order_relaxed);
        mp_event_metrics_end_write(metrics);
    }
}

void mp_event_metrics_snapshot(
    const mp_event_metrics_t *metrics,
    mp_event_metrics_snapshot_t *out_snapshot
) {
    if (metrics == NULL || out_snapshot == NULL) {
        return;
    }

    for (unsigned attempt = 0; attempt < 8; ++attempt) {
        const uint64_t before = atomic_load_explicit(&metrics->version, memory_order_seq_cst);
        if ((before & 1u) != 0u) {
            continue;
        }

        mp_event_metrics_snapshot_t snapshot = {0};
        snapshot.callback_count =
            atomic_load_explicit(&metrics->callback_count, memory_order_relaxed);
        snapshot.callback_total_ns =
            atomic_load_explicit(&metrics->callback_total_ns, memory_order_relaxed);
        snapshot.callback_max_ns =
            atomic_load_explicit(&metrics->callback_max_ns, memory_order_relaxed);
        for (unsigned index = 0; index < MP_CALLBACK_BUCKET_COUNT; ++index) {
            snapshot.callback_buckets[index] =
                atomic_load_explicit(&metrics->callback_buckets[index], memory_order_relaxed);
        }
        snapshot.tap_disabled_timeout_count =
            atomic_load_explicit(&metrics->tap_disabled_timeout_count, memory_order_relaxed);
        snapshot.tap_disabled_user_count =
            atomic_load_explicit(&metrics->tap_disabled_user_count, memory_order_relaxed);
        snapshot.discrete_overflow_count =
            atomic_load_explicit(&metrics->discrete_overflow_count, memory_order_relaxed);

        atomic_thread_fence(memory_order_seq_cst);
        const uint64_t after = atomic_load_explicit(&metrics->version, memory_order_seq_cst);
        if (before == after && (after & 1u) == 0u) {
            *out_snapshot = snapshot;
            return;
        }
    }

    memset(out_snapshot, 0, sizeof(*out_snapshot));
}

uint64_t mp_monotonic_time_ns(void) {
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
}
