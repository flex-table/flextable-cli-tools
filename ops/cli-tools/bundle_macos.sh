#!/usr/bin/env bash
# Bundle a portable, self-contained set of PostgreSQL client tools for macOS.
#
# pg_dump/pg_restore/psql are NOT static - they dynamic-link libpq + OpenSSL +
# friends. This copies each tool plus its non-system dylib closure into one
# directory and rewrites the Mach-O load paths to @loader_path-relative, so the
# bundle runs on a machine that has no PostgreSQL installed. The result is zipped
# and sha256'd for the signed manifest.
#
# Layout produced (everything the app installs into tools/postgresql-<major>/):
#   <out>/postgresql-<major>-macos-<arch>/
#     pg_dump  pg_restore  psql            # executables (load paths fixed)
#     lib/ libpq.5.dylib libssl.3.dylib …  # bundled deps (ids + cross-deps fixed)
#
# Install contract (tool_downloader.rs `stage_and_swap` + `detect_bundle_root`):
# the zip's single top-level dir is the bundle ROOT; the installer copies its
# CONTENTS up, so the app ends with tools/postgresql-<major>/pg_dump and
# tools/postgresql-<major>/lib/libpq.5.dylib (NOT a nested wrapper dir). This
# single-wrapper-dir layout is the proven, correct shape - do not flatten it here.
#
# Usage:
#   ops/cli-tools/bundle_macos.sh <src_bin_dir> <major> <arch> <out_dir>
# Example (Homebrew PG 17 on Apple Silicon):
#   ops/cli-tools/bundle_macos.sh /opt/homebrew/opt/postgresql@17/bin 17 arm64 dist
set -euo pipefail

SRC_BIN="${1:?source bin dir (e.g. /opt/homebrew/opt/postgresql@17/bin)}"
MAJOR="${2:?postgres major (e.g. 17)}"
ARCH="${3:?arch: arm64 | x86_64}"
OUT="${4:?output dir}"

# Defaults to the PostgreSQL tool set/namespace; override via env for another
# engine, e.g. `BUNDLE_NAMESPACE=mysql BUNDLE_TOOLS="mysqldump mysql"`. MAJOR is a
# free version label (e.g. `8.4` for a major-less engine).
NAMESPACE="${BUNDLE_NAMESPACE:-postgresql}"
read -ra TOOLS <<< "${BUNDLE_TOOLS:-pg_dump pg_restore psql}"
NAME="${NAMESPACE}-${MAJOR}-macos-${ARCH}"
STAGE="${OUT}/${NAME}"
LIBDIR="${STAGE}/lib"
EXES=(); for _t in "${TOOLS[@]}"; do EXES+=("${STAGE}/${_t}"); done

# Works from either source of binaries:
#   - an INSTALLED formula (deps are absolute /opt/homebrew paths), or
#   - an EXTRACTED, un-relocated bottle (deps are @@HOMEBREW_CELLAR@@ /
#     @@HOMEBREW_PREFIX@@ placeholders). For the bottle case the binaries live at
#     <cellar-root>/postgresql@<major>/<ver>/bin, so the cellar root is three
#     levels up from SRC_BIN; external deps still come from the live Homebrew prefix.
HBPREFIX="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
CELLAR_ROOT="$(cd "${SRC_BIN}/../../.." 2>/dev/null && pwd || true)"

rm -rf "$STAGE"
mkdir -p "$LIBDIR"

