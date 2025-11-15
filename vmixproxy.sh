#!/bin/bash
################################################################################
# vmixproxy.sh — Proxy-only build (v0.1a)
# - Converts libx264 -> h264_amf
# - Removes -preset and maps to -usage/-quality
# - Per-run log created in C:\ProgramData\vMix\streaming\vmixproxy-YYYY-MM-DD-HH-MM-SS.log
# - Executes ffmpeg from absolute path: C:\Program Files (x86)\vMix\streaming\ffmpeg.exe
################################################################################

set -e
set -o pipefail

WORKDIR="$(pwd)"
OUTPUT_DIR="$WORKDIR/output"
PROXY_SOURCE="$WORKDIR/ffmpeg_proxy.c"
TARGET_ARCH=${TARGET_ARCH:-x86_64-w64-mingw32}
BUILD_PROX_FLAGS=${BUILD_PROX_FLAGS:-"-O2 -s"}

mkdir -p "$OUTPUT_DIR"

cat > "$PROXY_SOURCE" <<'PROXY_CODE'
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#define MAX_ARGS 512
#define MAX_CMD 65536

/* Absolute path to ffmpeg.exe */
static const char *FFMPEG_ABS = "C:\\\\Program Files (x86)\\\\vMix\\\\streaming\\\\ffmpeg.exe";

typedef struct {
    const char *x264_preset;
    const char *amf_usage;
    const char *amf_quality;
} PresetMap;

static const PresetMap preset_map[] = {
    {"ultrafast", "lowlatency", "speed"},
    {"superfast", "lowlatency", "speed"},
    {"veryfast",  "lowlatency", "speed"},
    {"faster",    "lowlatency", "balanced"},
    {"fast",      "lowlatency", "balanced"},
    {"medium",    "transcoding", "balanced"},
    {"slow",      "transcoding", "quality"},
    {"slower",    "transcoding", "quality"},
    {"veryslow",  "transcoding", "quality"},
    {NULL, NULL, NULL}
};

static const PresetMap* find_preset(const char *preset) {
    for (int i = 0; preset_map[i].x264_preset != NULL; i++) {
        if (_stricmp(preset, preset_map[i].x264_preset) == 0) {
            return &preset_map[i];
        }
    }
    return NULL;
}

/* Build command line string with quoting */
static void build_cmdline_str(int argc, char *argv[], char *out, int outsize) {
    out[0] = 0;
    for (int i = 0; i < argc; i++) {
        if (i) strncat(out, " ", outsize - (int)strlen(out) - 1);
        int needq = (strchr(argv[i], ' ') != NULL);
        if (needq) strncat(out, "\"", outsize - (int)strlen(out) - 1);
        strncat(out, argv[i], outsize - (int)strlen(out) - 1);
        if (needq) strncat(out, "\"", outsize - (int)strlen(out) - 1);
    }
}

/* Append token with quoting if needed */
static void append_token(char *out, int outsize, const char *token) {
    if (!token) return;
    if (out[0] != 0) strncat(out, " ", outsize - (int)strlen(out) - 1);
    int needq = (strchr(token, ' ') != NULL);
    if (needq) strncat(out, "\"", outsize - (int)strlen(out) - 1);
    strncat(out, token, outsize - (int)strlen(out) - 1);
    if (needq) strncat(out, "\"", outsize - (int)strlen(out) - 1);
}

