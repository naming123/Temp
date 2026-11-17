// logger.c - sysfs logger for Lenovo TB321FU (Snapdragon 8 Gen 3)
// usage: ./logger <out_name> [duration_sec]   -> writes <out_name>.txt
// Output: tab-separated, one row per SAMPLING_TIME_MS, each row ends with EOL.
//
// Timing: same scheme as the original logger. Sleep until btime + SAMPLING_TIME_MS,
//         write one row, then btime += SAMPLING_TIME_MS (absolute deadline, CLOCK_MONOTONIC).
//
// Units
//   Time                 : count * SAMPLING_TIME_MS (row index based, not measured)
//   *_freq, MIF_Freq,
//   GPU_Freq             : GHz  (sysfs kHz / Hz -> GHz)
//   *_util, GPU_util     : %
//   temperature columns  : degC (sysfs mdegC / 1000)
//   *_freq_throttling    : 1 if scaling_max_freq < cpuinfo_max_freq, else 0
//   cdsp_*_state         : cooling_device cur_state (0 = no limit)
//   batt_volt            : mV (sysfs uV / 1000)
//   batt_curr            : mA (sysfs uA / 1000; unit and sign to be verified)
//   OFF = node missing or CPU offline, NA = no previous sample for util

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <time.h>
#include <unistd.h>

#define SAMPLING_TIME_MS 100
#define NUM_CPUS         8
#define NUM_STAT_FIELDS  8   // user nice system idle iowait irq softirq steal (guest is already in user)

typedef unsigned long long u64;

static volatile sig_atomic_t stop_flag = 0;
static void on_signal(int sig) { (void)sig; stop_flag = 1; }

/* ---------- column definitions (header and rows are built from the same tables) ---------- */

static const char *CPU_NAME[NUM_CPUS] = {
    "LIT0", "LIT1", "MID2", "MID3", "MID4", "MID5", "MID6", "BIG7"
};

struct cluster { const char *name; int policy; };
static const struct cluster CLUSTER[] = {
    {"LIT", 0}, {"MID2", 2}, {"MID5", 5}, {"BIG", 7}
};
#define NUM_CLUSTERS ((int)(sizeof(CLUSTER) / sizeof(CLUSTER[0])))

// Highest temperature among the listed thermal zones (zone numbers checked on TB321FU)
struct temp_group { const char *name; int zones[8]; int count; };
static const struct temp_group TEMP_GROUP[] = {
    // per-core: max over that core's sensors (type = cpu-<cluster>-<core>-<sensor>)
    // core order inside cpu-1-* / cpu-2-* is ASSUMED sequential (to be verified with taskset)
    {"LIT0_temp",       {28}, 1},                              // cpu-0-0-0
    {"LIT1_temp",       {29}, 1},                              // cpu-0-1-0
    {"MID2_temp",       {20, 21}, 2},                          // cpu-1-0-0/1
    {"MID3_temp",       {22, 23}, 2},                          // cpu-1-1-0/1
    {"MID4_temp",       {25, 26, 27}, 3},                      // cpu-1-2-0/1/2 (zone24 = aoss-1, excluded)
    {"MID5_temp",       {14, 15}, 2},                          // cpu-2-0-0/1
    {"MID6_temp",       {16, 17}, 2},                          // cpu-2-1-0/1
    {"BIG7_temp",       {18, 19}, 2},                          // cpu-2-2-0/1
    {"cpuss_temp",      {10, 11, 12, 13}, 4},                  // CPU subsystem shared area
    {"gpuss_temp",      {41, 42, 43, 44, 45, 46, 47, 48}, 8},
    {"nsphvx_temp",     {30, 31}, 2},                          // NPU HVX
    {"nsphmx_temp",     {32, 33, 34, 35}, 4},                  // NPU HMX
    {"ddr_temp",         {37}, 1},
    {"skin-msm-therm_temp", {60}, 1},
};
#define NUM_TEMP_GROUPS ((int)(sizeof(TEMP_GROUP) / sizeof(TEMP_GROUP[0])))

struct cdev { const char *name; int id; };
static const struct cdev CDSP_STATE[] = {
    {"cdsp_hw_state", 41}, {"cdsp_state", 42},
    {"cdsp_sw_hvx_state", 43}, {"cdsp_sw_hmx_state", 44}
};
#define NUM_CDSP_STATES ((int)(sizeof(CDSP_STATE) / sizeof(CDSP_STATE[0])))

/* ---------- helpers ---------- */

static int read_long(const char *path, long long *out)
{
    FILE *f = fopen(path, "r");
    int ok;
    if (f == NULL)
        return -1;
    ok = (fscanf(f, "%lld", out) == 1);
    fclose(f);
    return ok ? 0 : -1;
}