# A dylib path is "system" (never bundled) when it lives under /usr/lib or
# /System - those are guaranteed present on every macOS and ABI-stable.
is_system() { [[ "$1" == /usr/lib/* || "$1" == /System/* ]]; }

# Map a raw otool load-path to a real on-disk file: substitute Homebrew bottle
# placeholders, then resolve symlinks. A no-op for already-absolute install paths.
resolve_dep() {
  local dep="$1"
  dep="${dep//@@HOMEBREW_PREFIX@@/$HBPREFIX}"
  dep="${dep//@@HOMEBREW_CELLAR@@/$CELLAR_ROOT}"
  python3 -c "import os,sys;print(os.path.realpath(sys.argv[1]))" "$dep"
}
realdylib() { resolve_dep "$1"; }

# True for an already-relocated Mach-O load path. NOT the @@HOMEBREW...@@ bottle
# placeholders - those only start with '@' too but must still be resolved + bundled.
is_relocated() { [[ "$1" == @loader_path/* || "$1" == @rpath/* || "$1" == @executable_path/* ]]; }

# Recursively copy a dylib + its non-system deps into lib/. Dedup is by presence
# in lib/ (a dep already copied is skipped), so no associative array is needed -
# keeps this working under the stock macOS bash 3.2.
copy_deps() {
  local bin="$1"
  while IFS= read -r dep; do
    dep="${dep#"${dep%%[![:space:]]*}"}"          # ltrim
    dep="${dep%% (*}"                              # strip " (compatibility …)"
    [[ -z "$dep" ]] && continue
    is_system "$dep" && continue
    is_relocated "$dep" && continue                 # already relocated
    local real; real="$(realdylib "$dep")"
    local base; base="$(basename "$real")"
    [[ -f "${LIBDIR}/${base}" ]] && continue       # already bundled
    cp -f "$real" "${LIBDIR}/${base}"
    chmod 0644 "${LIBDIR}/${base}"
    copy_deps "${LIBDIR}/${base}"
  done < <(otool -L "$bin" | tail -n +2 | awk '{print $1}')
}

echo "==> staging $NAME"
for t in "${TOOLS[@]}"; do
  src="${SRC_BIN}/${t}"
  [[ -x "$src" ]] || { echo "missing executable: $src" >&2; exit 1; }
  cp -f "$src" "${STAGE}/${t}"
  chmod 0755 "${STAGE}/${t}"
  copy_deps "${STAGE}/${t}"
done

echo "==> rewriting load paths -> @loader_path"
# Each bundled dylib: set its own id, and point its sibling deps at @loader_path.
for lib in "${LIBDIR}"/*; do
  base="$(basename "$lib")"
  install_name_tool -id "@loader_path/${base}" "$lib"
  while IFS= read -r dep; do
    dep="${dep#"${dep%%[![:space:]]*}"}"; dep="${dep%% (*}"
    { [[ -z "$dep" ]] || is_relocated "$dep"; } && continue
    is_system "$dep" && continue
    install_name_tool -change "$dep" "@loader_path/$(basename "$(realdylib "$dep")")" "$lib"
  done < <(otool -L "$lib" | tail -n +2 | awk '{print $1}')
done
# Each executable: point its deps at @loader_path/lib/<dylib>.
for t in "${TOOLS[@]}"; do
  bin="${STAGE}/${t}"
  while IFS= read -r dep; do
    dep="${dep#"${dep%%[![:space:]]*}"}"; dep="${dep%% (*}"
    { [[ -z "$dep" ]] || is_relocated "$dep"; } && continue
    is_system "$dep" && continue
    install_name_tool -change "$dep" "@loader_path/lib/$(basename "$(realdylib "$dep")")" "$bin"
  done < <(otool -L "$bin" | tail -n +2 | awk '{print $1}')
done

echo "==> ad-hoc re-signing (install_name_tool invalidated the signatures)"
# On Apple Silicon a binary with an invalid signature is SIGKILL'd on exec. Every
# file we rewrote must be re-signed; sign dylibs before the executables.
for f in "${LIBDIR}"/* "${EXES[@]}"; do
  codesign --remove-signature "$f" 2>/dev/null || true
  codesign --force --sign - "$f"
done

echo "==> verifying no unbundled, non-system deps remain"
fail=0
for f in "${EXES[@]}" "${LIBDIR}"/*; do
  while IFS= read -r dep; do
    dep="${dep#"${dep%%[![:space:]]*}"}"; dep="${dep%% (*}"
    { [[ -z "$dep" ]] || is_relocated "$dep"; } && continue
    is_system "$dep" && continue
    echo "  LEAK: $(basename "$f") -> $dep" >&2; fail=1
  done < <(otool -L "$f" | tail -n +2 | awk '{print $1}')
done
[[ "$fail" == 0 ]] || { echo "unbundled deps remain - bundle is not portable" >&2; exit 1; }

echo "==> zipping + sha256"
ZIP="${OUT}/${NAME}.zip"
( cd "$OUT" && rm -f "${NAME}.zip" && zip -qry "${NAME}.zip" "${NAME}" )
SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
SIZE_MB="$(python3 -c "import os,sys;print(round(os.path.getsize(sys.argv[1])/1048576,1))" "$ZIP")"

echo ""
echo "bundle : $ZIP"
echo "sha256 : $SHA"
echo "sizeMb : $SIZE_MB"
echo "platform-key: macos-${ARCH}"
