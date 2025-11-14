#!/bin/bash
################################################################################
# FFmpeg Windows x64 Build Script - AMD AMF Proxy Approach
# Version 46.26 - vmixproxy.sh (Configurable heuristics + AMF extras)
# Updated: compact header and child PID logging
################################################################################

if [ -z "$BASH_VERSION" ]; then
  echo "ERROR: This script requires bash"
  exit 1
fi

set -e
set -o pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Performance configs
BUILD_THREADS=${BUILD_THREADS:-$(nproc)}   # configurable threads
export PATH="/usr/lib/ccache:$PATH"        # enable ccache if installed

# Heuristics env vars (defaults)
AMF_BPS_REF=${AMF_BPS_REF:-6}                 # Mbps reference (default 6 Mbps for 1080p60)
AMF_CRF_REF=${AMF_CRF_REF:-23}                # reference CRF
AMF_MAXRATE_FACTOR=${AMF_MAXRATE_FACTOR:-1.2} # default maxrate factor
AMF_BUFSIZE_FACTOR=${AMF_BUFSIZE_FACTOR:-1.5} # default bufsize factor
AMF_MIN_BPS=${AMF_MIN_BPS:-1500000}           # floor in bps (1.5 Mbps)
AMF_DRYRUN=${AMF_DRYRUN:-0}                   # if 1, print final command and exit (no exec)

# AMF extras controls (either list in AMF_SUPPORTED_FLAGS or individual flags)
# Example: export AMF_SUPPORTED_FLAGS="minqp,maxqp,aud"
AMF_SUPPORTED_FLAGS=${AMF_SUPPORTED_FLAGS:-""}
AMF_ENABLE_MINQP=${AMF_ENABLE_MINQP:-0}
AMF_ENABLE_MAXQP=${AMF_ENABLE_MAXQP:-0}
AMF_ENABLE_AUD=${AMF_ENABLE_AUD:-0}

# Absolute path for proxy log file (Windows path string literal used in proxy too)
LOG_PATH='C:\ProgramData\vMix\streaming\ffmpegproxy.log'

# Logging functions
log_section() {
  echo ""
  echo "════════════════════════════════════════════════════════════════════════════"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
  echo "════════════════════════════════════════════════════════════════════════════"
  echo ""
}

log_step() {
  echo -e "${CYAN}[$1]${NC} ${YELLOW}$2${NC}"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$1] $2" >> "$LOG_PATH"
}

log_success() {
  echo -e "${GREEN}  ✓ $1${NC}"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] SUCCESS: $1" >> "$LOG_PATH"
}

log_error() {
  echo -e "${RED}  ✗ $1${NC}"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >> "$LOG_PATH"
}

log_info() {
  echo -e "${BLUE}  → $1${NC}"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $1" >> "$LOG_PATH"
}

log_proxy_start() {
  echo "" >> "$LOG_PATH"
  echo "════════════════════════════════════════════════════════════════════════════" >> "$LOG_PATH"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] PROXY STARTED (build 46.26)" >> "$LOG_PATH"
  echo "════════════════════════════════════════════════════════════════════════════" >> "$LOG_PATH"
  echo "" >> "$LOG_PATH"
}

log_proxy_end() {
  echo "" >> "$LOG_PATH"
  echo "════════════════════════════════════════════════════════════════════════════" >> "$LOG_PATH"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] PROXY ENDED" >> "$LOG_PATH"
  echo "════════════════════════════════════════════════════════════════════════════" >> "$LOG_PATH"
  echo "" >> "$LOG_PATH"
}

# Start banner
log_proxy_start
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo -e "${GREEN}FFmpeg Builder v46.26 - vmixproxy.sh${NC}"
echo -e "${GREEN}vMix → ffmpeg6.exe → ffmpeg.exe${NC}"
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo ""

WORKDIR="$(pwd)"
OUTPUT_DIR="$WORKDIR/output"
PREFIX="$OUTPUT_DIR/build_static"
TARGET_ARCH="x86_64-w64-mingw32"

> "$LOG_PATH"
mkdir -p "$OUTPUT_DIR" "$OUTPUT_DIR/logs" "$PREFIX" "$WORKDIR/sources"

log_step "1/6" "Checking dependencies..."
DEPS_NEEDED=""
for dep in git pkg-config autoconf automake libtool yasm nasm cmake ccache; do
  command -v "$dep" &>/dev/null || DEPS_NEEDED="$DEPS_NEEDED $dep"
done
if ! command -v ${TARGET_ARCH}-gcc &>/dev/null; then
  DEPS_NEEDED="$DEPS_NEEDED mingw-w64"
fi
if [ -n "$DEPS_NEEDED" ]; then
  log_info "Installing:$DEPS_NEEDED"
  sudo apt-get update
  sudo apt-get install -y build-essential $DEPS_NEEDED
