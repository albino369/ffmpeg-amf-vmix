// ffmpeg_proxy.c — vmixproxy v0.3b (debugged again)
// CHANGE: Added append_raw_safe() to eliminate risky strncat patterns.
// CHANGE: Fixed output detection to accept "-" (stdout) as a valid output token.
// CHANGE: Standardized log and cmdline building to use safe append helpers.
// CHANGE: Strengthened bounds checks in append_token_safe().

#include <windows.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#define MAX_ARGS 1024
#define MAX_CMD 131072

static const char *FFMPEG_ABS = "C:\\\\Program Files (x86)\\\\vMix\\\\streaming\\\\ffmpeg.exe";

typedef struct { const char *x264_preset; const char *amf_usage; const char *amf_quality; } PresetMap;
static const PresetMap preset_map[] = {
    {"ultrafast","lowlatency","speed"}, {"superfast","lowlatency","speed"},
    {"veryfast","lowlatency","speed"}, {"faster","lowlatency","balanced"},
    {"fast","lowlatency","balanced"}, {"medium","transcoding","balanced"},
    {"slow","transcoding","quality"}, {"slower","transcoding","quality"},
    {"veryslow","transcoding","quality"}, {NULL,NULL,NULL}
};

static const PresetMap* find_preset(const char* p) {
    if (!p) return NULL;
    for (int i = 0; preset_map[i].x264_preset; i++) {
        if (_stricmp(p, preset_map[i].x264_preset) == 0) return &preset_map[i];
    }
    return NULL;
}

static char* dupstr(const char* s) {
    if (!s) return NULL;
    size_t n = strlen(s) + 1;
    char *r = (char*)malloc(n);
    if (r) memcpy(r, s, n);
    return r;
}

/* CHANGE: Safe raw appender (no quoting), using snprintf with offset tracking */
static void append_raw_safe(char *out, int outsize, const char *text) {
    if (!out || !text || outsize <= 0) return;
    int len = (int)strlen(out);
    int remaining = outsize - len;
    if (remaining <= 1) return;
    (void)snprintf(out + len, remaining, "%s", text);
}

/* CHANGE: Safer token append using snprintf and strict bounds for the inserted space */
static void append_token_safe(char *out, int outsize, const char *token) {
    if (!out || !token || outsize <= 0) return;

    int len = (int)strlen(out);
    int remaining = outsize - len;
    if (remaining <= 1) return;

    if (len > 0) {
        /* CHANGE: Ensure there is room for ' ' and '\0' */
        if (remaining <= 2) return;
        out[len] = ' ';
        out[len + 1] = '\0';
        len++;
        remaining = outsize - len;
        if (remaining <= 1) return;
    }

    int needq = strchr(token, ' ') != NULL;
    if (needq) {
        (void)snprintf(out + len, remaining, "\"%s\"", token);
    } else {
        (void)snprintf(out + len, remaining, "%s", token);
    }
}

static void build_cmdline_str(int argc, char *argv[], char *out, int outsize) {
    if (!out || outsize <= 0) return;
    out[0] = '\0';
    for (int i = 0; i < argc; i++) append_token_safe(out, outsize, argv[i]);
}

/* CHANGE: Treat "-" as a valid output token (stdout) */
static int is_valid_output_token(const char *t) {
    if (!t) return 0;
    if (strcmp(t, "-") == 0) return 1;      /* stdout */
    return t[0] != '-';                     /* normal output (URL/path) */
}

/* CHANGE: Prefer -f <fmt> <output>, fallback to last valid output token */
static int find_output_index_pref(int argc, char *argv[]) {
    if (argc <= 1) return argc;

    for (int i = 1; i < argc - 2; i++) {
        if (!argv[i]) continue;
        if (_stricmp(argv[i], "-f") == 0 && argv[i+1] && argv[i+1][0] != '-') {
            if (is_valid_output_token(argv[i+2])) return i + 2;
        }
    }

    for (int i = argc - 1; i >= 1; i--) {
        if (is_valid_output_token(argv[i])) return i;
    }

    return argc;
}