// Reads an integer node, divides it, prints with `prec` decimals (OFF on failure)
static void write_scaled(FILE *fp, const char *path, double div, int prec)
{
    long long v;
    if (read_long(path, &v) == 0)
        fprintf(fp, "%.*f\t", prec, v / div);
    else
        fputs("OFF\t", fp);
}

static long long now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

/* ---------- header ---------- */

static void write_header(FILE *fp)
{
    int i;
    fputs("Time\t", fp);
    for (i = 0; i < NUM_CPUS; i++)        fprintf(fp, "%s_freq\t", CPU_NAME[i]);
    for (i = 0; i < NUM_CPUS; i++)        fprintf(fp, "%s_util\t", CPU_NAME[i]);
    fputs("MIF_Freq\tGPU_Freq\tGPU_util\t", fp);
    for (i = 0; i < NUM_TEMP_GROUPS; i++) fprintf(fp, "%s\t", TEMP_GROUP[i].name);
    for (i = 0; i < NUM_CLUSTERS; i++)    fprintf(fp, "%s_freq_throttling\t", CLUSTER[i].name);
    for (i = 0; i < NUM_CDSP_STATES; i++) fprintf(fp, "%s\t", CDSP_STATE[i].name);
    fputs("batt_volt\tbatt_curr\tEOL\n", fp);
}

/* ---------- column writers (function name = column name) ---------- */

static void write_time(FILE *fp, long long time_ms)
{
    fprintf(fp, "%lld	", time_ms);
}

// LIT0_freq ... BIG7_freq : scaling_cur_freq (kHz) -> GHz
// OPP steps are 100 kHz, so 4 decimals in GHz are lossless
static void write_freq(FILE *fp)
{
    char path[128];
    int i;
    for (i = 0; i < NUM_CPUS; i++) {
        snprintf(path, sizeof(path), "/sys/devices/system/cpu/cpu%d/cpufreq/scaling_cur_freq", i);
        write_scaled(fp, path, 1e6, 4);
    }
}

// LIT0_util ... BIG7_util : from /proc/stat, matched by "cpuN" name
// (offline CPUs have no line in /proc/stat, so index-based parsing would shift)
static u64 util_last[NUM_CPUS][NUM_STAT_FIELDS];
static int util_valid[NUM_CPUS];

static void read_proc_stat(u64 cur[NUM_CPUS][NUM_STAT_FIELDS], int present[NUM_CPUS])
{
    FILE *f = fopen("/proc/stat", "r");
    char line[512];
    memset(present, 0, sizeof(int) * NUM_CPUS);
    if (f == NULL)
        return;
    while (fgets(line, sizeof(line), f)) {
        int id;
        u64 v[NUM_STAT_FIELDS] = {0};
        if (strncmp(line, "cpu", 3) != 0)
            break;                    // cpu lines come first
        if (line[3] == ' ')
            continue;                 // aggregate "cpu" line
        if (sscanf(line, "cpu%d %llu %llu %llu %llu %llu %llu %llu %llu", &id,
                   &v[0], &v[1], &v[2], &v[3], &v[4], &v[5], &v[6], &v[7]) >= 5
            && id >= 0 && id < NUM_CPUS) {
            memcpy(cur[id], v, sizeof(v));
            present[id] = 1;
        }
    }
    fclose(f);
}

static void init_util(void)
{
    int present[NUM_CPUS], i;
    read_proc_stat(util_last, present);
    for (i = 0; i < NUM_CPUS; i++)
        util_valid[i] = present[i];
}

static void write_util(FILE *fp)
{
    u64 cur[NUM_CPUS][NUM_STAT_FIELDS] = {{0}};
    int present[NUM_CPUS], i, j;

    read_proc_stat(cur, present);
    for (i = 0; i < NUM_CPUS; i++) {
        u64 total = 0, active, d[NUM_STAT_FIELDS];
        if (!present[i]) {
            fputs("OFF\t", fp);
            util_valid[i] = 0;
            continue;
        }
        if (!util_valid[i]) {         // first sample after coming online
            memcpy(util_last[i], cur[i], sizeof(cur[i]));
            util_valid[i] = 1;
            fputs("NA\t", fp);
            continue;
        }
        for (j = 0; j < NUM_STAT_FIELDS; j++) {
            d[j] = (cur[i][j] >= util_last[i][j]) ? cur[i][j] - util_last[i][j] : 0;
            util_last[i][j] = cur[i][j];
            total += d[j];
        }
        active = d[0] + d[1] + d[2] + d[5] + d[6] + d[7];   // exclude idle, iowait
        if (total == 0)
            fputs("0\t", fp);
        else
            fprintf(fp, "%.2f\t", active * 100.0 / total);
    }
}

// MIF_Freq : bus_dcvs/DDR/cur_freq (kHz) -> GHz
static void write_mif_freq(FILE *fp)
{
    write_scaled(fp, "/sys/devices/system/cpu/bus_dcvs/DDR/cur_freq", 1e6, 4);
}

