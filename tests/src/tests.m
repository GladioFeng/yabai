#include <Cocoa/Cocoa.h>
#include <ApplicationServices/ApplicationServices.h>
extern AXError _AXUIElementGetWindow(AXUIElementRef, uint32_t *);
static AXError test_ax_copy(AXUIElementRef, CFStringRef, CFTypeRef *);
static AXError test_ax_set(AXUIElementRef, CFStringRef, CFTypeRef);
static AXError test_ax_pid(AXUIElementRef, pid_t *);
static AXError test_ax_id(AXUIElementRef, uint32_t *);
static AXError test_ax_settable(AXUIElementRef, CFStringRef, Boolean *);
#define AXUIElementCopyAttributeValue test_ax_copy
#define AXUIElementSetAttributeValue test_ax_set
#define AXUIElementGetPid test_ax_pid
#define _AXUIElementGetWindow test_ax_id
#define AXUIElementIsAttributeSettable test_ax_settable
unsigned char __src_osax_payload[1];
unsigned int __src_osax_payload_len;
unsigned char __src_osax_loader[1];
unsigned int __src_osax_loader_len;

#include "../../src/manifest.m"
#undef AXUIElementCopyAttributeValue
#undef AXUIElementSetAttributeValue
#undef AXUIElementGetPid
#undef _AXUIElementGetWindow
#undef AXUIElementIsAttributeSettable

#define TEST_SIG(name) bool test_##name(void)
typedef TEST_SIG(function);

#define TEST_FUNC(name, code) static TEST_SIG(name) { char *test_name = #name; bool result = true; {code} return result; }
#define TEST_CHECK(r, e) if ((r) != (e)) { printf("                   \e[1;33m%s\e[m\e[1;31m#%d %s == %s\e[m \e[1;31m(%d == %d)\e[m\n", test_name, __LINE__, #r, #e, r, e); result = false; }

#include "area.c"

// Mock only the selected AX objects; exercise the real shared getters and writers.
static struct {
    bool active, healthy, wrong_pid, wrong_id, missing;
    AXError read_error, id_error;
    AXUIElementRef app, old, fresh;
    CGRect frame, written;
    struct window *destroy_window;
    int enumerations, old_writes, fresh_writes, attribute_reads, capability_reads;
} ax_test;

static AXError test_ax_copy(AXUIElementRef ref, CFStringRef key, CFTypeRef *value)
{
    if (!ax_test.active) return AXUIElementCopyAttributeValue(ref, key, value);
    ++ax_test.attribute_reads;
    *value = NULL;
    if (ref == ax_test.app && CFEqual(key, kAXWindowsAttribute)) {
        ++ax_test.enumerations;
        if (ax_test.destroy_window) ax_test.destroy_window->id_ptr = NULL;
        if (ax_test.missing) return kAXErrorCannotComplete;
        const void *items[] = { ax_test.fresh };
        *value = CFArrayCreate(NULL, items, 1, &kCFTypeArrayCallBacks);
        return kAXErrorSuccess;
    }
    if (ref != ax_test.old && ref != ax_test.fresh) return kAXErrorAttributeUnsupported;
    if (ref == ax_test.old && ax_test.read_error) return ax_test.read_error;
    CGRect f = ref == ax_test.old && !ax_test.healthy ? CGRectZero : ax_test.frame;
    if (CFEqual(key, kAXPositionAttribute)) *value = AXValueCreate(kAXValueTypeCGPoint, &f.origin);
    else if (CFEqual(key, kAXSizeAttribute)) *value = AXValueCreate(kAXValueTypeCGSize, &f.size);
    else if (CFEqual(key, kAXRoleAttribute)) *value = CFRetain(kAXWindowRole);
    else if (CFEqual(key, kAXSubroleAttribute)) *value = CFRetain(kAXStandardWindowSubrole);
    else return kAXErrorAttributeUnsupported;
    return kAXErrorSuccess;
}

static AXError test_ax_set(AXUIElementRef ref, CFStringRef key, CFTypeRef value)
{
    if (!ax_test.active) return AXUIElementSetAttributeValue(ref, key, value);
    if (ref == ax_test.old) ++ax_test.old_writes;
    if (ref == ax_test.fresh) ++ax_test.fresh_writes;
    if (ref == ax_test.old || ref == ax_test.fresh) {
        if (CFEqual(key, kAXPositionAttribute)) AXValueGetValue(value, kAXValueTypeCGPoint, &ax_test.written.origin);
        if (CFEqual(key, kAXSizeAttribute)) AXValueGetValue(value, kAXValueTypeCGSize, &ax_test.written.size);
    }
    return kAXErrorSuccess;
}