int main(int argc, char *argv[]) {
    if (argc <= 0) return 1;

    char *tmp_args[MAX_ARGS];
    for (int i = 0; i < MAX_ARGS; i++) tmp_args[i] = NULL;
    int tmp_argc = 0;

    int converted = 0;
    const char *preset_value = NULL;
    int have_pixfmt_or_format = 0;
    int force_usage_lowlatency = 0;
    const char *force_rc = NULL;
    int force_pixfmt_nv12 = 0;

    if (GetFileAttributesA(FFMPEG_ABS) == INVALID_FILE_ATTRIBUTES) {
        fprintf(stderr, "Proxy ERROR: ffmpeg.exe not found at \"%s\"\n", FFMPEG_ABS);
        return 1;
    }

    /* First pass: parse and duplicate tokens into tmp_args */
    for (int i = 1; i < argc; i++) {
        char *a = argv[i];
        if (!a) continue;

        if ((_stricmp(a,"-c:v")==0 || _stricmp(a,"-codec:v")==0 || _stricmp(a,"-vcodec")==0) && i+1 < argc) {
            if (_stricmp(argv[i+1], "libx264") == 0) {
                if (tmp_argc < MAX_ARGS - 2) {
                    tmp_args[tmp_argc++] = dupstr("-c:v");
                    tmp_args[tmp_argc++] = dupstr("h264_amf");
                }
                converted = 1;
                i++;
                continue;
            }
        }

        if ((_stricmp(a,"-preset")==0 || _stricmp(a,"-preset:v")==0) && i+1 < argc && converted) {
            preset_value = argv[i+1];
            i++;
            continue;
        }

        if (converted && (_stricmp(a,"-profile:v")==0 || _stricmp(a,"-profile")==0 ||
                          _stricmp(a,"-level:v")==0   || _stricmp(a,"-level")==0)) {
            if (i+1 < argc) i++;
            continue;
        }

        if (_stricmp(a,"-threads")==0 && i+1 < argc) { i++; continue; }

        if (_stricmp(a,"-tune")==0 && i+1 < argc) {
            if (_stricmp(argv[i+1], "zerolatency") == 0) {
                force_usage_lowlatency = 1;
                force_rc = "cbr";
                i++;
                continue;
            }
        }

        if (_stricmp(a,"-crf")==0 && i+1 < argc) {
            int crf_val = atoi(argv[i+1]);
            force_rc = (crf_val <= 23) ? "vbr" : "cbr";
            i++;
            continue;
        }

        if ((_stricmp(a,"-pix_fmt")==0 || _stricmp(a,"-pix_fmt:v")==0) && i+1 < argc) {
            have_pixfmt_or_format = 1;
            if (tmp_argc < MAX_ARGS - 2) {
                tmp_args[tmp_argc++] = dupstr(a);
                tmp_args[tmp_argc++] = dupstr(argv[++i]);
            } else i++;
            continue;
        }

        if (_stricmp(a,"-vf")==0 && i+1 < argc) {
            if (strstr(argv[i+1], "format=") != NULL) have_pixfmt_or_format = 1;
            if (tmp_argc < MAX_ARGS - 2) {
                tmp_args[tmp_argc++] = dupstr(a);
                tmp_args[tmp_argc++] = dupstr(argv[++i]);
            } else i++;
            continue;
        }

        if (tmp_argc < MAX_ARGS - 1) tmp_args[tmp_argc++] = dupstr(a);
        else break;
    }

    if (converted && !have_pixfmt_or_format) force_pixfmt_nv12 = 1;

    const char *usage = NULL, *quality = NULL;
    if (preset_value && converted) {
        const PresetMap *pm = find_preset(preset_value);
        usage = pm ? pm->amf_usage : "transcoding";
        quality = pm ? pm->amf_quality : "balanced";
    }
    if (force_usage_lowlatency) usage = "lowlatency";

    /* Build final_args by moving pointers from tmp_args (ownership transfer) */
    int out_idx = find_output_index_pref(tmp_argc, tmp_args);
    if (out_idx > tmp_argc) out_idx = tmp_argc;

    char *final_args[MAX_ARGS];
    for (int i = 0; i < MAX_ARGS; i++) final_args[i] = NULL;
    int final_argc = 0;

    for (int i = 0; i < out_idx && i < tmp_argc; i++) {
        final_args[final_argc++] = tmp_args[i];
        tmp_args[i] = NULL; /* ownership moved */
    }

    if (usage && quality) {
        if (final_argc < MAX_ARGS - 2) {
            final_args[final_argc++] = dupstr("-usage");
            final_args[final_argc++] = dupstr(usage);
        }
        if (final_argc < MAX_ARGS - 2) {
            final_args[final_argc++] = dupstr("-quality");
            final_args[final_argc++] = dupstr(quality);
        }
    }

    if (force_rc) {
        if (final_argc < MAX_ARGS - 2) {
            final_args[final_argc++] = dupstr("-rc");
            final_args[final_argc++] = dupstr(force_rc);
        }
    }

    if (force_pixfmt_nv12) {
        if (final_argc < MAX_ARGS - 2) {
            final_args[final_argc++] = dupstr("-pix_fmt");
            final_args[final_argc++] = dupstr("nv12");
        }
    }

    for (int i = out_idx; i < tmp_argc && final_argc < MAX_ARGS - 1; i++) {
        final_args[final_argc++] = tmp_args[i];
        tmp_args[i] = NULL; /* ownership moved */
    }
    final_args[final_argc] = NULL;

    /* Build final_cmd */
    char final_cmd[MAX_CMD];
    final_cmd[0] = '\0';
    for (int i = 0; i < final_argc; i++) append_token_safe(final_cmd, sizeof(final_cmd), final_args[i]);

    /* CHANGE: Build final_with_prog without mixing raw concatenation */
    char final_with_prog[MAX_CMD];
    final_with_prog[0] = '\0';
    append_token_safe(final_with_prog, sizeof(final_with_prog), FFMPEG_ABS);
    for (int i = 0; i < final_argc; i++) append_token_safe(final_with_prog, sizeof(final_with_prog), final_args[i]);

    /* Per-run log */
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

    /* CHANGE: Build cmdline using safe raw appender for the already-built final_cmd */
    char cmdline[MAX_CMD];
    cmdline[0] = '\0';
    append_raw_safe(cmdline, sizeof(cmdline), "\"");
    append_raw_safe(cmdline, sizeof(cmdline), FFMPEG_ABS);
    append_raw_safe(cmdline, sizeof(cmdline), "\"");
    if (final_cmd[0]) {
        append_raw_safe(cmdline, sizeof(cmdline), " ");
        append_raw_safe(cmdline, sizeof(cmdline), final_cmd);
    }

    if (cmdline[0] == '\0') {
        fprintf(stderr, "Proxy ERROR: command line construction failed\n");
        for (int i = 0; i < final_argc; i++) if (final_args[i]) free(final_args[i]);
        for (int i = 0; i < tmp_argc; i++) if (tmp_args[i]) free(tmp_args[i]);
        return 1;
    }

    STARTUPINFOA si; PROCESS_INFORMATION pi;
    ZeroMemory(&si, sizeof(si)); si.cb = sizeof(si);
    ZeroMemory(&pi, sizeof(pi));

    if (!CreateProcessA(NULL, cmdline, NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi)) {
        DWORD e = GetLastError();
        fprintf(stderr, "Proxy ERROR: CreateProcess failed (%lu)\n", e);
        for (int i = 0; i < final_argc; i++) if (final_args[i]) free(final_args[i]);
        for (int i = 0; i < tmp_argc; i++) if (tmp_args[i]) free(tmp_args[i]);
        return 1;
    }

    WaitForSingleObject(pi.hProcess, INFINITE);
    DWORD exit_code = 0;
    if (!GetExitCodeProcess(pi.hProcess, &exit_code)) exit_code = 1;

    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);

    for (int i = 0; i < final_argc; i++) if (final_args[i]) free(final_args[i]);
    for (int i = 0; i < tmp_argc; i++) if (tmp_args[i]) free(tmp_args[i]);

    return (int)exit_code;
}
