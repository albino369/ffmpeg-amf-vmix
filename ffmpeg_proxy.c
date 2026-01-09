/*
 * vmixproxy - Simple codec mapper for vMix -> FFmpeg
 *
 * Purpose:
 *   - Act as a drop-in replacement for vMix's ffmpeg6.exe
 *   - Rewrite the command line so that:
 *       * Video codec: libx264 -> h264_amf
 *       * x264 preset  -> AMF -usage / -quality
 *       * All other vMix parameters are preserved
 *       * DirectShow rtbufsize is safely increased for stability
 *
 * Notes:
 *   - This proxy only touches what is strictly necessary.
 *   - Bitrate, profile, level, GOP, audio settings, RTMP URL, etc. are passed through unchanged.
 *   - A per-run log is written under:
 *       C:\ProgramData\vMix\streaming\vmixproxy-YYYY-MM-DD-HH-MM-SS.log
 *
 * Build (MSVC, x64 example):
 *   cl /O2 /MT /EHsc vmixproxy.c /link /SUBSYSTEM:CONSOLE
 *
 * Usage:
 *   - Rename the original vMix ffmpeg binary (e.g. ffmpeg6.exe -> ffmpeg6_orig.exe)
 *   - Place this proxy as ffmpeg6.exe, pointing internally to your real ffmpeg.exe
 */

#include <windows.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#define MAX_ARGS 512
#define MAX_CMD  65536

/* Absolute path to the real ffmpeg.exe */
static const char *FFMPEG_ABS =
    "C:\\\\Program Files (x86)\\\\vMix\\\\streaming\\\\ffmpeg.exe";

typedef struct {
    const char *x264_preset;
    const char *amf_usage;
    const char *amf_quality;
} PresetMap;

static const PresetMap preset_map[] = {
    { "ultrafast", "lowlatency", "speed"    },
    { "superfast", "lowlatency", "speed"    },
    { "veryfast",  "lowlatency", "speed"    },
    { "faster",    "lowlatency", "balanced" },
    { "fast",      "lowlatency", "balanced" },
    { "medium",    "transcoding", "balanced"},
    { "slow",      "transcoding", "quality" },
    { "slower",    "transcoding", "quality" },
    { "veryslow",  "transcoding", "quality" },
    { NULL,        NULL,          NULL      }
};

static const PresetMap* find_preset(const char *preset) {
    for (int i = 0; preset_map[i].x264_preset != NULL; i++) {
        if (_stricmp(preset, preset_map[i].x264_preset) == 0) {
            return &preset_map[i];
        }
    }
    return NULL;
}

/* Build command line string with proper quoting (for logging) */
static void build_cmdline_str(int argc, char *argv[], char *out, int outsize) {
    out[0] = 0;
    for (int i = 0; i < argc; i++) {
        if (i) {
            strncat(out, " ", outsize - (int)strlen(out) - 1);
        }
        int needq = (strchr(argv[i], ' ') != NULL);
        if (needq) {
            strncat(out, "\"", outsize - (int)strlen(out) - 1);
        }
        strncat(out, argv[i], outsize - (int)strlen(out) - 1);
        if (needq) {
            strncat(out, "\"", outsize - (int)strlen(out) - 1);
        }
    }
}

/* Append token with quoting if needed (for process cmdline) */
static void append_token(char *out, int outsize, const char *token) {
    if (!token) return;
    if (out[0] != 0) {
        strncat(out, " ", outsize - (int)strlen(out) - 1);
    }
    int needq = (strchr(token, ' ') != NULL);
    if (needq) {
        strncat(out, "\"", outsize - (int)strlen(out) - 1);
    }
    strncat(out, token, outsize - (int)strlen(out) - 1);
    if (needq) {
        strncat(out, "\"", outsize - (int)strlen(out) - 1);
    }
}