static AXError test_ax_pid(AXUIElementRef ref, pid_t *pid)
{
    if (!ax_test.active) return AXUIElementGetPid(ref, pid);
    *pid = ref == ax_test.fresh && ax_test.wrong_pid ? 999 : 500;
    return kAXErrorSuccess;
}

static AXError test_ax_id(AXUIElementRef ref, uint32_t *id)
{
    if (!ax_test.active) return _AXUIElementGetWindow(ref, id);
    if (ref == ax_test.old && ax_test.id_error) return ax_test.id_error;
    *id = ref == ax_test.fresh && ax_test.wrong_id ? 999 : 225;
    return kAXErrorSuccess;
}

static AXError test_ax_settable(AXUIElementRef ref, CFStringRef key, Boolean *value)
{
    if (!ax_test.active) return AXUIElementIsAttributeSettable(ref, key, value);
    ++ax_test.capability_reads;
    if (ref != ax_test.fresh) return kAXErrorInvalidUIElement;
    *value = true;
    return kAXErrorSuccess;
}

TEST_FUNC(ax_minimize_notification_routing,
{
    ax_test = (typeof(ax_test)){0};
    ax_test.active = true;
    ax_test.app = AXUIElementCreateApplication(100);
    ax_test.old = AXUIElementCreateApplication(101);
    ax_test.fresh = AXUIElementCreateApplication(102);
    ax_test.frame = CGRectMake(20, 30, 400, 300);
    ax_test.id_error = kAXErrorIllegalArgument;
    struct application app = {0}; app.ref = ax_test.app; app.pid = 500;
    struct window w = {0}; w.application = &app; w.ref = ax_test.old; w.id = 225; w.id_ptr = &w.id;
    window_refresh_ax_properties(&w);
    TEST_CHECK(window_can_move(&w) && window_can_resize(&w), true);
    TEST_CHECK(CFEqual(w.subrole, kAXStandardWindowSubrole), true);
    ax_test.missing = true;
    window_refresh_ax_properties(&w);
    TEST_CHECK(window_can_move(&w) && window_can_resize(&w), true);
    TEST_CHECK(CFEqual(w.subrole, kAXStandardWindowSubrole), true);
    ax_test.missing = false;

    // Exercise callbacks from both registration scopes without a worker thread.
    memory_pool_init(&g_event_loop.pool, 4096);
    char name[64]; snprintf(name, sizeof(name), "/yabai_min_test_%d", getpid());
    g_event_loop.semaphore = sem_open(name, O_CREAT, 0600, 0); sem_unlink(name);
    g_event_loop.head = memory_pool_push(&g_event_loop.pool, sizeof(struct event));
    g_event_loop.head->next = NULL; g_event_loop.tail = g_event_loop.head;
    for (int i = 0; i < 4; ++i) {
        application_notification_handler(NULL, ax_test.fresh,
            i < 2 ? kAXWindowMiniaturizedNotification : kAXWindowDeminiaturizedNotification,
            i % 2 ? (void *)&w : (void *)&app);
        TEST_CHECK(g_event_loop.tail->type == (i < 2 ? WINDOW_MINIMIZED : WINDOW_DEMINIMIZED), true);
        TEST_CHECK((uint32_t)(uintptr_t)g_event_loop.tail->context == w.id, true);
    }
    sem_close(g_event_loop.semaphore);
    munmap(g_event_loop.pool.memory, g_event_loop.pool.size + getpagesize());
    g_event_loop = (struct event_loop){0};

    table_init(&g_window_manager.window, 13, hash_wm, compare_wm);
    table_init(&g_window_manager.window_lost_focused_event, 13, hash_wm, compare_wm);
    table_add(&g_window_manager.window, &w.id, &w);
    table_init(&g_window_manager.managed_window, 13, hash_wm, compare_wm);
    ax_test.attribute_reads = ax_test.capability_reads = 0;
    EVENT_HANDLER_WINDOW_MINIMIZED((void *)(uintptr_t)w.id, 0);
    TEST_CHECK(window_check_flag(&w, WINDOW_MINIMIZE), true);
    TEST_CHECK(ax_test.attribute_reads == 0 && ax_test.capability_reads == 0, true);
    TEST_CHECK(window_can_move(&w) && window_can_resize(&w), true);
    TEST_CHECK(CFEqual(w.subrole, kAXStandardWindowSubrole), true);
    // Duplicate notifications and queued events for destroyed windows must be harmless.
    window_set_flag(&w, WINDOW_MINIMIZE);
    EVENT_HANDLER_WINDOW_MINIMIZED((void *)(uintptr_t)w.id, 0);
    window_clear_flag(&w, WINDOW_MINIMIZE);
    EVENT_HANDLER_WINDOW_DEMINIMIZED((void *)(uintptr_t)w.id, 0);
    w.id_ptr = NULL;
    EVENT_HANDLER_WINDOW_MINIMIZED((void *)(uintptr_t)w.id, 0);
    EVENT_HANDLER_WINDOW_DEMINIMIZED((void *)(uintptr_t)w.id, 0);
    EVENT_HANDLER_WINDOW_MINIMIZED((void *)(uintptr_t)999, 0);
    EVENT_HANDLER_WINDOW_DEMINIMIZED((void *)(uintptr_t)999, 0);
    TEST_CHECK(window_check_flag(&w, WINDOW_MINIMIZE), false);
    table_free(&g_window_manager.managed_window);
    table_free(&g_window_manager.window);
    table_free(&g_window_manager.window_lost_focused_event);
    app.notification = 1 << AX_APPLICATION_WINDOW_DEMINIMIZED_INDEX;
    TEST_CHECK(app.notification == 256, true);
    CFRelease(w.role); CFRelease(w.subrole);
    CFRelease(ax_test.app); CFRelease(ax_test.old); CFRelease(ax_test.fresh);
    ax_test = (typeof(ax_test)){0};
});

