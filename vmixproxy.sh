#!/bin/bash
################################################################################
# FFmpeg Windows x64 Build Script - AMD AMF Proxy Approach
# Versão 46.2 - vmixproxy.sh (FIX: FDK-AAC paths)
#
# ARQUITETURA:
#   vMix → ffmpeg6.exe (proxy) → ffmpeg.exe (real com AMF)
################################################################################

if [ -z "$BASH_VERSION" ]; then
    echo "ERRO: Este script requer bash"
    exit 1
fi

set -e
set -o pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${GREEN}════════════════════════════════════════${NC}"
echo -e "${GREEN}FFmpeg Builder v46.2 - vmixproxy.sh${NC}"
echo -e "${GREEN}vMix → ffmpeg6.exe → ffmpeg.exe${NC}"
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo ""

WORKDIR="$(pwd)"
OUTPUT_DIR="$WORKDIR/output"
PREFIX="$OUTPUT_DIR/build_static"
TARGET_ARCH="x86_64-w64-mingw32"
DEPURE_LOG="$WORKDIR/depure.log"

> "$DEPURE_LOG"
exec 1> >(tee -a "$DEPURE_LOG")
exec 2>&1

log_section() {
    echo ""
    echo "════════════════════════════════════════════════════════════════════════════"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "════════════════════════════════════════════════════════════════════════════"
    echo ""
}

log_step() {
    echo -e "${CYAN}[$1]${NC} ${YELLOW}$2${NC}"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$1] $2" >> "$DEPURE_LOG"
}

log_success() {
    echo -e "${GREEN}  ✓ $1${NC}"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] SUCCESS: $1" >> "$DEPURE_LOG"
}

log_error() {
    echo -e "${RED}  ✗ $1${NC}"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >> "$DEPURE_LOG"
}

log_info() {
    echo -e "${BLUE}  → $1${NC}"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $1" >> "$DEPURE_LOG"
}

log_section "INÍCIO v46.2"
echo "Diretório: $WORKDIR"
echo "CPU cores: $(nproc)"
echo ""

mkdir -p "$OUTPUT_DIR" "$OUTPUT_DIR/logs" "$PREFIX" "$WORKDIR/sources"

log_step "1/6" "Verificando dependências..."

DEPS_NEEDED=""
for dep in git pkg-config autoconf automake libtool yasm nasm cmake; do
    command -v "$dep" &>/dev/null || DEPS_NEEDED="$DEPS_NEEDED $dep"
done

if ! command -v ${TARGET_ARCH}-gcc &>/dev/null; then
    DEPS_NEEDED="$DEPS_NEEDED mingw-w64"
fi

if [ -n "$DEPS_NEEDED" ]; then
    log_info "Instalando:$DEPS_NEEDED"
    sudo apt-get update
    sudo apt-get install -y build-essential $DEPS_NEEDED
fi

log_success "Dependências OK"

log_step "2/6" "AMD AMF SDK..."

if [ ! -d "$WORKDIR/AMF" ]; then
    git clone --depth 1 https://github.com/GPUOpen-LibrariesAndSDKs/AMF.git "$WORKDIR/AMF"
fi

AMF_PATH="$WORKDIR/AMF/amf/public/include"
cd "$AMF_PATH" && [ ! -e "AMF" ] && ln -s . AMF 2>/dev/null || true

log_success "AMF SDK pronto"

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

log_step "4/6" "FDK-AAC..."

if [ -f "$PREFIX/lib/libfdk-aac.a" ] && [ -f "$PREFIX/include/fdk-aac/aacenc_lib.h" ]; then
    log_info "FDK-AAC já instalado, pulando compilação"
else
    log_info "Compilando FDK-AAC..."
    
    if [ ! -d "$WORKDIR/sources/fdk-aac" ]; then
        cd "$WORKDIR/sources"
        git clone --depth 1 https://github.com/mstorsjo/fdk-aac.git
    fi
    
    cd "$WORKDIR/sources/fdk-aac"
    make distclean 2>/dev/null || true
    
    log_info "Executando autogen..."
    ./autogen.sh
    
    log_info "Configurando FDK-AAC..."
    ./configure \
        --host="$TARGET_ARCH" \
        --prefix="$PREFIX" \
        --disable-shared \
        --enable-static
    
    log_info "Compilando ($(nproc) threads)..."
    make -j"$(nproc)"
    
    log_info "Instalando..."
    make install
fi

if [ ! -f "$PREFIX/lib/libfdk-aac.a" ]; then
    log_error "FDK-AAC não foi compilado: libfdk-aac.a não encontrado"
    exit 1
fi

if [ ! -f "$PREFIX/include/fdk-aac/aacenc_lib.h" ]; then
    log_error "FDK-AAC headers não instalados"
    exit 1
fi