fi
log_success "Dependencies OK"

# Step 2: AMD AMF SDK
log_step "2/6" "AMD AMF SDK..."
if [ ! -d "$WORKDIR/AMF" ]; then
  git clone --depth 1 https://github.com/GPUOpen-LibrariesAndSDKs/AMF.git "$WORKDIR/AMF"
fi
AMF_PATH="$WORKDIR/AMF/amf/public/include"
cd "$AMF_PATH" && [ ! -e "AMF" ] && ln -s . AMF 2>/dev/null || true
log_success "AMF SDK ready"

# Step 3: FFmpeg master
log_step "3/6" "FFmpeg master..."
if [ ! -d "$WORKDIR/ffmpeg" ]; then
  git clone --depth 1 https://github.com/FFmpeg/FFmpeg.git "$WORKDIR/ffmpeg"
else
  cd "$WORKDIR/ffmpeg"
  git fetch origin
  git reset --hard origin/master
fi
cd "$WORKDIR/ffmpeg"
FFMPEG_COMMIT=$(git rev-parse --short HEAD)
log_success "FFmpeg: $FFMPEG_COMMIT"

# Step 4: FDK-AAC
log_step "4/6" "FDK-AAC..."
if [ -f "$PREFIX/lib/libfdk-aac.a" ] && [ -f "$PREFIX/include/fdk-aac/aacenc_lib.h" ]; then
  log_info "FDK-AAC already installed, skipping build"
else
  log_info "Building FDK-AAC..."
  if [ ! -d "$WORKDIR/sources/fdk-aac" ]; then
    cd "$WORKDIR/sources"
    git clone --depth 1 https://github.com/mstorsjo/fdk-aac.git
  fi
  cd "$WORKDIR/sources/fdk-aac"
  make distclean 2>/dev/null || true
  ./autogen.sh
  ./configure --host="$TARGET_ARCH" --prefix="$PREFIX" --disable-shared --enable-static
  make -j"$BUILD_THREADS"
  make install
fi
if [ ! -f "$PREFIX/lib/libfdk-aac.a" ]; then
  log_error "FDK-AAC build failed"
  exit 1
fi
if [ ! -f "$PREFIX/include/fdk-aac/aacenc_lib.h" ]; then
  log_error "FDK-AAC headers missing"
  exit 1
fi
FDK_SIZE=$(du -h "$PREFIX/lib/libfdk-aac.a" | cut -f1)
log_success "FDK-AAC installed: $FDK_SIZE"

# Step 5: Build FFmpeg
log_step "5/6" "Building FFmpeg (AMF only)..."
cd "$WORKDIR/ffmpeg"
make distclean 2>/dev/null || true

CONFIGURE_LOG="$OUTPUT_DIR/logs/configure.log"
> "$CONFIGURE_LOG"

AMF_FLAGS="-I$AMF_PATH -I$AMF_PATH/core -I$AMF_PATH/components"
PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" ./configure \
  --arch=x86_64 \
  --target-os=mingw32 \
  --cross-prefix="$TARGET_ARCH-" \
  --prefix="$PREFIX" \
  --enable-cross-compile \
  --enable-gpl \
  --enable-nonfree \
  --enable-version3 \
  --disable-debug \
  --disable-doc \
  --disable-shared \
  --enable-static \
  --enable-runtime-cpudetect \
  --enable-amf \
  --enable-libfdk-aac \
  --extra-cflags="$AMF_FLAGS -I$PREFIX/include -DWIN32_LEAN_AND_MEAN -O3" \
  --extra-cxxflags="$AMF_FLAGS -I$PREFIX/include -DWIN32_LEAN_AND_MEAN -O3" \
  --extra-ldflags="-L$PREFIX/lib -static -static-libgcc" \
  2>&1 | tee "$CONFIGURE_LOG"

if [ ${PIPESTATUS[0]} -ne 0 ]; then
  log_error "Configure failed"
  tail -n 30 "$CONFIGURE_LOG"
  exit 1
fi

log_success "Configure OK"

if ! grep -q "CONFIG_H264_AMF_ENCODER=yes" ffbuild/config.mak 2>/dev/null; then
  log_error "h264_amf not enabled"
  exit 1
fi

BUILD_LOG="$OUTPUT_DIR/logs/build.log"
> "$BUILD_LOG"

log_info "Building (threads: $BUILD_THREADS)..."
make -j"$BUILD_THREADS" 2>&1 | tee "$BUILD_LOG"

if [ ${PIPESTATUS[0]} -ne 0 ]; then
  log_error "Build failed"
  tail -n 50 "$BUILD_LOG"
  exit 1
fi

log_success "Build OK"

if [ ! -f ffmpeg.exe ]; then
  log_error "ffmpeg.exe not generated"
  exit 1
fi