TEST_FUNC(ax_stale_reference_recovery,
{
    ax_test.app = AXUIElementCreateApplication(100);
    ax_test.old = AXUIElementCreateApplication(101);
    ax_test.fresh = AXUIElementCreateApplication(102);
    ax_test.frame = CGRectMake(20, 30, 400, 300);
    ax_test.active = true;
    struct application app = {0}; app.ref = ax_test.app; app.pid = 500;
    struct window w = {0}; w.application = &app; w.ref = ax_test.old; w.id = 225; w.notification = AX_WINDOW_ALL;
    w.id_ptr = &w.id;
    w.frame = CGRectZero; // Recover from a zero cache, not merely return the cached geometry.
    CFIndex retained = CFGetRetainCount(ax_test.fresh);

    ax_test.healthy = true;
    TEST_CHECK(CGRectEqualToRect(window_ax_frame(&w), ax_test.frame), true);
    TEST_CHECK(ax_test.enumerations == 0, true);
    window_manager_set_window_frame(&w, 30, 40, 500, 400);
    TEST_CHECK(ax_test.old_writes == 3 && ax_test.fresh_writes == 0, true);

    ax_test.healthy = false;
    ax_test.old_writes = ax_test.fresh_writes = 0;
    TEST_CHECK(CGRectEqualToRect(window_ax_frame(&w), ax_test.frame), true);
    TEST_CHECK(CGPointEqualToPoint(window_ax_origin(&w), ax_test.frame.origin), true);
    window_manager_set_window_frame(&w, 30, 40, 500, 400);
    TEST_CHECK(ax_test.old_writes == 0 && ax_test.fresh_writes == 3, true);
    window_manager_move_window(&w, 30, 40);
    window_manager_resize_window(&w, 500, 400);
    TEST_CHECK(ax_test.old_writes == 0 && ax_test.fresh_writes == 5, true);
    TEST_CHECK(w.ref == ax_test.old && w.notification == AX_WINDOW_ALL && w.id_ptr == &w.id, true);
    TEST_CHECK(CFGetRetainCount(ax_test.fresh) == retained, true);

    struct window_manager wm = {0};
    table_init(&wm.managed_window, 13, hash_wm, compare_wm);
    TEST_CHECK(window_manager_move_window_relative(&wm, &w, TYPE_REL, 50, 0) == WINDOW_OP_ERROR_SUCCESS, true);
    TEST_CHECK(CGRectEqualToRect(ax_test.written, CGRectMake(70, 30, 400, 300)), true);
    TEST_CHECK(window_manager_resize_window_relative(&wm, &w, HANDLE_ABS, 500, 450, true) == WINDOW_OP_ERROR_SUCCESS, true);
    TEST_CHECK(CGRectEqualToRect(ax_test.written, CGRectMake(20, 30, 500, 450)), true);
    table_free(&wm.managed_window);
    w.frame = ax_test.frame; // Matching cache must not make a writer choose the bad reference.
    ax_test.old_writes = ax_test.fresh_writes = 0;
    window_manager_set_window_frame(&w, 30, 40, 500, 400);
    TEST_CHECK(ax_test.old_writes == 0 && ax_test.fresh_writes == 3, true);
    ax_test.read_error = kAXErrorCannotComplete;
    TEST_CHECK(CGRectEqualToRect(window_ax_frame(&w), ax_test.frame), true);
    ax_test.read_error = kAXErrorSuccess;
    ax_test.id_error = kAXErrorIllegalArgument;
    TEST_CHECK(CGRectEqualToRect(window_ax_frame(&w), ax_test.frame), true);
    ax_test.id_error = kAXErrorSuccess;
    for (int mode = 0; mode < 5; ++mode) {
        w.id_ptr = &w.id;
        ax_test.destroy_window = mode == 4 ? &w : NULL;
        ax_test.wrong_pid = mode == 0;
        ax_test.wrong_id = mode == 1;
        ax_test.missing = mode == 2;
        if (mode == 3) w.id_ptr = NULL;
        ax_test.old_writes = ax_test.fresh_writes = 0;
        TEST_CHECK(CGRectEqualToRect(window_ax_frame(&w), w.frame), true);
        window_manager_set_window_frame(&w, 30, 40, 500, 400);
        TEST_CHECK(ax_test.old_writes == 0 && ax_test.fresh_writes == 0, true);
    }
    TEST_CHECK(CFGetRetainCount(ax_test.fresh) == retained, true);
    ax_test.active = false;
    CFRelease(ax_test.app); CFRelease(ax_test.old); CFRelease(ax_test.fresh);
});