FDK_SIZE=$(du -h "$PREFIX/lib/libfdk-aac.a" | cut -f1)
log_success "FDK-AAC instalado: $FDK_SIZE"

log_step "5/6" "Compilando FFmpeg (AMF apenas)..."

cd "$WORKDIR/ffmpeg"
make distclean 2>/dev/null || true

CONFIGURE_LOG="$OUTPUT_DIR/logs/configure.log"
> "$CONFIGURE_LOG"

AMF_FLAGS="-I$AMF_PATH -I$AMF_PATH/core -I$AMF_PATH/components"

log_info "Configurando..."
log_info "PKG_CONFIG_PATH: $PREFIX/lib/pkgconfig"
log_info "FDK-AAC include: $PREFIX/include"
log_info "FDK-AAC lib: $PREFIX/lib"

PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" \
./configure \
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
    log_error "Configure falhou"
    tail -n 30 "$CONFIGURE_LOG"
    exit 1
fi

log_success "Configure OK"

if grep -q "CONFIG_H264_AMF_ENCODER=yes" ffbuild/config.mak 2>/dev/null; then
    log_success "h264_amf: HABILITADO"
else
    log_error "h264_amf: NÃO HABILITADO"
    exit 1
fi

BUILD_LOG="$OUTPUT_DIR/logs/build.log"
> "$BUILD_LOG"

log_info "Compilando (15-25 min)..."

make -j"$(nproc)" 2>&1 | tee "$BUILD_LOG"

if [ ${PIPESTATUS[0]} -ne 0 ]; then
    log_error "Build falhou"
    tail -n 50 "$BUILD_LOG"
    exit 1
fi

log_success "Build OK"

if [ ! -f ffmpeg.exe ]; then
    log_error "ffmpeg.exe não gerado"
    exit 1
fi

FFMPEG_SIZE=$(du -h ffmpeg.exe | cut -f1)
cp ffmpeg.exe "$OUTPUT_DIR/ffmpeg.exe"
log_success "ffmpeg.exe: $FFMPEG_SIZE (com h264_amf)"

[ -f ffprobe.exe ] && cp ffprobe.exe "$OUTPUT_DIR/ffprobe.exe"

log_step "6/6" "Criando ffmpeg6.exe (proxy)..."

PROXY_SOURCE="$WORKDIR/ffmpeg_proxy.c"

cat > "$PROXY_SOURCE" << 'PROXY_CODE'
/*
 * FFmpeg Proxy v46.2
 * Nome: ffmpeg6.exe
 * Chama: ffmpeg.exe (no mesmo diretório)
 */

#include <windows.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#define MAX_ARGS 512
#define MAX_CMD 32768

typedef struct {
    const char *x264_preset;
    const char *amf_usage;
    const char *amf_quality;
} PresetMap;

static const PresetMap preset_map[] = {
    {"ultrafast", "speed", "speed"},
    {"superfast", "speed", "speed"},
    {"veryfast",  "lowlatency", "speed"},
    {"faster",    "lowlatency", "speed"},
    {"fast",      "lowlatency", "balanced"},
    {"medium",    "transcoding", "balanced"},
    {"slow",      "transcoding", "quality"},
    {"slower",    "transcoding", "quality"},
    {"veryslow",  "transcoding", "quality"},
    {NULL, NULL, NULL}
};

static void log_message(const char *msg) {
    FILE *log = fopen("ffmpeg_proxy.log", "a");
    if (log) {
        SYSTEMTIME st;
        GetLocalTime(&st);
        fprintf(log, "[%02d:%02d:%02d.%03d] %s\n", 
                st.wHour, st.wMinute, st.wSecond, st.wMilliseconds, msg);
        fclose(log);
    }
}

static const PresetMap* find_preset(const char *preset) {
    for (int i = 0; preset_map[i].x264_preset != NULL; i++) {
        if (_stricmp(preset, preset_map[i].x264_preset) == 0) {
            return &preset_map[i];
        }
    }
    return NULL;
}

