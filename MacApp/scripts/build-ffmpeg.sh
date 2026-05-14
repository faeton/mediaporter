#!/usr/bin/env bash
# Build a minimal arm64 ffmpeg + ffprobe with only the codecs/formats/filters
# MediaPorter actually uses (see CLAUDE.md and Sources/Transcode/*.swift).
#
# Output: MacApp/build/ffmpeg-bin/{ffmpeg,ffprobe} — statically linked against
# our own libass/freetype/fribidi/harfbuzz, dynamically against system libs
# only (libSystem, CoreFoundation, CoreText, VideoToolbox, AudioToolbox, …).
# Pass that directory to scripts/build-app.sh via --bundle-ffmpeg.
#
# Why we build from source instead of vendoring brew/evermeet:
#   • brew ffmpeg is ~70 MB (codecs/formats/encoders we don't ship).
#   • Our build is ~12 MB — only what the pipeline calls.
#   • No GPL contagion: --disable-gpl, no libx264/libx265 (CLAUDE.md says
#     we encode HEVC via VideoToolbox; libx265 was only a soft fallback for
#     Intel Macs without HW encode, which we don't ship a bundled variant for).
#   • Reproducible: every dep pinned by URL + SHA256.
#
# Host requirements (brew install …):
#   pkg-config meson ninja  — build systems for fribidi/harfbuzz
# Plus Xcode CLT for clang/make/autotools.
#
# Usage:
#   ./scripts/build-ffmpeg.sh           # incremental — skips already-built libs
#   ./scripts/build-ffmpeg.sh --clean   # nuke build dir, rebuild from scratch
#
# Build is idempotent via $LIB.done marker files. Bumping a pinned version
# implicitly invalidates because the marker path encodes the version.

set -euo pipefail

# Pinned versions — bump together with their SHA256s. SHA256s came from
# trust-on-first-download against upstream tarballs; rotation guide:
#   curl -sLO <new url> && shasum -a 256 <file>
FREETYPE_VERSION="2.14.3"
FREETYPE_SHA256="36bc4f1cc413335368ee656c42afca65c5a3987e8768cc28cf11ba775e785a5f"
FREETYPE_URL="https://download.savannah.gnu.org/releases/freetype/freetype-${FREETYPE_VERSION}.tar.xz"

FRIBIDI_VERSION="1.0.16"
FRIBIDI_SHA256="1b1cde5b235d40479e91be2f0e88a309e3214c8ab470ec8a2744d82a5a9ea05c"
FRIBIDI_URL="https://github.com/fribidi/fribidi/releases/download/v${FRIBIDI_VERSION}/fribidi-${FRIBIDI_VERSION}.tar.xz"

HARFBUZZ_VERSION="14.2.0"
HARFBUZZ_SHA256="94017020f96d025bb66ae91574e4cf334bcad23e8175a8a40565b3721bc2eaff"
HARFBUZZ_URL="https://github.com/harfbuzz/harfbuzz/releases/download/${HARFBUZZ_VERSION}/harfbuzz-${HARFBUZZ_VERSION}.tar.xz"

LIBASS_VERSION="0.17.4"
LIBASS_SHA256="78f1179b838d025e9c26e8fef33f8092f65611444ffa1bfc0cfac6a33511a05a"
LIBASS_URL="https://github.com/libass/libass/releases/download/${LIBASS_VERSION}/libass-${LIBASS_VERSION}.tar.xz"

FFMPEG_VERSION="8.1.1"
FFMPEG_SHA256="b6863adde98898f42602017462871b5f6333e65aec803fdd7a6308639c52edf3"
FFMPEG_URL="https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz"

# Layout. Build root lives under MacApp/build/ so it's gitignored alongside
# other intermediate output and can be wiped with `rm -rf MacApp/build`.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACAPP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_ROOT="$MACAPP_DIR/build/ffmpeg-build"
DOWNLOAD_DIR="$BUILD_ROOT/download"
SRC_DIR="$BUILD_ROOT/src"
PREFIX="$BUILD_ROOT/prefix"
BIN_OUT="$MACAPP_DIR/build/ffmpeg-bin"

# Apple Silicon target. Deployment target matches the MacApp baseline.
ARCH="arm64"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-12.0}"
SDKROOT_RESOLVED="$(xcrun --sdk macosx --show-sdk-path)"
export SDKROOT="$SDKROOT_RESOLVED"
JOBS="$(sysctl -n hw.ncpu)"