#ifdef __x86_64__
#include "../../src/osax/x64_payload.m"

static const unsigned char expected[] = { 0x66, 0x0f, 0xef, 0xc0, 0x66, 0x0f, 0xef, 0xc0 };

TEST_FUNC(x64_space_animation_patch_bytes,
{
    TEST_CHECK(memcmp(&x64_zero_animation_patch, expected, sizeof(expected)) == 0, true);
});
#endif

#define TEST_ENTRY(name) { #name, test_##name },
#define TEST_LIST                                              \
    TEST_ENTRY(display_area_is_in_direction)                   \
    TEST_ENTRY(closest_display_in_direction)

static struct {
    char *name;
    test_function *func;
} tests[] = {
    TEST_LIST
    TEST_ENTRY(ax_minimize_notification_routing)
    TEST_ENTRY(ax_stale_reference_recovery)
#ifdef __x86_64__
    TEST_ENTRY(x64_space_animation_patch_bytes)
#endif
};

int main(int argc, char **argv)
{
    int succeeded = 0;
    int failed = 0;
    int total = array_count(tests);
    printf("\e[1;34m -- Running %d tests\e[m\n\n", total);

    uint64_t cpu_freq  = read_cpu_freq();
    uint64_t begin_tsc = read_cpu_timer();

    for (int i = 0; i < total; ++i) {
        uint64_t tsc = read_cpu_timer();
        bool result = tests[i].func();
        double ms_elapsed = 1000.0 * (double)(read_cpu_timer() - tsc) / (double)cpu_freq;

        printf("(%0.4fms) %s \e[1;33m%s\e[m\n", ms_elapsed, result ? "\e[1;32msuccess\e[m" : " \e[1;31mfailed\e[m", tests[i].name);
        if (result) ++succeeded; else ++failed;
    }

    double ms_elapsed = 1000.0 * (double)(read_cpu_timer() - begin_tsc) / (double)cpu_freq;
    printf("\n\e[1;34m -- Completed (%0.4fms)\e[m\n", ms_elapsed);
    printf("\t%d \e[1;32msucceeded\e[m\n", succeeded);
    printf("\t%d \e[1;31mfailed\e[m\n", failed);
    printf("\t%d \e[1;33mtotal\e[m\n", total);

    return total == succeeded ? EXIT_SUCCESS : EXIT_FAILURE;
}
