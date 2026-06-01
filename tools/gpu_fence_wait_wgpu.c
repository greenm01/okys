#include <stdint.h>

#if OKYS_ENABLE_WGPU_FENCE
#include <stdatomic.h>
#include <time.h>
#include <webgpu/webgpu.h>

typedef struct okys_wgpu_wait_state {
    atomic_int done;
    int status;
} okys_wgpu_wait_state;

static void okys_wgpu_queue_done(
    WGPUQueueWorkDoneStatus status,
    WGPUStringView message,
    void *userdata1,
    void *userdata2) {
    (void)message;
    (void)userdata2;
    okys_wgpu_wait_state *state = (okys_wgpu_wait_state *)userdata1;
    state->status = (int)status;
    atomic_store_explicit(&state->done, 1, memory_order_release);
}

static uint64_t okys_now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ((uint64_t)ts.tv_sec * 1000000000ull) + (uint64_t)ts.tv_nsec;
}

int okys_wgpu_queue_fence_wait(const void *queue_ptr, uint64_t timeout_ns) {
    static atomic_int disabled_after_timeout = 0;
    if (queue_ptr == 0) {
        return -1;
    }
    if (atomic_load_explicit(&disabled_after_timeout, memory_order_acquire) != 0) {
        return -4;
    }

    okys_wgpu_wait_state state;
    atomic_init(&state.done, 0);
    state.status = 0;

    WGPUQueueWorkDoneCallbackInfo info = {0};
    info.mode = WGPUCallbackMode_AllowSpontaneous;
    info.callback = okys_wgpu_queue_done;
    info.userdata1 = &state;

    wgpuQueueOnSubmittedWorkDone((WGPUQueue)queue_ptr, info);

    const uint64_t start = okys_now_ns();
    const struct timespec sleep_for = {.tv_sec = 0, .tv_nsec = 1000000};
    while (atomic_load_explicit(&state.done, memory_order_acquire) == 0) {
        if (okys_now_ns() - start >= timeout_ns) {
            atomic_store_explicit(&disabled_after_timeout, 1, memory_order_release);
            return -4;
        }
        nanosleep(&sleep_for, 0);
    }

    return state.status == (int)WGPUQueueWorkDoneStatus_Success ? 0 : -3;
}
#else
int okys_wgpu_queue_fence_wait(const void *queue_ptr, uint64_t timeout_ns) {
    (void)queue_ptr;
    (void)timeout_ns;
    return -5;
}
#endif
