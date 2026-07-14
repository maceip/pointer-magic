#ifndef MAGIC_POINTER_C_H
#define MAGIC_POINTER_C_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
    MP_POINTER_EVENT_MOVED = 1,
    MP_POINTER_EVENT_DRAGGED = 2,
    MP_POINTER_EVENT_BUTTON = 3,
    MP_POINTER_EVENT_FALLBACK = 4,
};

enum {
    MP_DISCRETE_BUTTON_DOWN = 1,
    MP_DISCRETE_BUTTON_UP = 2,
    MP_DISCRETE_SCROLL = 3,
};

typedef struct {
    uint64_t sequence;
    uint64_t event_time_ns;
    uint64_t observed_time_ns;
    double quartz_x;
    double quartz_y;
    double appkit_x;
    double appkit_y;
    uint64_t flags;
    uint32_t buttons;
    uint8_t event_kind;
    uint8_t _padding[3];
} mp_motion_sample_t;

typedef struct {
    uint64_t sequence;
    uint64_t event_time_ns;
    uint64_t observed_time_ns;
    double quartz_x;
    double quartz_y;
    double delta_x;
    double delta_y;
    uint64_t flags;
    uint32_t buttons;
    uint8_t event_kind;
    uint8_t button;
    uint8_t click_count;
    uint8_t _padding;
} mp_discrete_event_t;

typedef struct mp_motion_mailbox mp_motion_mailbox_t;
typedef struct mp_discrete_ring mp_discrete_ring_t;
typedef struct mp_event_metrics mp_event_metrics_t;

typedef struct {
    uint64_t callback_count;
    uint64_t callback_total_ns;
    uint64_t callback_max_ns;
    uint64_t callback_buckets[8];
    uint64_t tap_disabled_timeout_count;
    uint64_t tap_disabled_user_count;
    uint64_t discrete_overflow_count;
} mp_event_metrics_snapshot_t;

mp_motion_mailbox_t *mp_motion_mailbox_create(void);
void mp_motion_mailbox_destroy(mp_motion_mailbox_t *mailbox);
void mp_motion_mailbox_reset(mp_motion_mailbox_t *mailbox);
void mp_motion_mailbox_write(mp_motion_mailbox_t *mailbox, const mp_motion_sample_t *sample);
bool mp_motion_mailbox_read(
    const mp_motion_mailbox_t *mailbox,
    uint64_t after_version,
    uint64_t *out_version,
    mp_motion_sample_t *out_sample
);

mp_discrete_ring_t *mp_discrete_ring_create(void);
void mp_discrete_ring_destroy(mp_discrete_ring_t *ring);
void mp_discrete_ring_reset(mp_discrete_ring_t *ring);
bool mp_discrete_ring_push(mp_discrete_ring_t *ring, const mp_discrete_event_t *event);
bool mp_discrete_ring_pop(mp_discrete_ring_t *ring, mp_discrete_event_t *out_event);
uint32_t mp_discrete_ring_count(const mp_discrete_ring_t *ring);
uint64_t mp_discrete_ring_overflow_epoch(const mp_discrete_ring_t *ring);

mp_event_metrics_t *mp_event_metrics_create(void);
void mp_event_metrics_destroy(mp_event_metrics_t *metrics);
void mp_event_metrics_record_callback(mp_event_metrics_t *metrics, uint64_t duration_ns);
void mp_event_metrics_record_tap_disabled_timeout(mp_event_metrics_t *metrics);
void mp_event_metrics_record_tap_disabled_user(mp_event_metrics_t *metrics);
void mp_event_metrics_record_discrete_overflow(mp_event_metrics_t *metrics);
void mp_event_metrics_snapshot(
    const mp_event_metrics_t *metrics,
    mp_event_metrics_snapshot_t *out_snapshot
);

uint64_t mp_monotonic_time_ns(void);

#ifdef __cplusplus
}
#endif

#endif