# Static link only our own libs; system libs link dynamically (stable ABI).
COMMON_CFLAGS="-arch $ARCH -isysroot $SDKROOT_RESOLVED -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET -O3 -fPIC"
COMMON_LDFLAGS="-arch $ARCH -isysroot $SDKROOT_RESOLVED -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
# pkg-config --static lets dependents see the full transitive library graph
# (e.g. ffmpeg sees that libass also needs libfreetype, libfribidi, …).
export PKG_CONFIG="${PKG_CONFIG:-pkg-config}"

# ---- helpers ------------------------------------------------------------

die() { echo "ERROR: $*" >&2; exit 1; }

require_tool() {
    command -v "$1" >/dev/null 2>&1 || die "missing tool: $1 — try: brew install $2"
}

fetch() {
    local url="$1" sha="$2" dest="$3"
    if [[ -f "$dest" ]]; then
        local actual
        actual=$(shasum -a 256 "$dest" | awk '{print $1}')
        if [[ "$actual" == "$sha" ]]; then return; fi
        echo "  ! SHA256 mismatch on cached $(basename "$dest") — refetching"
        rm -f "$dest"
    fi
    echo "  → curl $(basename "$dest")"
    curl -sSL --fail -o "$dest" "$url" || die "download failed: $url"
    local actual
    actual=$(shasum -a 256 "$dest" | awk '{print $1}')
    [[ "$actual" == "$sha" ]] || die "SHA256 mismatch for $(basename "$dest"):
  expected: $sha
  actual:   $actual"
}

extract() {
    local tarball="$1" dest_parent="$2"
    rm -rf "$dest_parent"
    mkdir -p "$dest_parent"
    tar -xf "$tarball" -C "$dest_parent" --strip-components=1
}

# ---- args ---------------------------------------------------------------

if [[ "${1:-}" == "--clean" ]]; then
    echo "==> Cleaning $BUILD_ROOT and $BIN_OUT"
    rm -rf "$BUILD_ROOT" "$BIN_OUT"
fi

mkdir -p "$DOWNLOAD_DIR" "$SRC_DIR" "$PREFIX/lib/pkgconfig" "$BIN_OUT"

# ---- preflight ----------------------------------------------------------

echo "==> Preflight: host tools"
require_tool pkg-config pkg-config
require_tool meson      meson
require_tool ninja      ninja
require_tool make       "(install Xcode CLT)"
require_tool clang      "(install Xcode CLT)"
require_tool tar        "(install Xcode CLT)"
require_tool curl       "(install Xcode CLT)"
echo "    deployment target: $MACOSX_DEPLOYMENT_TARGET"
echo "    arch:              $ARCH"
echo "    sdkroot:           $SDKROOT_RESOLVED"
echo "    parallel jobs:     $JOBS"
echo "    install prefix:    $PREFIX"

# ---- 1/5 freetype --------------------------------------------------------
# Built first because libass needs it for outline rasterization. Built without
# harfbuzz support (would create a freetype↔harfbuzz cycle we'd have to
# resolve with a two-pass build); libass uses harfbuzz directly anyway, not
# via freetype, so we lose nothing.

if [[ ! -f "$BUILD_ROOT/freetype-${FREETYPE_VERSION}.done" ]]; then
    echo "==> [1/5] freetype $FREETYPE_VERSION"
    fetch "$FREETYPE_URL" "$FREETYPE_SHA256" "$DOWNLOAD_DIR/freetype-${FREETYPE_VERSION}.tar.xz"
    extract "$DOWNLOAD_DIR/freetype-${FREETYPE_VERSION}.tar.xz" "$SRC_DIR/freetype-${FREETYPE_VERSION}"
    pushd "$SRC_DIR/freetype-${FREETYPE_VERSION}" >/dev/null
    CFLAGS="$COMMON_CFLAGS" LDFLAGS="$COMMON_LDFLAGS" \
        ./configure \
            --prefix="$PREFIX" \
            --host="${ARCH}-apple-darwin" \
            --enable-static --disable-shared \
            --without-harfbuzz \
            --without-png \
            --without-brotli
    make -j"$JOBS"
    make install
    popd >/dev/null
    touch "$BUILD_ROOT/freetype-${FREETYPE_VERSION}.done"
else
    echo "==> [1/5] freetype $FREETYPE_VERSION  (cached)"
fi

# ---- 2/5 fribidi ---------------------------------------------------------
# Pure C, meson-only since 1.0.13. No deps. Disable everything that pulls
# extra files into the install tree.