int main(int argc, char *argv[]) {
    char *new_args[MAX_ARGS];
    int new_argc = 0;
    char cmdline[MAX_CMD] = {0};
    char exe_path[MAX_PATH];
    char exe_dir[MAX_PATH];
    char ffmpeg_real[MAX_PATH];
    int i, converted = 0;
    const char *preset_value = NULL;
    const PresetMap *preset_mapping = NULL;
    
    log_message("=== PROXY v46.2 START ===");
    
    GetModuleFileNameA(NULL, exe_path, MAX_PATH);
    strcpy(exe_dir, exe_path);
    char *last_slash = strrchr(exe_dir, '\\');
    if (last_slash) *last_slash = 0;
    
    snprintf(ffmpeg_real, MAX_PATH, "%s\\ffmpeg.exe", exe_dir);
    
    char log_buf[512];
    snprintf(log_buf, sizeof(log_buf), "Proxy directory: %s", exe_dir);
    log_message(log_buf);
    snprintf(log_buf, sizeof(log_buf), "Target: %s", ffmpeg_real);
    log_message(log_buf);
    
    if (GetFileAttributesA(ffmpeg_real) == INVALID_FILE_ATTRIBUTES) {
        log_message("ERROR: ffmpeg.exe not found!");
        fprintf(stderr, "PROXY ERROR: ffmpeg.exe not found in %s\n", exe_dir);
        fprintf(stderr, "Make sure ffmpeg.exe is in the same directory as ffmpeg6.exe\n");
        return 1;
    }
    
    log_message("ffmpeg.exe found OK");
    
    new_args[new_argc++] = "ffmpeg.exe";
    
    log_message("=== ORIGINAL COMMAND ===");
    for (i = 1; i < argc && i < 10; i++) {
        snprintf(log_buf, sizeof(log_buf), "  arg[%d]: %s", i, argv[i]);
        log_message(log_buf);
    }
    
    for (i = 1; i < argc; i++) {
        char *arg = argv[i];
        
        if ((strcmp(arg, "-codec:v") == 0 || strcmp(arg, "-c:v") == 0) && i + 1 < argc) {
            if (strcmp(argv[i+1], "libx264") == 0) {
                new_args[new_argc++] = arg;
                new_args[new_argc++] = "h264_amf";
                log_message("CONVERTED: -codec:v libx264 → h264_amf");
                converted = 1;
                i++;
                continue;
            }
        }
        
        if ((strcmp(arg, "-preset:v") == 0 || strcmp(arg, "-preset") == 0) && i + 1 < argc && converted) {
            preset_value = argv[i+1];
            snprintf(log_buf, sizeof(log_buf), "Detected preset: %s", preset_value);
            log_message(log_buf);
            i++;
            continue;
        }
        
        if (strcmp(arg, "-tune") == 0 && converted) {
            if (i + 1 < argc) i++;
            log_message("REMOVED: -tune");
            continue;
        }
        
        if ((strcmp(arg, "-profile:v") == 0 || strcmp(arg, "-profile") == 0) && converted) {
            if (i + 1 < argc) {
                new_args[new_argc++] = arg;
                new_args[new_argc++] = argv[i+1];
                i++;
            }
            continue;
        }
        
        if (strcmp(arg, "-crf") == 0 && converted) {
            if (i + 1 < argc) {
                int crf = atoi(argv[i+1]);
                int bitrate = (51 - crf) * 200000;
                char bitrate_str[32];
                snprintf(bitrate_str, sizeof(bitrate_str), "%d", bitrate);
                new_args[new_argc++] = "-b:v";
                new_args[new_argc++] = strdup(bitrate_str);
                snprintf(log_buf, sizeof(log_buf), "CONVERTED: -crf %d → -b:v %d", crf, bitrate);
                log_message(log_buf);
                i++;
            }
            continue;
        }
        
        new_args[new_argc++] = arg;
        
        if (new_argc >= MAX_ARGS - 10) {
            log_message("WARNING: Too many arguments");
            break;
        }
    }
    
    if (preset_value && converted) {
        preset_mapping = find_preset(preset_value);
        if (preset_mapping) {
            new_args[new_argc++] = "-usage";
            new_args[new_argc++] = (char*)preset_mapping->amf_usage;
            new_args[new_argc++] = "-quality";
            new_args[new_argc++] = (char*)preset_mapping->amf_quality;
            snprintf(log_buf, sizeof(log_buf), 
                     "MAPPED: preset %s → usage=%s quality=%s",
                     preset_value, preset_mapping->amf_usage, preset_mapping->amf_quality);
            log_message(log_buf);
        } else {
            new_args[new_argc++] = "-usage";
            new_args[new_argc++] = "transcoding";
            new_args[new_argc++] = "-quality";
            new_args[new_argc++] = "balanced";
        }
    }
    
    new_args[new_argc] = NULL;
    
    log_message("=== FINAL COMMAND ===");
    snprintf(log_buf, sizeof(log_buf), "Total arguments: %d", new_argc - 1);
    log_message(log_buf);
    
    int pos = 0;
    for (i = 0; i < new_argc && pos < MAX_CMD - 1; i++) {
        if (i > 0) cmdline[pos++] = ' ';
        
        int needs_quote = strchr(new_args[i], ' ') != NULL || strchr(new_args[i], ':') != NULL;
        if (needs_quote) cmdline[pos++] = '"';
        
        int len = strlen(new_args[i]);
        if (pos + len < MAX_CMD - 1) {
            strcpy(&cmdline[pos], new_args[i]);
            pos += len;
        }
        
        if (needs_quote && pos < MAX_CMD - 1) 
            cmdline[pos++] = '"';
    }
    cmdline[pos] = 0;
    
    STARTUPINFOA si;
    PROCESS_INFORMATION pi;
    ZeroMemory(&si, sizeof(si));
    si.cb = sizeof(si);
    ZeroMemory(&pi, sizeof(pi));
    
    log_message("Calling CreateProcess...");
    
    if (!CreateProcessA(ffmpeg_real, cmdline, NULL, NULL, TRUE, 0, 
                        NULL, NULL, &si, &pi)) {
        DWORD err = GetLastError();
        snprintf(log_buf, sizeof(log_buf), "CreateProcess FAILED: error %lu", err);
        log_message(log_buf);
        fprintf(stderr, "PROXY ERROR: Cannot start ffmpeg.exe (error %lu)\n", err);
        return 1;
    }
    
    log_message("Process started successfully");
    
    WaitForSingleObject(pi.hProcess, INFINITE);
    
    DWORD exit_code = 0;
    GetExitCodeProcess(pi.hProcess, &exit_code);
    
    snprintf(log_buf, sizeof(log_buf), "Process exit code: %lu", exit_code);
    log_message(log_buf);
    log_message("=== PROXY END ===");
    
    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);
    
    return (int)exit_code;
}
PROXY_CODE