int main(int argc, char *argv[]) {
    char *new_args[MAX_ARGS];
    int   new_argc = 0;
    char  final_args[MAX_CMD]       = {0};
    char  final_with_prog[MAX_CMD]  = {0};
    const char *preset_value        = NULL;
    int   converted                 = 0;

    /* Verify ffmpeg exists at absolute path */
    if (GetFileAttributesA(FFMPEG_ABS) == INVALID_FILE_ATTRIBUTES) {
        fprintf(stderr,
                "Proxy ERROR: ffmpeg.exe not found at \"%s\"\n",
                FFMPEG_ABS);
        return 1;
    }

    /*
     * Build new argv list:
     *   - Override -rtbufsize to a safe large value
     *   - Convert libx264 -> h264_amf
     *   - Capture and remove -preset, later map to -usage/-quality
     *   - Pass everything else through unchanged
     */
    for (int i = 1; i < argc; i++) {
        char *a = argv[i];

        /* Override rtbufsize for DirectShow input stability */
        if (_stricmp(a, "-rtbufsize") == 0 && i + 1 < argc) {
            new_args[new_argc++] = "-rtbufsize";
            new_args[new_argc++] = "1024M"; /* 1 GiB buffer */
            i++; /* skip original value */
            continue;
        }

        /* Convert codec libx264 -> h264_amf */
        if ((_stricmp(a, "-c:v") == 0 || _stricmp(a, "-codec:v") == 0) &&
            i + 1 < argc) {
            if (_stricmp(argv[i + 1], "libx264") == 0) {
                new_args[new_argc++] = "-c:v";
                new_args[new_argc++] = "h264_amf";
                converted = 1;
                i++;
                continue;
            }
        }

        /* Intercept preset (skip original, will map later) */
        if ((_stricmp(a, "-preset") == 0 || _stricmp(a, "-preset:v") == 0) &&
            i + 1 < argc && converted) {
            preset_value = argv[i + 1];
            i++;
            continue; /* do not add -preset to final command */
        }

        /* Pass-through argument */
        new_args[new_argc++] = a;
        if (new_argc >= MAX_ARGS - 4) {
            break;
        }
    }

    /*
     * Map x264 preset to AMF usage/quality, appended as trailing options.
     * This mimics a known working behavior where trailing encoder options
     * are still honored by FFmpeg's AMF implementation.
     */
    if (preset_value && converted) {
        const PresetMap *pm = find_preset(preset_value);
        if (pm) {
            new_args[new_argc++] = "-usage";
            new_args[new_argc++] = (char*)pm->amf_usage;
            new_args[new_argc++] = "-quality";
            new_args[new_argc++] = (char*)pm->amf_quality;
        } else {
            /* Reasonable default if preset is unknown */
            new_args[new_argc++] = "-usage";
            new_args[new_argc++] = "transcoding";
            new_args[new_argc++] = "-quality";
            new_args[new_argc++] = "balanced";
        }
    }

    new_args[new_argc] = NULL;

    /* Build final args string for process creation */
    final_args[0] = 0;
    for (int i = 0; i < new_argc; i++) {
        append_token(final_args, sizeof(final_args), new_args[i]);
    }

    /* Build string with program + args for logging */
    final_with_prog[0] = 0;
    append_token(final_with_prog, sizeof(final_with_prog), FFMPEG_ABS);
    if (final_args[0] != 0) {
        strncat(final_with_prog, " ",
                sizeof(final_with_prog) - (int)strlen(final_with_prog) - 1);
        strncat(final_with_prog, final_args,
                sizeof(final_with_prog) - (int)strlen(final_with_prog) - 1);
    }

    /* Create per-run log file */
    SYSTEMTIME st;
    GetLocalTime(&st);
    char log_path[MAX_PATH];
    snprintf(log_path, MAX_PATH,
             "C:\\\\ProgramData\\\\vMix\\\\streaming\\\\vmixproxy-%04d-%02d-%02d-%02d-%02d-%02d.log",
             st.wYear, st.wMonth, st.wDay,
             st.wHour, st.wMinute, st.wSecond);

    FILE *log = fopen(log_path, "w");
    if (log) {
        char orig_cmd[MAX_CMD];
        build_cmdline_str(argc, argv, orig_cmd, sizeof(orig_cmd));
        fprintf(log, "==== vmixproxy per-run log ====\n");
        fprintf(log, "Original command: %s\n", orig_cmd);
        fprintf(log, "Final command: %s\n", final_with_prog);
        fclose(log);
    }

    /* Prepare STARTUPINFOA / PROCESS_INFORMATION for CreateProcessA */
    STARTUPINFOA si;
    PROCESS_INFORMATION pi;
    ZeroMemory(&si, sizeof(si));
    si.cb = sizeof(si);
    ZeroMemory(&pi, sizeof(pi));

    /* Build command line buffer for CreateProcessA (must be mutable) */
    char cmdline[MAX_CMD];
    cmdline[0] = '\0';

    snprintf(cmdline, sizeof(cmdline), "\"%s\"", FFMPEG_ABS);
    if (final_args[0] != 0) {
        strncat(cmdline, " ", sizeof(cmdline) - strlen(cmdline) - 1);
        strncat(cmdline, final_args,
                sizeof(cmdline) - strlen(cmdline) - 1);
    }

    /* Spawn the real ffmpeg process */
    if (!CreateProcessA(
            NULL,
            cmdline,
            NULL,
            NULL,
            TRUE,  /* inherit handles from vMix */
            0,
            NULL,
            NULL,
            &si,
            &pi)) {
        DWORD err = GetLastError();
        fprintf(stderr,
                "Proxy ERROR: CreateProcess failed (%lu)\n",
                (unsigned long)err);
        return 1;
    }

    /* Wait for ffmpeg to finish and propagate its exit code */
    WaitForSingleObject(pi.hProcess, INFINITE);

    DWORD exit_code = 0;
    if (!GetExitCodeProcess(pi.hProcess, &exit_code)) {
        exit_code = 1;
    }

    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);

    return (int)exit_code;
}