if [[ ! -f "$BUILD_ROOT/fribidi-${FRIBIDI_VERSION}.done" ]]; then
    echo "==> [2/5] fribidi $FRIBIDI_VERSION"
    fetch "$FRIBIDI_URL" "$FRIBIDI_SHA256" "$DOWNLOAD_DIR/fribidi-${FRIBIDI_VERSION}.tar.xz"
    extract "$DOWNLOAD_DIR/fribidi-${FRIBIDI_VERSION}.tar.xz" "$SRC_DIR/fribidi-${FRIBIDI_VERSION}"
    pushd "$SRC_DIR/fribidi-${FRIBIDI_VERSION}" >/dev/null
    rm -rf _build
    CFLAGS="$COMMON_CFLAGS" LDFLAGS="$COMMON_LDFLAGS" \
        meson setup _build \
            --prefix="$PREFIX" \
            --buildtype=release \
            --default-library=static \
            -Ddocs=false -Dtests=false -Dbin=false
    ninja -C _build -j"$JOBS"
    ninja -C _build install
    popd >/dev/null
    touch "$BUILD_ROOT/fribidi-${FRIBIDI_VERSION}.done"
else
    echo "==> [2/5] fribidi $FRIBIDI_VERSION  (cached)"
fi

# ---- 3/5 harfbuzz --------------------------------------------------------
# Needs freetype (already built). Use CoreText for shaping fallbacks so we
# don't pull ICU. Disable utilities/tests/docs to keep install tree clean
# and the build fast.

if [[ ! -f "$BUILD_ROOT/harfbuzz-${HARFBUZZ_VERSION}.done" ]]; then
    echo "==> [3/5] harfbuzz $HARFBUZZ_VERSION"
    fetch "$HARFBUZZ_URL" "$HARFBUZZ_SHA256" "$DOWNLOAD_DIR/harfbuzz-${HARFBUZZ_VERSION}.tar.xz"
    extract "$DOWNLOAD_DIR/harfbuzz-${HARFBUZZ_VERSION}.tar.xz" "$SRC_DIR/harfbuzz-${HARFBUZZ_VERSION}"
    pushd "$SRC_DIR/harfbuzz-${HARFBUZZ_VERSION}" >/dev/null
    rm -rf _build
    CFLAGS="$COMMON_CFLAGS" CXXFLAGS="$COMMON_CFLAGS" LDFLAGS="$COMMON_LDFLAGS" \
        meson setup _build \
            --prefix="$PREFIX" \
            --buildtype=release \
            --default-library=static \
            -Dfreetype=enabled \
            -Dcoretext=enabled \
            -Dicu=disabled -Dgraphite=disabled \
            -Dtests=disabled -Ddocs=disabled \
            -Dbenchmark=disabled -Dutilities=disabled \
            -Dcairo=disabled -Dglib=disabled -Dgobject=disabled
    ninja -C _build -j"$JOBS"
    ninja -C _build install
    popd >/dev/null
    touch "$BUILD_ROOT/harfbuzz-${HARFBUZZ_VERSION}.done"
else
    echo "==> [3/5] harfbuzz $HARFBUZZ_VERSION  (cached)"
fi

# ---- 4/5 libass ----------------------------------------------------------
# Needs freetype + fribidi + harfbuzz. CoreText for font discovery on macOS
# means we can drop fontconfig — saves ~2 MB and a beast of a dep tree.

if [[ ! -f "$BUILD_ROOT/libass-${LIBASS_VERSION}.done" ]]; then
    echo "==> [4/5] libass $LIBASS_VERSION"
    fetch "$LIBASS_URL" "$LIBASS_SHA256" "$DOWNLOAD_DIR/libass-${LIBASS_VERSION}.tar.xz"
    extract "$DOWNLOAD_DIR/libass-${LIBASS_VERSION}.tar.xz" "$SRC_DIR/libass-${LIBASS_VERSION}"
    pushd "$SRC_DIR/libass-${LIBASS_VERSION}" >/dev/null
    # --disable-libunibreak: skip pkg-config probe for brew's libunibreak;
    # libass falls back to its internal Unicode line-breaking. Without this
    # the dependency leaks into the final ffmpeg binary as a path under
    # /opt/homebrew, which doesn't exist on the user's Mac.
    CFLAGS="$COMMON_CFLAGS" LDFLAGS="$COMMON_LDFLAGS" \
        ./configure \
            --prefix="$PREFIX" \
            --host="${ARCH}-apple-darwin" \
            --enable-static --disable-shared \
            --disable-fontconfig \
            --disable-libunibreak \
            --enable-coretext
    make -j"$JOBS"
    make install
    popd >/dev/null
    touch "$BUILD_ROOT/libass-${LIBASS_VERSION}.done"