log_info "Compilando proxy..."

${TARGET_ARCH}-gcc -O2 -s \
    -o "$OUTPUT_DIR/ffmpeg6.exe" \
    "$PROXY_SOURCE" \
    -static -static-libgcc

if [ ! -f "$OUTPUT_DIR/ffmpeg6.exe" ]; then
    log_error "ffmpeg6.exe não foi gerado"
    exit 1
fi

PROXY_SIZE=$(du -h "$OUTPUT_DIR/ffmpeg6.exe" | cut -f1)
log_success "ffmpeg6.exe (proxy): $PROXY_SIZE"

cat > "$OUTPUT_DIR/README.txt" << 'README'
════════════════════════════════════════════════════════════════════════════
FFmpeg v46.2 - AMD AMF Proxy (vmixproxy.sh)
════════════════════════════════════════════════════════════════════════════

ARQUITETURA CORRETA:
  vMix → ffmpeg6.exe (proxy) → ffmpeg.exe (real com h264_amf)

ARQUIVOS:
  • ffmpeg6.exe  = PROXY (configure o vMix para usar este)
  • ffmpeg.exe   = FFmpeg real com h264_amf
  • ffprobe.exe  = Ferramenta de análise

IMPORTANTE:
  Os dois arquivos DEVEM estar no mesmo diretório!

CONFIGURAÇÃO NO VMIX:
  1. Vá em Settings → Encoders → External
  2. Aponte para: ffmpeg6.exe
  3. Use configurações normais (libx264, preset, etc)
  4. O proxy converte automaticamente para h264_amf

CONVERSÕES AUTOMÁTICAS:
  ✓ -codec:v libx264 → h264_amf
  ✓ -preset:v veryfast → -usage lowlatency -quality speed
  ✓ -crf 23 → -b:v 5600000

LOGS:
  • ffmpeg_proxy.log = Log do proxy (runtime)
  • depure.log = Log do build

VERSÃO: 46.2 (FIX: FDK-AAC paths)
DATA: $(date +"%Y-%m-%d %H:%M")
════════════════════════════════════════════════════════════════════════════
README

cd "$OUTPUT_DIR"
if command -v zip &>/dev/null; then
    ZIP_NAME="ffmpeg-v46.2-vmixproxy-$(date +%Y%m%d-%H%M).zip"
    zip -q "$ZIP_NAME" ffmpeg6.exe ffmpeg.exe ffprobe.exe README.txt 2>/dev/null || true
    if [ -f "$ZIP_NAME" ]; then
        log_success "ZIP: $ZIP_NAME"
    fi
fi

log_section "BUILD CONCLUÍDO!"

echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}✓✓✓ v46.2 DEFINITIVO ✓✓✓${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${CYAN}Arquivos em: ${YELLOW}$OUTPUT_DIR${NC}"
echo ""
ls -lh "$OUTPUT_DIR"/*.exe 2>/dev/null
echo ""
echo -e "${YELLOW}CONFIGURE NO VMIX:${NC}"
echo -e "  Aponte para: ${GREEN}ffmpeg6.exe${NC}"
echo ""
echo -e "${CYAN}ARQUITETURA:${NC}"
echo -e "  vMix → ${GREEN}ffmpeg6.exe${NC} (proxy) → ${GREEN}ffmpeg.exe${NC} (real)"
echo ""
echo -e "${CYAN}LOGS:${NC}"
echo -e "  Build: ${GREEN}$DEPURE_LOG${NC}"
echo -e "  Runtime: ${GREEN}ffmpeg_proxy.log${NC} (cria ao executar)"
echo ""

log_section "FIM"
