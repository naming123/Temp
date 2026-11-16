#!/system/bin/sh

root=/data/local/tmp/wooseok/hpca/profiling
duration="${1:-370}"

export ADSP_LIBRARY_PATH="/vendor/dsp/cdsp;/vendor/dsp/adsp;/vendor/lib/rfsa/adsp;/system/lib/rfsa/adsp;/dsp"
export CDSP_LIBRARY_PATH="$ADSP_LIBRARY_PATH"

rm -f /sdcard/sysmon_cdsp.bin
cd "$root" || exit 1
exec ./sysMonApp profiler \
  --q6 cdsp \
  --privileged 1 \
  --samplingPeriod 100 \
  --duration "$duration" \
  --profileFastrpcTimeline 0