FFMPEG_SIZE=$(du -h ffmpeg.exe | cut -f1)
cp ffmpeg.exe "$OUTPUT_DIR/ffmpeg.exe"
log_success "ffmpeg.exe: $FFMPEG_SIZE (with h264_amf)"
if [ -f ffprobe.exe ]; then
  cp ffprobe.exe "$OUTPUT_DIR/ffprobe.exe"
fi

# Step 6: Create ffmpeg6.exe (proxy) with configurable heuristics and AMF extras
log_step "6/6" "Creating ffmpeg6.exe (proxy)..."

PROXY_SOURCE="$WORKDIR/ffmpeg_proxy.c"

cat > "$PROXY_SOURCE" << 'PROXY_CODE'
/*
 * FFmpeg Proxy v46.26
 * Name: ffmpeg6.exe
 * Calls: ffmpeg.exe (in the same directory)
 * Features:
 *  - Advanced x264->AMF mapping for streaming
 *  - Heuristics configurable via env vars
 *  - Compact header log (overwrite per-execution) and child PID logging
 */

#include <windows.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <ctype.h>
#include <time.h>

#define MAX_ARGS 512
#define MAX_CMD 65536

const char *LOG_PATH = "C:\\ProgramData\\vMix\\streaming\\ffmpegproxy.log";

/* Helpers to read env vars with defaults (returns integer) */
static int env_int_default(const char *name, int dflt) {
  const char *v = getenv(name);
  if (!v) return dflt;
  return atoi(v);
}

/* Helpers to read double env var default */
static double env_double_default(const char *name, double dflt) {
  const char *v = getenv(name);
  if (!v) return dflt;
  return atof(v);
}

/* Check if a comma-separated flag exists in AMF_SUPPORTED_FLAGS */
static int supported_flag(const char *flag) {
  const char *list = getenv("AMF_SUPPORTED_FLAGS");
  if (!list) return 0;
  const char *p = list;
  size_t fl = strlen(flag);
  while (*p) {
    while (*p == ' ' || *p == ',') p++;
    if (*p == 0) break;
    const char *q = p;
    while (*q && *q != ',') q++;
    size_t len = q - p;
    if (len == fl && _strnicmp(p, flag, fl) == 0) return 1;
    p = q;
    if (*p == ',') p++;
  }
  return 0;
}

/* Truncate/initialize log file at process start and write compact execution header */
static void init_log_and_header(int argc, char *argv[]) {
  FILE *log = fopen(LOG_PATH, "w"); /* overwrite previous execution */
  if (!log) return;

  /* Time */
  time_t t = time(NULL);
  struct tm tm;
  localtime_s(&tm, &t);

  /* PID */
  DWORD pid = GetCurrentProcessId();

  /* Username (fallback to unknown) */
  char username[128] = "unknown";
  DWORD uname_len = sizeof(username);
  if (!GetUserNameA(username, &uname_len)) {
    strncpy(username, "unknown", sizeof(username));
    username[sizeof(username)-1] = '\0';
  }

  /* Relevant AMF_* env vars to include (print only if set) */
  const char *envs[] = {
    "AMF_BPS_REF", "AMF_CRF_REF", "AMF_MAXRATE_FACTOR",
    "AMF_BUFSIZE_FACTOR", "AMF_MIN_BPS", "AMF_DRYRUN",
    "AMF_LATENCY_MODE", "AMF_SUPPORTED_FLAGS",
    "AMF_ENABLE_MINQP", "AMF_ENABLE_MAXQP", "AMF_ENABLE_AUD",
    NULL
  };

  /* Header: compact single block */
  fprintf(log, "==== FFmpeg Proxy v46.26 Start ====\n");
  fprintf(log, "Start: %04d-%02d-%02d %02d:%02d:%02d  PID:%lu  User:%s\n",
          tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday,
          tm.tm_hour, tm.tm_min, tm.tm_sec, (unsigned long)pid, username);

  /* Print env vars compactly: NAME=VALUE; separated by semicolon */
  int first = 1;
  for (int i = 0; envs[i] != NULL; i++) {
    const char *v = getenv(envs[i]);
    if (v) {
      if (!first) fprintf(log, "; ");
      fprintf(log, "%s=%s", envs[i], v);
      first = 0;
    }
  }
  if (first) fprintf(log, "(no AMF envs set)");
  fprintf(log, "\n");

  /* Original command line on single line (quoted minimal) */
  fprintf(log, "Cmd:");
  for (int i = 0; i < argc; i++) {
    int needs_quote = (strchr(argv[i], ' ') != NULL) || (strchr(argv[i], ':') != NULL);
    if (needs_quote) fprintf(log, " \"%s\"", argv[i]);
    else fprintf(log, " %s", argv[i]);
  }
  fprintf(log, "\n====================================\n");

  fclose(log);
}

