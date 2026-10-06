unsigned char __src_osax_payload[1];
unsigned int __src_osax_payload_len;
unsigned char __src_osax_loader[1];
unsigned int __src_osax_loader_len;

#include "../../src/manifest.m"

#define TEST_SIG(name) bool test_##name(void)
typedef TEST_SIG(function);

#define TEST_FUNC(name, code) static TEST_SIG(name) { char *test_name = #name; bool result = true; {code} return result; }
#define TEST_CHECK(r, e) if ((r) != (e)) { printf("                   \e[1;33m%s\e[m\e[1;31m#%d %s == %s\e[m \e[1;31m(%d == %d)\e[m\n", test_name, __LINE__, #r, #e, r, e); result = false; }

#include "area.c"

#ifdef __x86_64__
#include "../../src/osax/x64_payload.m"

static bool test_pattern_matches(const unsigned char *bytes, size_t length, const char *pattern)
{
    size_t i = 0;
    while (*pattern) {
        if (i == length) return false;
        if (pattern[0] != '?' || pattern[1] != '?') {
            unsigned int value;
            if (sscanf(pattern, "%2x", &value) != 1 || bytes[i] != value) return false;
        }
        ++i;
        pattern += 2;
        if (*pattern == ' ') ++pattern;
    }
    return true;
}

// Receiver load for moveSpace:toDisplay:displayUUID: in the 23J423 Intel Dock.
static const unsigned char dppm_receiver[] = {
    0xBE, 0xC9, 0x14, 0x00, 0x4C, 0x8B, 0x28, 0x4C, 0x89, 0xEF,
    0xE8, 0xD1, 0x58, 0x05, 0x00, 0x48, 0x89, 0xDF, 0x4C, 0x89,
    0xF6, 0xE8, 0x26, 0x38, 0x05, 0x00, 0x48, 0x89, 0xC3, 0x48,
    0x8B, 0x35, 0xEE, 0x14, 0x12, 0x00, 0x4C, 0x89, 0xEF
};

static const unsigned char dppm_getter_tail[] = {
    0xB2, 0x76, 0x2C, 0x00, 0x31, 0xFF, 0x5D, 0xE9, 0x1C, 0xF3, 0x1C, 0x00
};

TEST_FUNC(sonoma_14_8_5_scripting_addition_scan_windows,
{
    NSOperatingSystemVersion version;
    version.majorVersion = 14;
    version.minorVersion = 8;
    version.patchVersion = 5;

    // Unique pattern locations observed in the Intel Dock on macOS 14.8.5 (23J423).
    uint64_t dock_spaces = get_dock_spaces_offset(version);
    uint64_t dppm = get_dppm_offset(version);
    uint64_t set_front_window = get_set_front_window_offset(version);
    TEST_CHECK(dock_spaces <= 0xD4B4C && 0xD4B4C < dock_spaces + 0x1286A0, true);
    TEST_CHECK(dppm <= 0x2A7316 && 0x2A7316 < dppm + 0x1286A0, true);
    TEST_CHECK(set_front_window <= 0x499BE && 0x499BE < set_front_window + 0x1286A0, true);
    TEST_CHECK(test_pattern_matches(dppm_receiver, sizeof(dppm_receiver), get_dppm_pattern(version)), true);
    TEST_CHECK(test_pattern_matches(dppm_getter_tail, sizeof(dppm_getter_tail), get_dppm_pattern(version)), false);

    version.patchVersion = 4;
    TEST_CHECK(get_dock_spaces_offset(version) == 0xD5000, true);
    TEST_CHECK(get_dppm_offset(version) == 0x12CE00, true);
    TEST_CHECK(get_set_front_window_offset(version) == 0x4A000, true);

    version.patchVersion = 6;
    TEST_CHECK(get_dock_spaces_offset(version) == 0xD5000, true);
    TEST_CHECK(get_dppm_offset(version) == 0x12CE00, true);
    TEST_CHECK(get_set_front_window_offset(version) == 0x4A000, true);

    version.minorVersion = 7;
    version.patchVersion = 8;
    TEST_CHECK(get_dock_spaces_offset(version) == 0xD5000, true);
    TEST_CHECK(get_dppm_offset(version) == 0x12CE00, true);
    TEST_CHECK(get_set_front_window_offset(version) == 0x4A000, true);
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
#ifdef __x86_64__
    TEST_ENTRY(sonoma_14_8_5_scripting_addition_scan_windows)
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
