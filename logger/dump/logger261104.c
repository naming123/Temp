/*
 * Lenovo TB321FU (SM8650, Snapdragon 8 Gen 3) sampler
 *
 * CPU policies read from the device:
 *   cpu0-1 : LIT, max 2265600 kHz
 *   cpu2-4 : MID, max 3148800 kHz
 *   cpu5-6 : MID, max 2956800 kHz
 *   cpu7   : BIG, max 3302400 kHz
 *
 * NPU clock and load have no sysfs node on this device; collect them with
 * sysMonApp profiler and align the two logs on the Uptime_ms column.
 *
 * Usage: ./sampler <output name>   -> writes <output name>.txt
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define SAMPLING_TIME 100 /* ms */
#define OP_PERIOD_MS 1000000000L
#define NUM_CPU 8

#define MAX_THERMAL_INDEX 512
#define MAX_COOLING_INDEX 512
#define MAX_SELECTED 128
#define NAME_LEN 64
#define PATH_LEN 256

#define GPU_FREQ_PATH "/sys/class/kgsl/kgsl-3d0/gpuclk"
#define GPU_LOAD_PATH "/sys/class/kgsl/kgsl-3d0/gpu_busy_percentage"
#define DDR_FREQ_PATH "/sys/devices/system/cpu/bus_dcvs/DDR/cur_freq"
#define BATT_VOLT_PATH "/sys/class/power_supply/battery/voltage_now"
#define BATT_CURR_PATH "/sys/class/power_supply/battery/current_now"

typedef unsigned long long u64;

struct node {
	char name[NAME_LEN];
	char path[PATH_LEN];
};

static const char *cpu_label[NUM_CPU] = {
	"LIT0", "LIT1", "MID2", "MID3", "MID4", "MID5", "MID6", "BIG7"
};

/* Thermal zones to log. nsphvx and nsphmx are the NPU sensors. */
static const char *zone_prefix[] = {
	"cpu-", "cpuss-", "gpuss-", "nsphvx-", "nsphmx-", NULL
};
static const char *zone_exact[] = { "ddr", "skin-msm-therm", NULL };

/* Cooling devices to log. cdsp* are the NPU devices. */
static const char *cooling_exact[] = {
	"cpufreq-cpu0", "cpufreq-cpu2", "cpufreq-cpu5", "cpufreq-cpu7",
	"cpu-cluster0", "cpu-cluster1", "cpu-cluster2", "cpu-cluster3",
	"devfreq-3d00000.qcom,kgsl-3d0", "gpu", "ddr-cdev",
	"cdsp_hw", "cdsp", "cdsp_sw_hvx", "cdsp_sw_hmx", NULL
};

static struct node zones[MAX_SELECTED];
static int num_zones;
static struct node coolings[MAX_SELECTED];
static int num_coolings;

static u64 last_stat[NUM_CPU][10];

static void find_nodes(void);
static void write_header(FILE *fp);
static void write_freq(FILE *fp);
static void write_util(FILE *fp);
static void write_bus(FILE *fp);
static void write_gpu(FILE *fp);
static void write_temp(FILE *fp);
static void write_battery(FILE *fp);
static void write_governor(FILE *fp);

static long elapsed_ms(const struct timespec *from, const struct timespec *to)
{
	return (to->tv_sec - from->tv_sec) * 1000L +
	       (to->tv_nsec - from->tv_nsec) / 1000000L;
}

static void add_ms(struct timespec *t, long ms)
{
	t->tv_sec += ms / 1000;
	t->tv_nsec += (ms % 1000) * 1000000L;
	if (t->tv_nsec >= 1000000000L) {
		t->tv_sec++;
		t->tv_nsec -= 1000000000L;
	}
}

static int is_after(const struct timespec *a, const struct timespec *b)
{
	if (a->tv_sec != b->tv_sec)
		return a->tv_sec > b->tv_sec;
	return a->tv_nsec > b->tv_nsec;
}

/* Returns 1 on success. Parses the leading number, so "37 %" reads as 37. */
static int read_long(const char *path, long *value)
{
	FILE *buf = fopen(path, "r");
	int ok;

	if (buf == NULL)
		return 0;
	ok = (fscanf(buf, "%ld", value) == 1);
	fclose(buf);
	return ok;
}