/* Simple helper to append a timestamped message to the log (append mode) */
static void log_message(const char *msg) {
  FILE *log = fopen(LOG_PATH, "a");
  if (log) {
    SYSTEMTIME st;
    GetLocalTime(&st);
    fprintf(log, "[%02d:%02d:%02d.%03d] %s\n",
            st.wHour, st.wMinute, st.wSecond, st.wMilliseconds, msg);
    fclose(log);
  }
}

/* Append child PID info to log (append mode) */
static void log_child_pid(DWORD child_pid) {
  FILE *log = fopen(LOG_PATH, "a");
  if (log) {
    SYSTEMTIME st;
    GetLocalTime(&st);
    fprintf(log, "[%02d:%02d:%02d.%03d] Child ffmpeg PID: %lu\n",
            st.wHour, st.wMinute, st.wSecond, st.wMilliseconds, (unsigned long)child_pid);
    fclose(log);
  }
}

/* Case-insensitive substring check */
static int contains_ci(const char *hay, const char *needle) {
  if (!hay || !needle) return 0;
  const char *p = hay;
  size_t nl = strlen(needle);
  while (*p) {
    if (_strnicmp(p, needle, nl) == 0) return 1;
    p++;
  }
  return 0;
}

/* Parse resolution WxH string */
static void parse_resolution(const char *s, int *w, int *h) {
  if (!s || !w || !h) return;
  int W = 0, H = 0;
  if (sscanf(s, "%dx%d", &W, &H) == 2 && W > 0 && H > 0) {
    *w = W; *h = H;
  }
}

/* Compute bitrate (bps) from CRF, using environment-configurable heuristics */
static int compute_bitrate_from_crf_env(int crf, int width, int height, double fps) {
  double ref_mbps = env_double_default("AMF_BPS_REF", 6.0);      // Mbps
  double crf_ref = env_double_default("AMF_CRF_REF", 23.0);
  double maxrate_factor = env_double_default("AMF_MAXRATE_FACTOR", 1.2);
  double bufsize_factor = env_double_default("AMF_BUFSIZE_FACTOR", 1.5);
  double min_bps = (double)env_int_default("AMF_MIN_BPS", 1500000);

  double ref_pixels = 1920.0 * 1080.0 * 60.0; // reference: 1080p60
  double cur_pixels = (double)width * (double)height * (fps > 0.0 ? fps : 30.0);
  double scale = cur_pixels / ref_pixels;
  double crf_factor = 1.0 + (crf_ref - crf) * 0.05;
  if (crf_factor < 0.5) crf_factor = 0.5;
  if (crf_factor > 1.5) crf_factor = 1.5;
  double mbps = ref_mbps * scale * crf_factor;
  if (mbps < (min_bps / 1000000.0)) mbps = (min_bps / 1000000.0);
  int bps = (int)(mbps * 1000000.0);
  return bps;
}

/* Detect streaming context (enhanced) */
static int is_streaming_target(int argc, char *argv[], char *reason, size_t reason_len) {
  const char *stream_formats[] = {"flv", "mpegts", "rtmp", "srt", "rtsp", "rtmp_flv", NULL};
  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "-f") == 0 && i + 1 < argc) {
      const char *fmt = argv[i+1];
      for (int k = 0; stream_formats[k] != NULL; k++) {
        if (_strnicmp(fmt, stream_formats[k], strlen(stream_formats[k])) == 0) {
          snprintf(reason, reason_len, "format=%s", fmt);
          return 1;
        }
      }
    }
    if (contains_ci(argv[i], "rtmp://") || contains_ci(argv[i], "srt://") || contains_ci(argv[i], "rtsp://")) {
      snprintf(reason, reason_len, "url=%s", argv[i]);
      return 1;
    }
    if (strstr(argv[i], ":1935") || strstr(argv[i], ":9000") || strstr(argv[i], ":80") || strstr(argv[i], ":443")) {
      snprintf(reason, reason_len, "dest_has_port=%s", argv[i]);
      return 1;
    }
  }
  snprintf(reason, reason_len, "default_assume_streaming");
  return 1;
}