else
    echo "==> [4/5] libass $LIBASS_VERSION  (cached)"
fi

# ---- 5/5 ffmpeg ----------------------------------------------------------
# Configure flag set is the contract with the Swift code under
# Sources/Transcode/, Sources/Analysis/, Sources/Metadata/, Sources/Tagger/.
# When you add a codec/format/filter call site, add it here too — otherwise
# the bundled-ffmpeg variant fails for users while the system-ffmpeg
# variant (brew) keeps working, and it's a confusing bug to track.

if [[ ! -f "$BUILD_ROOT/ffmpeg-${FFMPEG_VERSION}.done" ]]; then
    echo "==> [5/5] ffmpeg $FFMPEG_VERSION"
    fetch "$FFMPEG_URL" "$FFMPEG_SHA256" "$DOWNLOAD_DIR/ffmpeg-${FFMPEG_VERSION}.tar.xz"
    extract "$DOWNLOAD_DIR/ffmpeg-${FFMPEG_VERSION}.tar.xz" "$SRC_DIR/ffmpeg-${FFMPEG_VERSION}"
    pushd "$SRC_DIR/ffmpeg-${FFMPEG_VERSION}" >/dev/null

    # `--pkg-config-flags=--static` makes ffmpeg pull libass's full
    # transitive link line (libfreetype + libharfbuzz + libfribidi + system
    # frameworks) rather than just `-lass`. Without it the final link
    # fails with undefined symbols from libass internals.
    ./configure \
        --prefix="$PREFIX" \
        --arch="$ARCH" \
        --target-os=darwin \
        --cc=clang \
        --extra-cflags="$COMMON_CFLAGS -I$PREFIX/include" \
        --extra-ldflags="$COMMON_LDFLAGS -L$PREFIX/lib" \
        --pkg-config-flags="--static" \
        --enable-static --disable-shared \
        --disable-debug --disable-doc --disable-htmlpages --disable-manpages \
        --disable-podpages --disable-txtpages \
        --disable-network --disable-autodetect \
        --disable-everything \
        --disable-gpl --disable-nonfree \
        --enable-protocol=file,pipe,fd \
        --enable-demuxer=mov,matroska,mpegts,mpegps,mpegvideo,avi,flac,wav,mp3,aac,ac3,eac3,dts,truehd,ogg,ass,srt,webvtt,subviewer,microdvd \
        --enable-decoder=h264,hevc,mpeg4,mpeg2video,mpeg1video,vp9,av1,prores \
        --enable-decoder=aac,ac3,eac3,dca,truehd,flac,opus,mp3,vorbis,alac \
        --enable-decoder=pcm_s16le,pcm_s16be,pcm_s24le,pcm_s24be,pcm_s32le,pcm_f32le,pcm_dvd,pcm_bluray \
        --enable-decoder=ass,ssa,subrip,movtext,webvtt,pgssub,dvdsub,dvbsub \
        --enable-encoder=hevc_videotoolbox,aac,movtext,subrip,mjpeg \
        --enable-muxer=mp4,matroska,srt,ass,image2,mjpeg \
        --enable-filter=scale,format,setpts,aresample,aformat,subtitles,overlay,null,anull,fps,trim,atrim,copy,acopy \
        --enable-bsf=aac_adtstoasc,h264_mp4toannexb,hevc_mp4toannexb,extract_extradata \
        --enable-parser=h264,hevc,aac,ac3,opus,vorbis,vp9,av1,mpeg4video,mpegvideo,mpegaudio \
        --enable-videotoolbox \
        --enable-libass --enable-libfreetype --enable-libfribidi --enable-libharfbuzz \
        --enable-zlib --enable-bzlib \
        --enable-pic
    make -j"$JOBS"
    make install
    popd >/dev/null
    touch "$BUILD_ROOT/ffmpeg-${FFMPEG_VERSION}.done"
else
    echo "==> [5/5] ffmpeg $FFMPEG_VERSION  (cached)"
fi

# ---- copy out + verify ---------------------------------------------------

echo "==> Copying binaries to $BIN_OUT"
cp -f "$PREFIX/bin/ffmpeg"  "$BIN_OUT/ffmpeg"
cp -f "$PREFIX/bin/ffprobe" "$BIN_OUT/ffprobe"
chmod +x "$BIN_OUT/ffmpeg" "$BIN_OUT/ffprobe"