int main(int argc, char *argv[]) {
    char *new_args[MAX_ARGS];
    int new_argc = 0;
    char final_args[MAX_CMD] = {0};
    char final_with_prog[MAX_CMD] = {0};
    const char *preset_value = NULL;
    int converted = 0;

    /* Verify ffmpeg exists at absolute path */
    if (GetFileAttributesA(FFMPEG_ABS) == INVALID_FILE_ATTRIBUTES) {
        fprintf(stderr, "Proxy ERROR: ffmpeg.exe not found at \"%s\"\n", FFMPEG_ABS);
        return 1;
    }

    /* Build new argv list */
    for (int i = 1; i < argc; i++) {
        char *a = argv[i];

        /* Convert codec libx264 -> h264_amf */
        if ((_stricmp(a, "-c:v") == 0 || _stricmp(a, "-codec:v") == 0) && i+1 < argc) {
            if (_stricmp(argv[i+1], "libx264") == 0) {
                new_args[new_argc++] = "-c:v";
                new_args[new_argc++] = "h264_amf";
                converted = 1;
                i++;
                continue;
            }
        }

        /* Intercept preset */
        if ((_stricmp(a, "-preset") == 0 || _stricmp(a, "-preset:v") == 0) && i+1 < argc && converted) {
            preset_value = argv[i+1];
            i++;
            continue; /* skip preset */
        }

        /* Pass-through */
        new_args[new_argc++] = a;
        if (new_argc >= MAX_ARGS - 2) break;
    }

    /* Map preset to usage/quality */
    if (preset_value && converted) {
        const PresetMap *pm = find_preset(preset_value);
        if (pm) {
            new_args[new_argc++] = "-usage";
            new_args[new_argc++] = (char*)pm->amf_usage;
            new_args[new_argc++] = "-quality";
            new_args[new_argc++] = (char*)pm->amf_quality;
        } else {
            new_args[new_argc++] = "-usage";
            new_args[new_argc++] = "transcoding";
            new_args[new_argc++] = "-quality";
            new_args[new_argc++] = "balanced";
        }
    }

    new_args[new_argc] = NULL;

    /* Build final args string */
    final_args[0] = 0;
    for (int i = 0; i < new_argc; i++) {
        append_token(final_args, sizeof(final_args), new_args[i]);
    }

    /* Build string with program + args for logging */
    final_with_prog[0] = 0;
    append_token(final_with_prog, sizeof(final_with_prog), FFMPEG_ABS);
    if (final_args[0] != 0) {
        strncat(final_with_prog, " ", sizeof(final_with_prog) - (int)strlen(final_with_prog) - 1);
        strncat(final_with_prog, final_args, sizeof(final_with_prog) - (int)strlen(final_with_prog) - 1);
    }

    /* Create per-run log */
    SYSTEMTIME st; GetLocalTime(&st);
    char log_path[MAX_PATH];
    snprintf(log_path, MAX_PATH,
             "C:\\\\ProgramData\\\\vMix\\\\streaming\\\\vmixproxy-%04d-%02d-%02d-%02d-%02d-%02d.log",
             st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond);

    FILE *log = fopen(log_path, "w");
    if (log) {
        char orig_cmd[MAX_CMD];
        build_cmdline_str(argc, argv, orig_cmd, sizeof(orig_cmd));
        fprintf(log, "==== vmixproxy per-run log ====\n");
        fprintf(log, "Original command: %s\n", orig_cmd);
        fprintf(log, "Final command: %s\n", final_with_prog);
        fclose(log);
    }

    /* Execute ffmpeg at absolute path */
    STARTUPINFOA si; PROCESS_INFORMATION pi;
    ZeroMemory(&si, sizeof(si)); si.cb = sizeof(si);
    ZeroMemory(&pi, sizeof(pi));

    if (!CreateProcessA(FFMPEG_ABS, final_args[0] ? final_args : NULL,
                        NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi)) {
        DWORD err = GetLastError();
        fprintf(stderr, "Proxy ERROR: Cannot start ffmpeg.exe (error %lu)\n", err);
        return 1;
    }

    WaitForSingleObject(pi.hProcess, INFINITE);
    DWORD exit_code = 0;
    GetExitCodeProcess(pi.hProcess, &exit_code);
    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);

    return (int)exit_code;
}
PROXY_CODE

echo "[INFO] Compiling proxy v0.1a..."
${TARGET_ARCH}-gcc ${BUILD_PROX_FLAGS} -o "$OUTPUT_DIR/ffmpeg6.exe" "$PROXY_SOURCE" -static-libgcc

if [ -f "$OUTPUT_DIR/ffmpeg6.exe" ]; then
    echo "[INFO] ffmpeg6.exe generated at $OUTPUT_DIR/ffmpeg6.exe"
else
    echo "[ERROR] ffmpeg6.exe was not generated"
    exit 1
fi