/* Main */
int main(int argc, char *argv[]) {
  char *new_args[MAX_ARGS];
  int new_argc = 0;
  char cmdline[MAX_CMD] = {0};
  char exe_path[MAX_PATH];
  char exe_dir[MAX_PATH];
  char ffmpeg_real[MAX_PATH];
  int i;

  /* Initialize log (truncate and write compact header with envs and original argv) */
  init_log_and_header(argc, argv);

  log_message("Proxy v46.26 start");

  GetModuleFileNameA(NULL, exe_path, MAX_PATH);
  strcpy(exe_dir, exe_path);
  char *last_slash = strrchr(exe_dir, '\\');
  if (last_slash) *last_slash = 0;
  snprintf(ffmpeg_real, MAX_PATH, "%s\\ffmpeg.exe", exe_dir);

  /* Early detection */
  char detect_reason[256] = {0};
  int is_streaming = is_streaming_target(argc, argv, detect_reason, sizeof(detect_reason));
  char buf[512];
  snprintf(buf, sizeof(buf), "Streaming detection -> %s (reason: %s)", is_streaming ? "YES" : "NO", detect_reason);
  log_message(buf);

  /* Latency override env */
  const char *env_latency = getenv("AMF_LATENCY_MODE"); // auto|low|normal
  if (env_latency) {
    snprintf(buf, sizeof(buf), "AMF_LATENCY_MODE=%s", env_latency);
    log_message(buf);
  }

  /* Configurable AMF extras */
  int want_minqp = 0, want_maxqp = 0, want_aud = 0;
  if (supported_flag("minqp") || getenv("AMF_ENABLE_MINQP")) want_minqp = 1;
  if (supported_flag("maxqp") || getenv("AMF_ENABLE_MAXQP")) want_maxqp = 1;
  if (supported_flag("aud") || getenv("AMF_ENABLE_AUD")) want_aud = 1;
  if (want_minqp) log_message("AMF extra enabled: minqp");
  if (want_maxqp) log_message("AMF extra enabled: maxqp");
  if (want_aud) log_message("AMF extra enabled: aud");

  /* Heuristics env debugging */
  char hv[256];
  snprintf(hv, sizeof(hv), "Heuristics: AMF_BPS_REF=%s AMF_MAXRATE_FACTOR=%s AMF_BUFSIZE_FACTOR=%s AMF_MIN_BPS=%s",
           getenv("AMF_BPS_REF")?getenv("AMF_BPS_REF"):"(default)",
           getenv("AMF_MAXRATE_FACTOR")?getenv("AMF_MAXRATE_FACTOR"):"(default)",
           getenv("AMF_BUFSIZE_FACTOR")?getenv("AMF_BUFSIZE_FACTOR"):"(default)",
           getenv("AMF_MIN_BPS")?getenv("AMF_MIN_BPS"):"(default)");
  log_message(hv);

  /* Collect some state from args (first pass) */
  int converted = 0;
  const char *preset_value = NULL;
  const char *profile_value = NULL;
  int user_set_gop = 0;
  int rate_control_set = 0;
  int width = 1280, height = 720;
  double fps = 30.0;
  int explicit_bitrate_bps = 0;

  for (i = 1; i < argc; i++) {
    char *a = argv[i];
    if ((strcmp(a, "-codec:v") == 0 || strcmp(a, "-c:v") == 0) && i+1 < argc) {
      if (strcmp(argv[i+1], "libx264") == 0) { converted = 1; i++; continue; }
    }
    if ((strcmp(a, "-preset") == 0 || strcmp(a, "-preset:v") == 0) && i+1 < argc) {
      preset_value = argv[i+1]; i++; continue;
    }
    if ((strcmp(a, "-profile") == 0 || strcmp(a, "-profile:v") == 0) && i+1 < argc) {
      profile_value = argv[i+1]; i++; continue;
    }
    if (strcmp(a, "-g") == 0 && i+1 < argc) {
      user_set_gop = 1; i++; continue;
    }
    if (strcmp(a, "-b:v") == 0 && i+1 < argc) {
      const char *val = argv[i+1];
      long long bps = atoll(val);
      if (strchr(val, 'k') || strchr(val, 'K')) bps = (long long)(atof(val) * 1000.0);
      else if (strchr(val, 'M') || strchr(val, 'm')) bps = (long long)(atof(val) * 1000000.0);
      if (bps > 0) explicit_bitrate_bps = (int)bps;
      i++; continue;
    }
    if (strcmp(a, "-r") == 0 && i+1 < argc) {
      fps = atof(argv[i+1]); i++; continue;
    }
    if (strcmp(a, "-s") == 0 && i+1 < argc) {
      parse_resolution(argv[i+1], &width, &height); i++; continue;
    }
    if (strcmp(a, "-crf") == 0 && i+1 < argc) { /* keep for mapping later */ i++; continue; }
  }

  /* Second pass: build new args and apply mapping */
  new_args[new_argc++] = "ffmpeg.exe";
  for (i = 1; i < argc; i++) {
    char *a = argv[i];
    if ((strcmp(a, "-codec:v") == 0 || strcmp(a, "-c:v") == 0) && i+1 < argc) {
      if (strcmp(argv[i+1], "libx264") == 0) {
        new_args[new_argc++] = "-c:v";
        new_args[new_argc++] = "h264_amf";
        i++;
        continue;
      }
    }
    /* skip original preset/profile; handled below */
    if ((strcmp(a, "-preset") == 0 || strcmp(a, "-preset:v") == 0) && i+1 < argc) { i++; continue; }
    if ((strcmp(a, "-profile") == 0 || strcmp(a, "-profile:v") == 0) && i+1 < argc) { i++; continue; }

    /* CRF -> compute bps using env-configurable heuristics */
    if (strcmp(a, "-crf") == 0 && i+1 < argc) {
      int crf = atoi(argv[i+1]);
      int bps = compute_bitrate_from_crf_env(crf, width, height, fps);
      char bstr[32]; snprintf(bstr, sizeof(bstr), "%d", bps);
      new_args[new_argc++] = "-b:v"; new_args[new_argc++] = _strdup(bstr);
      char maxstr[32], bufstr[32];
      snprintf(maxstr, sizeof(maxstr), "%d", (int)(bps * env_double_default("AMF_MAXRATE_FACTOR", 1.2)));
      snprintf(bufstr, sizeof(bufstr), "%d", (int)(bps * env_double_default("AMF_BUFSIZE_FACTOR", 1.5)));
      new_args[new_argc++] = "-maxrate"; new_args[new_argc++] = _strdup(maxstr);
      new_args[new_argc++] = "-bufsize"; new_args[new_argc++] = _strdup(bufstr);
      new_args[new_argc++] = "-rc"; new_args[new_argc++] = "vbr";
      rate_control_set = 1;
      i++; continue;
    }

    /* explicit bitrate -> enforce CBR with strict VBV */
    if (strcmp(a, "-b:v") == 0 && i+1 < argc) {
      new_args[new_argc++] = "-b:v"; new_args[new_argc++] = argv[i+1];
      const char *val = argv[i+1];
      long long bps = atoll(val);
      if (strchr(val, 'k') || strchr(val, 'K')) bps = (long long)(atof(val) * 1000.0);
      else if (strchr(val, 'M') || strchr(val, 'm')) bps = (long long)(atof(val) * 1000000.0);
      if (bps > 0) {
        char maxstr[32], bufstr[32];
        snprintf(maxstr, sizeof(maxstr), "%lld", bps);
        snprintf(bufstr, sizeof(bufstr), "%lld", bps * 2LL);
        new_args[new_argc++] = "-maxrate"; new_args[new_argc++] = _strdup(maxstr);
        new_args[new_argc++] = "-bufsize"; new_args[new_argc++] = _strdup(bufstr);
      }
      new_args[new_argc++] = "-rc"; new_args[new_argc++] = "cbr";
      rate_control_set = 1;
      i++; continue;
    }

    /* pass-through for other args (including -r, -s already handled earlier) */
    new_args[new_argc++] = a;
    if (i + 1 < argc &&
        (strcmp(a, "-r") == 0 || strcmp(a, "-s") == 0 || strcmp(a, "-g") == 0 ||
         strcmp(a, "-maxrate") == 0 || strcmp(a, "-bufsize") == 0)) {
      new_args[new_argc++] = argv[i+1];
      i++;
    }
  }

  /* Apply preset/profile mapping for converted codec */
  if (converted) {
    if (preset_value) {
      if (strncasecmp(preset_value, "ultrafast", 9) == 0 ||
          strncasecmp(preset_value, "superfast", 9) == 0 ||
          strncasecmp(preset_value, "veryfast", 8) == 0) {
        new_args[new_argc++] = "-usage"; new_args[new_argc++] = "lowlatency";
        new_args[new_argc++] = "-quality"; new_args[new_argc++] = "speed";
      } else if (strncasecmp(preset_value, "faster", 6) == 0 ||
                 strncasecmp(preset_value, "fast", 4) == 0) {
        new_args[new_argc++] = "-usage"; new_args[new_argc++] = "lowlatency";
        new_args[new_argc++] = "-quality"; new_args[new_argc++] = "balanced";
      } else if (strncasecmp(preset_value, "medium", 6) == 0) {
        new_args[new_argc++] = "-usage"; new_args[new_argc++] = "transcoding";
        new_args[new_argc++] = "-quality"; new_args[new_argc++] = "balanced";
      } else {
        new_args[new_argc++] = "-usage"; new_args[new_argc++] = "transcoding";
        new_args[new_argc++] = "-quality"; new_args[new_argc++] = "quality";
      }
    } else {
      new_args[new_argc++] = "-usage"; new_args[new_argc++] = "lowlatency";
      new_args[new_argc++] = "-quality"; new_args[new_argc++] = "speed";
    }
  }

  /* Latency decision (env override or auto by detection) */
  int apply_low_latency = 0;
  const char *latency_mode = getenv("AMF_LATENCY_MODE"); /* auto|low|normal */
  if (latency_mode && _stricmp(latency_mode, "low") == 0) apply_low_latency = 1;
  else if (latency_mode && _stricmp(latency_mode, "normal") == 0) apply_low_latency = 0;
  else apply_low_latency = is_streaming;

  if (apply_low_latency) {
    new_args[new_argc++] = "-lowlatency"; new_args[new_argc++] = "1";
    new_args[new_argc++] = "-bf"; new_args[new_argc++] = "0";
    new_args[new_argc++] = "-refs"; new_args[new_argc++] = "1";
  }

  /* Apply AMF extras if enabled */
  if (want_minqp) {
    /* default values; user can override with AMF_MINQP / AMF_MAXQP envs */
    int minqp = env_int_default("AMF_MINQP", 10);
    char sminqp[32]; snprintf(sminqp, sizeof(sminqp), "%d", minqp);
    new_args[new_argc++] = "-minqp"; new_args[new_argc++] = _strdup(sminqp);
  }
  if (want_maxqp) {
    int maxqp = env_int_default("AMF_MAXQP", 51);
    char smaxqp[32]; snprintf(smaxqp, sizeof(smaxqp), "%d", maxqp);
    new_args[new_argc++] = "-maxqp"; new_args[new_argc++] = _strdup(smaxqp);
  }
  if (want_aud) {
    new_args[new_argc++] = "-aud"; new_args[new_argc++] = "1";
  }

  /* Ensure GOP if not user-defined: tie to fps (~2s) */
  int found_g = 0;
  for (i = 0; i < new_argc; i++) if (strcmp(new_args[i], "-g") == 0) found_g = 1;
  if (!found_g) {
    int fps_i = (int)(fps > 0.0 ? fps : 30);
    int gop_value = fps_i * 2;
    char gop_str[16];
    snprintf(gop_str, sizeof(gop_str), "%d", gop_value);
    new_args[new_argc++] = "-g";
    new_args[new_argc++] = _strdup(gop_str);
  }

  /* Ensure rate control exists */
  if (!rate_control_set) {
    int bps = explicit_bitrate_bps > 0 ? explicit_bitrate_bps : compute_bitrate_from_crf_env(23, width, height, fps);
    char b_str[32], mr_str[32], bs_str[32];
    snprintf(b_str, sizeof(b_str), "%d", bps);
    snprintf(mr_str, sizeof(mr_str), "%d", (int)(bps * env_double_default("AMF_MAXRATE_FACTOR", 1.2)));
    snprintf(bs_str, sizeof(bs_str), "%d", (int)(bps * env_double_default("AMF_BUFSIZE_FACTOR", 1.5)));
    new_args[new_argc++] = "-b:v";
    new_args[new_argc++] = _strdup(b_str);
    new_args[new_argc++] = "-maxrate";
    new_args[new_argc++] = _strdup(mr_str);
    new_args[new_argc++] = "-bufsize";
    new_args[new_argc++] = _strdup(bs_str);
    new_args[new_argc++] = "-rc";
    new_args[new_argc++] = "vbr";
  }

  /* Finalize args */
  new_args[new_argc] = NULL;

  /* Log original vs final for debug (append) */
  {
    char lbuf[8192]; int off = snprintf(lbuf, sizeof(lbuf), "Original argv:");
    for (i = 0; i < argc && off < (int)sizeof(lbuf) - 64; i++) off += snprintf(lbuf+off, sizeof(lbuf)-off, " [%s]", argv[i]);
    log_message(lbuf);
  }
  {
    char lbuf[8192]; int off = snprintf(lbuf, sizeof(lbuf), "Final argv:");
    for (i = 0; i < new_argc && off < (int)sizeof(lbuf) - 64; i++) off += snprintf(lbuf+off, sizeof(lbuf)-off, " [%s]", new_args[i]);
    log_message(lbuf);
  }

  /* Build command line with safe quoting and overflow check */
  int pos = 0;
  for (i = 0; i < new_argc && pos < MAX_CMD - 1; i++) {
    if (i > 0) cmdline[pos++] = ' ';
    int needs_quote = strchr(new_args[i], ' ') != NULL || strchr(new_args[i], ':') != NULL;
    if (needs_quote) cmdline[pos++] = '"';
    int len = (int)strlen(new_args[i]);
    if (pos + len >= MAX_CMD - 1) {
      log_message("ERROR: command line too long, truncation prevented");
      fprintf(stderr, "PROXY ERROR: command line too long\n");
      return 1;
    }
    strcpy(&cmdline[pos], new_args[i]);
    pos += len;
    if (needs_quote && pos < MAX_CMD - 1) cmdline[pos++] = '"';
  }
  cmdline[pos] = 0;

  /* Dry run support for debugging heuristics */
  const char *dry = getenv("AMF_DRYRUN");
  if (dry && atoi(dry) == 1) {
    log_message("DRYRUN active: printing final command and exiting");
    printf("DRYRUN: %s\n", cmdline);
    return 0;
  }

  /* Start ffmpeg.exe */
  STARTUPINFOA si; PROCESS_INFORMATION pi;
  ZeroMemory(&si, sizeof(si)); si.cb = sizeof(si);
  ZeroMemory(&pi, sizeof(pi));

  log_message("Starting ffmpeg.exe with translated args");
  if (!CreateProcessA(ffmpeg_real, cmdline, NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi)) {
    DWORD err = GetLastError();
    char ebuf[256]; snprintf(ebuf, sizeof(ebuf), "CreateProcess FAILED: error %lu", err);
    log_message(ebuf);
    fprintf(stderr, "PROXY ERROR: Cannot start ffmpeg.exe (error %lu)\n", err);
    return 1;
  }

  /* Log child PID in the log file */
  log_child_pid(pi.dwProcessId);

  WaitForSingleObject(pi.hProcess, INFINITE);
  DWORD exit_code = 0;
  GetExitCodeProcess(pi.hProcess, &exit_code);
  char xbuf[128]; snprintf(xbuf, sizeof(xbuf), "ffmpeg.exe exited with code %lu", exit_code);
  log_message(xbuf);

  CloseHandle(pi.hProcess);
  CloseHandle(pi.hThread);

  log_message("Proxy v46.26 end");
  return (int)exit_code;
}
PROXY_CODE

