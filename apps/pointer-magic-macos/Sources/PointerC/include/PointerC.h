#ifndef POINTER_MAGIC_C_H
#define POINTER_MAGIC_C_H

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

/// Stable identity for one observed process incarnation. `start_time_unix_ns`
/// must be paired with `pid`; a PID alone can be reused after process exit.
typedef struct {
    int32_t pid;
    int32_t parent_pid;
    int32_t process_group_id;
    int32_t terminal_process_group_id;
    uint32_t status;
    uint32_t _padding;
    uint64_t start_time_unix_ns;
    uint64_t controlling_terminal_device;
} mp_process_identity_t;

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

/// Passive process inspection used by the macOS agent-discovery subsystem.
/// These functions never signal, suspend, spawn, attach to, or write to a process.
/// String-copy functions return the number of bytes excluding the final NUL.
size_t mp_process_list_pids(
    int32_t *out_pids,
    size_t capacity,
    bool *out_truncated
);
bool mp_process_read_identity(int32_t pid, mp_process_identity_t *out_identity);
size_t mp_process_copy_name(int32_t pid, char *out_buffer, size_t capacity);
size_t mp_process_copy_executable_path(int32_t pid, char *out_buffer, size_t capacity);
size_t mp_process_copy_cwd(int32_t pid, char *out_buffer, size_t capacity);
size_t mp_process_copy_tty(int32_t pid, char *out_buffer, size_t capacity);

/// Copies argv as consecutive NUL-terminated strings, without environment data.
/// The returned byte count includes each copied string terminator. Truncation occurs
/// only between arguments, never in the middle of one.
size_t mp_process_copy_arguments(
    int32_t pid,
    char *out_buffer,
    size_t capacity,
    uint32_t *out_argument_count,
    bool *out_truncated
);

/// Copies open vnode paths as consecutive NUL-terminated strings. This is a bounded
/// native substitute for launching `lsof`; callers should request it only for already
/// classified candidate processes.
size_t mp_process_copy_open_file_paths(
    int32_t pid,
    char *out_buffer,
    size_t capacity,
    size_t maximum_paths,
    uint32_t *out_path_count,
    bool *out_truncated
);

#ifdef __cplusplus
}
#endif

#endif