static int read_word(const char *path, char *value, const char *format)
{
	FILE *buf = fopen(path, "r");
	int ok;

	if (buf == NULL)
		return 0;
	ok = (fscanf(buf, format, value) == 1);
	fclose(buf);
	return ok;
}

static void write_long_or_off(FILE *fp, const char *path)
{
	long value;

	if (read_long(path, &value))
		fprintf(fp, "%ld\t", value);
	else
		fprintf(fp, "OFF\t");
}

int main(int argc, char *argv[])
{
	struct timespec start, next, now, uptime;
	char fname[PATH_LEN];
	FILE *fp;

	if (argc < 2) {
		fprintf(stderr, "Usage: %s <output name>\n", argv[0]);
		return 1;
	}

	snprintf(fname, sizeof(fname), "%s.txt", argv[1]);
	fp = fopen(fname, "w");
	if (fp == NULL) {
		perror(fname);
		return 1;
	}

	find_nodes();
	write_header(fp);

	/* Set the baseline so the first row is not the average since boot */
	{
		FILE *null_fp = fopen("/dev/null", "w");

		if (null_fp != NULL) {
			write_util(null_fp);
			fclose(null_fp);
		}
	}

	clock_gettime(CLOCK_MONOTONIC, &start);
	next = start;

	while (1) {
		add_ms(&next, SAMPLING_TIME);
		clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &next, NULL);

		clock_gettime(CLOCK_MONOTONIC, &now);
		clock_gettime(CLOCK_BOOTTIME, &uptime);
		fprintf(fp, "%ld\t%lld\t", elapsed_ms(&start, &now),
			(long long)uptime.tv_sec * 1000LL + uptime.tv_nsec / 1000000L);

		write_freq(fp);
		write_util(fp);
		write_bus(fp);
		write_gpu(fp);
		write_temp(fp);
		write_battery(fp);
		write_governor(fp);
		fprintf(fp, "EOL\n");
		fflush(fp);

		clock_gettime(CLOCK_MONOTONIC, &now);

		/* If a sample overran its slot, restart from now instead of bursting */
		if (is_after(&now, &next))
			next = now;

		if (elapsed_ms(&start, &now) > OP_PERIOD_MS)
			break;
	}

	fclose(fp);
	return 0;
}

static int matches_prefix(const char *type, const char **list)
{
	int i;

	for (i = 0; list[i] != NULL; i++) {
		if (strncmp(type, list[i], strlen(list[i])) == 0)
			return 1;
	}
	return 0;
}

static int matches_exact(const char *type, const char **list)
{
	int i;

	for (i = 0; list[i] != NULL; i++) {
		if (strcmp(type, list[i]) == 0)
			return 1;
	}
	return 0;
}

/*
 * Thermal zone and cooling device indexes can differ between builds, so they
 * are selected by type name at startup.
 */
static void find_nodes(void)
{
	char path[PATH_LEN];
	char type[NAME_LEN];
	int i;

	for (i = 0; i < MAX_THERMAL_INDEX && num_zones < MAX_SELECTED; i++) {
		snprintf(path, sizeof(path), "/sys/class/thermal/thermal_zone%d/type", i);
		if (!read_word(path, type, "%63s"))
			continue;
		if (!matches_prefix(type, zone_prefix) && !matches_exact(type, zone_exact))
			continue;
		strcpy(zones[num_zones].name, type);
		snprintf(zones[num_zones].path, PATH_LEN,
			 "/sys/class/thermal/thermal_zone%d/temp", i);
		printf("thermal_zone%d\t%s\n", i, type);
		num_zones++;
	}

	for (i = 0; i < MAX_COOLING_INDEX && num_coolings < MAX_SELECTED; i++) {
		snprintf(path, sizeof(path), "/sys/class/thermal/cooling_device%d/type", i);
		if (!read_word(path, type, "%63s") || !matches_exact(type, cooling_exact))
			continue;
		strcpy(coolings[num_coolings].name, type);
		snprintf(coolings[num_coolings].path, PATH_LEN,
			 "/sys/class/thermal/cooling_device%d/cur_state", i);
		printf("cooling_device%d\t%s\n", i, type);
		num_coolings++;
	}

	printf("Selected %d thermal zones and %d cooling devices\n", num_zones, num_coolings);
	fflush(stdout);
}