// GPU_Freq : kgsl gpuclk (Hz) -> GHz
static void write_gpu_freq(FILE *fp)
{
    write_scaled(fp, "/sys/class/kgsl/kgsl-3d0/gpuclk", 1e9, 4);
}

// GPU_util : kgsl gpu_busy_percentage (%)
static void write_gpu_util(FILE *fp)
{
    write_scaled(fp, "/sys/class/kgsl/kgsl-3d0/gpu_busy_percentage", 1.0, 0);
}

// LIT0_temp ... skin-msm-therm_temp : max over each unit's sensors (kept: single sensors miss transient spikes, survey 2026-11-10), mdegC -> degC (lossless, 3 decimals)
static void write_temp(FILE *fp)
{
    char path[128];
    int g, i;
    for (g = 0; g < NUM_TEMP_GROUPS; g++) {
        long long t, max = 0;
        int found = 0;
        for (i = 0; i < TEMP_GROUP[g].count; i++) {
            snprintf(path, sizeof(path), "/sys/class/thermal/thermal_zone%d/temp", TEMP_GROUP[g].zones[i]);
            if (read_long(path, &t) == 0 && (!found || t > max)) {
                max = t;
                found = 1;
            }
        }
        if (found)
            fprintf(fp, "%.3f\t", max / 1000.0);
        else
            fputs("OFF\t", fp);
    }
}

// LIT_freq_throttling ... BIG_freq_throttling : 1 if the frequency ceiling was lowered
static void write_freq_throttling(FILE *fp)
{
    char path[128];
    int c;
    for (c = 0; c < NUM_CLUSTERS; c++) {
        long long smax, cmax;
        snprintf(path, sizeof(path), "/sys/devices/system/cpu/cpufreq/policy%d/scaling_max_freq", CLUSTER[c].policy);
        if (read_long(path, &smax) != 0) { fputs("OFF\t", fp); continue; }
        snprintf(path, sizeof(path), "/sys/devices/system/cpu/cpufreq/policy%d/cpuinfo_max_freq", CLUSTER[c].policy);
        if (read_long(path, &cmax) != 0) { fputs("OFF\t", fp); continue; }
        fprintf(fp, "%d\t", smax < cmax ? 1 : 0);
    }
}

// cdsp_hw_state ... cdsp_sw_hmx_state : NPU cooling device cur_state
static void write_cdsp_state(FILE *fp)
{
    char path[128];
    int i;
    for (i = 0; i < NUM_CDSP_STATES; i++) {
        snprintf(path, sizeof(path), "/sys/class/thermal/cooling_device%d/cur_state", CDSP_STATE[i].id);
        write_scaled(fp, path, 1.0, 0);
    }
}

// batt_volt : voltage_now (uV) -> mV
static void write_batt_volt(FILE *fp)
{
    write_scaled(fp, "/sys/class/power_supply/battery/voltage_now", 1000.0, 3);
}

// batt_curr : current_now (uA assumed) -> mA
static void write_batt_curr(FILE *fp)
{
    write_scaled(fp, "/sys/class/power_supply/battery/current_now", 1000.0, 3);
}

/* ---------- main ---------- */

int main(int argc, char *argv[])
{
    char fname[256];
    FILE *fp;
    long long duration_ms, btime, ctime, atime;
    long long count = 0;
    struct sigaction sa;

    if (argc < 2) {
        fprintf(stderr, "usage: %s <out_name> [duration_sec]\n", argv[0]);
        return 1;
    }
    duration_ms = (argc >= 3) ? atoll(argv[2]) * 1000 : -1;   // -1: run until killed

    snprintf(fname, sizeof(fname), "%s.txt", argv[1]);
    fp = fopen(fname, "w");
    if (fp == NULL) {
        perror(fname);
        return 1;
    }
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = on_signal;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);

    write_header(fp);
    init_util();

    btime = now_ms();
    atime = btime;
    while (!stop_flag) {
        ctime = now_ms();
        if (btime + SAMPLING_TIME_MS > ctime) {
            usleep((useconds_t)((btime + SAMPLING_TIME_MS - ctime) * 1000));
            ctime = now_ms();
        }

        if (ctime - btime >= SAMPLING_TIME_MS) {
            write_time(fp, count * SAMPLING_TIME_MS);
            write_freq(fp);
            write_util(fp);
            write_mif_freq(fp);
            write_gpu_freq(fp);
            write_gpu_util(fp);
            write_temp(fp);
            write_freq_throttling(fp);
            write_cdsp_state(fp);
            write_batt_volt(fp);
            write_batt_curr(fp);
            fputs("EOL\n", fp);
            fflush(fp);
            btime += SAMPLING_TIME_MS;
            count++;
        }
        if (duration_ms >= 0 && ctime - atime >= duration_ms)
            break;
    }
    fclose(fp);
    return 0;
}