log_info "Building proxy..."
${TARGET_ARCH}-gcc -O3 -flto -fomit-frame-pointer -funroll-loops -s \
  -o "$OUTPUT_DIR/ffmpeg6.exe" \
  "$PROXY_SOURCE" \
  -static -static-libgcc

if [ ! -f "$OUTPUT_DIR/ffmpeg6.exe" ]; then
  log_error "ffmpeg6.exe was not generated"
  exit 1
fi

PROXY_SIZE=$(du -h "$OUTPUT_DIR/ffmpeg6.exe" | cut -f1)
log_success "ffmpeg6.exe (proxy): $PROXY_SIZE"

# README
cat > "$OUTPUT_DIR/README.txt" << 'README'
════════════════════════════════════════════════════════════════════════════
FFmpeg v46.26 - AMD AMF Proxy (vmixproxy.sh)
════════════════════════════════════════════════════════════════════════════

CHANGES:
  - Compact header on each execution (overwrites previous log):
      includes Start timestamp, PID, User, AMF_* envs (if set), and original Cmd
  - Child ffmpeg PID is logged after process creation
  - Heuristics configurable via environment variables:
      AMF_BPS_REF (Mbps, default 6)
      AMF_CRF_REF (CRF ref, default 23)
      AMF_MAXRATE_FACTOR (default 1.2)
      AMF_BUFSIZE_FACTOR (default 1.5)
      AMF_MIN_BPS (default 1500000)
      AMF_DRYRUN (if "1", print final command and exit)
  - AMF extras:
      Enable via AMF_SUPPORTED_FLAGS="minqp,maxqp,aud"
      Or set:
        AMF_ENABLE_MINQP=1
        AMF_ENABLE_MAXQP=1
        AMF_ENABLE_AUD=1