static void write_header(FILE *fp)
{
	int i;

	fprintf(fp, "Time\tUptime_ms\t");
	for (i = 0; i < NUM_CPU; i++)
		fprintf(fp, "%s_freq\t", cpu_label[i]);
	for (i = 0; i < NUM_CPU; i++)
		fprintf(fp, "%s_util\t", cpu_label[i]);
	fprintf(fp, "DDR_Freq\tGPU_Freq\tGPU_Load\t");
	for (i = 0; i < num_zones; i++)
		fprintf(fp, "%s\t", zones[i].name);
	for (i = 0; i < num_coolings; i++)
		fprintf(fp, "%s_state\t", coolings[i].name);
	fprintf(fp, "batt_volt\tbatt_curr\t");
	for (i = 0; i < NUM_CPU; i++)
		fprintf(fp, "%s_governor\t", cpu_label[i]);
	fprintf(fp, "EOL\n");
	fflush(fp);
}

static void write_freq(FILE *fp)
{
	char path[PATH_LEN];
	int i;

	for (i = 0; i < NUM_CPU; i++) {
		snprintf(path, sizeof(path),
			 "/sys/devices/system/cpu/cpu%d/cpufreq/scaling_cur_freq", i);
		write_long_or_off(fp, path);
	}
}

static void write_governor(FILE *fp)
{
	char path[PATH_LEN];
	char governor[64];
	int i;

	for (i = 0; i < NUM_CPU; i++) {
		snprintf(path, sizeof(path),
			 "/sys/devices/system/cpu/cpu%d/cpufreq/scaling_governor", i);
		if (read_word(path, governor, "%63s"))
			fprintf(fp, "%s\t", governor);
		else
			fprintf(fp, "OFF\t");
	}
}

/* /proc/stat omits offline CPUs, so each line is matched by its CPU number. */
static void write_util(FILE *fp)
{
	FILE *stat_fp;
	char line[256];
	u64 current[NUM_CPU][10];
	int present[NUM_CPU] = { 0 };
	int i, j;

	stat_fp = fopen("/proc/stat", "r");
	if (stat_fp != NULL) {
		while (fgets(line, sizeof(line), stat_fp)) {
			int cpu;
			u64 v[10] = { 0 };

			if (strncmp(line, "cpu", 3) != 0)
				break;
			if (sscanf(line,
				   "cpu%d %llu %llu %llu %llu %llu %llu %llu %llu %llu %llu",
				   &cpu, &v[0], &v[1], &v[2], &v[3], &v[4],
				   &v[5], &v[6], &v[7], &v[8], &v[9]) < 5)
				continue;
			if (cpu < 0 || cpu >= NUM_CPU)
				continue;
			memcpy(current[cpu], v, sizeof(v));
			present[cpu] = 1;
		}
		fclose(stat_fp);
	}

	for (i = 0; i < NUM_CPU; i++) {
		u64 diff[10];
		u64 total_diff = 0;
		u64 active_diff;

		if (!present[i]) {
			fprintf(fp, "OFF\t");
			continue;
		}

		for (j = 0; j < 10; j++) {
			diff[j] = (current[i][j] < last_stat[i][j]) ?
				  0 : current[i][j] - last_stat[i][j];
			last_stat[i][j] = current[i][j];
			total_diff += diff[j];
		}

		if (total_diff == 0) {
			fprintf(fp, "0\t");
		} else {
			active_diff = diff[0] + diff[1] + diff[2] +
				      diff[5] + diff[6] + diff[7];
			fprintf(fp, "%llu\t", (active_diff * 100) / total_diff);
		}
	}
}

static void write_temp(FILE *fp)
{
	int i;

	for (i = 0; i < num_zones; i++)
		write_long_or_off(fp, zones[i].path);
	for (i = 0; i < num_coolings; i++)
		write_long_or_off(fp, coolings[i].path);
}

static void write_gpu(FILE *fp)
{
	long freq_hz;

	if (read_long(GPU_FREQ_PATH, &freq_hz))
		fprintf(fp, "%ld\t", freq_hz / 1000000); /* Hz -> MHz */
	else
		fprintf(fp, "OFF\t");

	write_long_or_off(fp, GPU_LOAD_PATH);
}

static void write_battery(FILE *fp)
{
	write_long_or_off(fp, BATT_VOLT_PATH);
	write_long_or_off(fp, BATT_CURR_PATH);
}

static void write_bus(FILE *fp)
{
	write_long_or_off(fp, DDR_FREQ_PATH);
}