echo "==> Verifying linkage"
echo "    ffmpeg:"
otool -L "$BIN_OUT/ffmpeg"  | sed 's/^/      /'
echo "    ffprobe:"
otool -L "$BIN_OUT/ffprobe" | sed 's/^/      /'

# Sanity: any /usr/local or /opt/homebrew dep means we accidentally linked
# against a host library that won't exist on the user's Mac. That's the #1
# reason a "works on my machine" bundled ffmpeg blows up in shipped builds.
# otool -L prints one dep per line, indented with a tab; the first whitespace
# field on each indented line is the dylib path. Anything from /opt/homebrew,
# /usr/local, or a user homedir is a host-only library that won't exist on the
# end user's Mac and will produce a launch-time dyld error.
LEAK=$(otool -L "$BIN_OUT/ffmpeg" "$BIN_OUT/ffprobe" \
    | awk '/^\t/ {print $1}' \
    | grep -E '^(/usr/local|/opt/homebrew|/Users/)' || true)
if [[ -n "$LEAK" ]]; then
    echo
    echo "ERROR: bundled binaries link against host libraries:" >&2
    echo "$LEAK" >&2
    echo
    echo "Every dep should be statically linked or come from /usr/lib or /System/."  >&2
    echo "Re-check the configure flags for the leaky lib." >&2
    exit 1
fi

echo "==> Smoke test"
"$BIN_OUT/ffmpeg" -hide_banner -version | head -1 | sed 's/^/    /'

# ffmpeg's --enable-decoder/--enable-encoder accepts unknown names silently
# (no warning, no error) — a typo means the decoder is missing from the
# binary and the pipeline fails per-file at runtime with a confusing message.
# Verify each name we care about appears in the actual output.
ENCODERS=$("$BIN_OUT/ffmpeg" -hide_banner -encoders 2>/dev/null)
DECODERS=$("$BIN_OUT/ffmpeg" -hide_banner -decoders 2>/dev/null)
MUXERS=$("$BIN_OUT/ffmpeg"   -hide_banner -muxers   2>/dev/null)
DEMUXERS=$("$BIN_OUT/ffmpeg" -hide_banner -demuxers 2>/dev/null)
FILTERS=$("$BIN_OUT/ffmpeg"  -hide_banner -filters  2>/dev/null)

require_in() {
    # require_in <list-name> <list-content> <expected> [<expected>...]
    # Matches the codec/format name as a comma- or whitespace-delimited
    # token. ffmpeg's `-demuxers` output groups aliases on one line
    # (e.g. "mov,mp4,m4a,3gp,3g2,mj2") so the matcher has to accept commas
    # as separators, not just spaces. Boundary chars on both sides keep
    # `aac` from false-matching `aac_at`.
    local name="$1" list="$2"; shift 2
    local missing=()
    for item in "$@"; do
        if ! grep -qE "[[:space:],]${item}[[:space:],]" <<< "$list"; then
            missing+=("$item")
        fi
    done
    if (( ${#missing[@]} > 0 )); then
        echo "ERROR: $name missing: ${missing[*]}" >&2
        return 1
    fi
}

# Names the Swift pipeline depends on. The display names from `ffmpeg
# -encoders` / `-decoders` differ from the `--enable-X=...` configure
# names for one outlier — `movtext` configure name shows as `mov_text` in
# the listing. Other names (pgssub/dvdsub/dvbsub) match their configure
# names exactly.
# Update together with the configure flag set above when you add a
# codec/format to a new call site.
require_in "encoders" "$ENCODERS" hevc_videotoolbox aac mov_text mjpeg subrip
require_in "decoders" "$DECODERS" h264 hevc aac ac3 eac3 dca flac opus mp3 vorbis ass subrip mov_text webvtt pgssub dvdsub dvbsub
require_in "muxers"   "$MUXERS"   mp4 matroska image2 mjpeg srt
require_in "demuxers" "$DEMUXERS" mov matroska mpegts avi flac
# Filters use "name" alignment that's different — match by surrounding spaces.
for f in scale subtitles overlay aresample aformat; do
    grep -qE " ${f} +[A-Z]+->[A-Z]+ " <<< "$FILTERS" || { echo "ERROR: filter missing: $f" >&2; exit 1; }
done

ls -lh "$BIN_OUT/ffmpeg" "$BIN_OUT/ffprobe" | awk '{print "    " $5 "  " $NF}'

echo
echo "==> Done."
echo "    Pass to build-app.sh:  --bundle-ffmpeg $BIN_OUT"