USAGE:
  Export any AMF_* env vars before running the proxy or set them in your environment
  on Windows (System Properties) so the proxy reads them when launched.

EXAMPLES:
  AMF_BPS_REF=4 AMF_MAXRATE_FACTOR=1.15 AMF_DRYRUN=1 ./makeinstall.sh
  export AMF_SUPPORTED_FLAGS="minqp,maxqp"
  AMF_ENABLE_MINQP=1 AMF_MINQP=12 ./makeinstall.sh

VERSION: 46.26
DATE: $(date +"%Y-%m-%d %H:%M")
════════════════════════════════════════════════════════════════════════════
README

# Optional zip
cd "$OUTPUT_DIR"
if command -v zip &>/dev/null; then
  ZIP_NAME="ffmpeg-v46.26-vmixproxy-$(date +%Y%m%d-%H%M).zip"
  zip -q "$ZIP_NAME" ffmpeg6.exe ffmpeg.exe ffprobe.exe README.txt 2>/dev/null || true
  if [ -f "$ZIP_NAME" ]; then
    log_success "ZIP: $ZIP_NAME"
  fi
fi

log_section "BUILD COMPLETED!"

echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}✓✓✓ v46.26 FINAL ✓✓✓${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${CYAN}Files at: ${YELLOW}$OUTPUT_DIR${NC}"
echo ""
ls -lh "$OUTPUT_DIR"/*.exe 2>/dev/null
echo ""
echo -e "${YELLOW}SETUP IN VMIX:${NC}"
echo -e "  Point to: ${GREEN}ffmpeg6.exe${NC}"
echo ""
echo -e "${CYAN}ARCHITECTURE:${NC}"
echo -e "  vMix → ${GREEN}ffmpeg6.exe${NC} (proxy) → ${GREEN}ffmpeg.exe${NC} (real)"
echo ""
echo -e "${CYAN}LOGS:${NC}"
echo -e "  Runtime: ${GREEN}C:\\ProgramData\\vMix\\streaming\\ffmpegproxy.log${NC}"
echo ""

log_section "END"
