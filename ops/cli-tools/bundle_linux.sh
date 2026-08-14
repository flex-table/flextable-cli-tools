#!/usr/bin/env bash
# Bundle a portable, self-contained set of PostgreSQL client tools for Linux.
#
# pg_dump/pg_restore/psql are NOT static - they dynamic-link libpq + OpenSSL +
# friends. This copies each tool plus its non-system .so closure into one
# directory and rewrites the ELF rpath to $ORIGIN-relative (via patchelf), so the
# bundle runs on a machine that has no PostgreSQL installed. The result is zipped
# and sha256'd for the signed manifest. This is the Linux analogue of
# bundle_macos.sh (@loader_path -> $ORIGIN, otool/install_name_tool -> ldd/patchelf,
# no codesign).
#
# Layout produced (everything the app installs into tools/postgresql-<major>/):
#   <out>/postgresql-<major>-linux-<arch>/
#     pg_dump  pg_restore  psql            # executables (rpath = $ORIGIN/lib)
#     lib/ libpq.so.5 libssl.so.3 …        # bundled deps (rpath = $ORIGIN)
#
# Install contract (tool_downloader.rs `stage_and_swap` + `detect_bundle_root`):
# the zip's single top-level dir is the bundle ROOT; the installer copies its
# CONTENTS up, so the app ends with tools/postgresql-<major>/pg_dump and
# tools/postgresql-<major>/lib/libpq.so.5 (NOT a nested wrapper dir). This
# single-wrapper-dir layout is the proven, correct shape - do not flatten it here.
#
# The installer's `copy_tree` REJECTS symlinks as a path-escape guard, so each
# bundled .so is a REAL file (never a `.so.N` -> `.so.N.M` symlink). Its NAME is
# the SONAME the consumer's ELF asks for (the `ldd` left column, e.g.
# `libpq.so.5`); its CONTENT is the `realpath`-resolved real file (e.g.
# `libpq.so.5.17`). Naming the real file by its own basename would break the
# loader, which requests the SONAME and cannot follow a symlink we are not allowed
# to ship. Build inside an older-glibc container (manylinux / ubuntu-20.04) so the
# bundle runs on newer hosts.
#
# Usage:
#   ops/cli-tools/bundle_linux.sh <src_bin_dir> <major> <arch> <out_dir>
# Example (PGDG / postgres:17 container binaries):
#   ops/cli-tools/bundle_linux.sh /usr/lib/postgresql/17/bin 17 x86_64 dist
set -euo pipefail

SRC_BIN="${1:?source bin dir (e.g. /usr/lib/postgresql/17/bin)}"
MAJOR="${2:?postgres major (e.g. 17)}"
ARCH="${3:?arch: x86_64 | arm64}"
OUT="${4:?output dir}"

# Defaults to the PostgreSQL tool set/namespace; override via env for another
# engine, e.g. `BUNDLE_NAMESPACE=mysql BUNDLE_TOOLS="mysqldump mysql"`. MAJOR is a
# free version label (e.g. `9` for MySQL). Keep pg behavior byte-identical when
# the env vars are unset.
NAMESPACE="${BUNDLE_NAMESPACE:-postgresql}"
read -ra TOOLS <<< "${BUNDLE_TOOLS:-pg_dump pg_restore psql}"
NAME="${NAMESPACE}-${MAJOR}-linux-${ARCH}"
STAGE="${OUT}/${NAME}"
LIBDIR="${STAGE}/lib"

rm -rf "$STAGE"
mkdir -p "$LIBDIR"
# Normalize LIBDIR to an absolute path so the leak-check (which compares against
# `realpath` output) is not fooled by a relative OUT (e.g. `dist`): a relative
# ${LIBDIR} would never prefix-match an absolute realpath and bundled libs would
# be falsely reported as leaks.
LIBDIR="$(cd "$LIBDIR" && pwd)"
# Absolute path to each staged executable, mirroring the tool set.
EXES=(); for _t in "${TOOLS[@]}"; do EXES+=("${STAGE}/${_t}"); done

# A .so is "system" (never bundled) when it is part of the glibc baseline that is
# guaranteed present + ABI-stable on every Linux host. Matching the macOS
# /usr/lib + /System skip: ship everything else (libpq, OpenSSL, libldap, …).
is_system() {
  local base; base="$(basename "$1")"
  case "$base" in
    linux-vdso.so* | ld-linux*.so* | libc.so* | libm.so* | libdl.so* \
    | libpthread.so* | librt.so* | libresolv.so*)
      return 0
      ;;
  esac
  return 1
}

# Resolve a path to its real on-disk file (a .so.N symlink -> the real .so.N.M).
realso() { python3 -c "import os,sys;print(os.path.realpath(sys.argv[1]))" "$1"; }

# Recursively copy a binary's non-system .so closure into lib/. The bundled FILE
# is named by the SONAME the loader requests (the `ldd` LEFT column), while its
# CONTENT is the realpath-resolved real file (the right column dereferenced) - a
# real file under the name the consumer's DT_NEEDED asks for, since copy_tree
# rejects the symlink we would otherwise need. Dedup is by presence of lib/<name>.
# `ldd` already walks the transitive closure, but we still recurse each copied .so
# so a dep reachable only through a non-system lib is never missed.
copy_deps() {
  local bin="$1"
  while IFS= read -r line; do
    # ldd lines: "libpq.so.5 => /usr/lib/x86_64-linux-gnu/libpq.so.5 (0x...)".
    # Skip the "not a dynamic executable" / "statically linked" / vdso / ld.so
    # lines that have no "=> /path".
    local needed name path target
    needed="$(awk '{print $1}' <<<"$line")"   # SONAME (left column)
    is_system "$needed" && continue
    case "$line" in
      *"=> /"*) path="$(awk '{print $3}' <<<"$line")" ;;
      *) continue ;;
    esac
    [[ -n "$path" && -e "$path" ]] || continue
    is_system "$path" && continue
    name="$(basename "$needed")"               # bundle under the requested SONAME
    target="$(realso "$path")"                 # content = the real file
    [[ -f "${LIBDIR}/${name}" ]] && continue   # already bundled
    cp -f "$target" "${LIBDIR}/${name}"
    chmod 0644 "${LIBDIR}/${name}"
    copy_deps "${LIBDIR}/${name}"
  done < <(ldd "$bin" 2>/dev/null || true)
}

echo "==> staging $NAME"
for t in "${TOOLS[@]}"; do
  src="${SRC_BIN}/${t}"
  [[ -x "$src" ]] || { echo "missing executable: $src" >&2; exit 1; }
  cp -f "$src" "${STAGE}/${t}"
  chmod 0755 "${STAGE}/${t}"
  copy_deps "${STAGE}/${t}"
done

echo "==> rewriting rpath -> \$ORIGIN (no codesign on Linux)"
# Executables load their deps from the sibling lib/ dir; each bundled .so loads
# its peers from its own dir. patchelf needs no re-sign (unlike macOS).
for t in "${TOOLS[@]}"; do
  patchelf --set-rpath '$ORIGIN/lib' "${STAGE}/${t}"
done
for lib in "${LIBDIR}"/*; do
  [[ -e "$lib" ]] || continue
  patchelf --set-rpath '$ORIGIN' "$lib"
done

echo "==> verifying no unbundled, non-system deps remain"
# Re-run ldd with lib/ on the search path: every non-system dep must now resolve
# to a file we bundled (i.e. live under lib/). A dep that still resolves outside
# the bundle - or is reported "not found" - is a leak that breaks a clean host.
fail=0
for f in "${EXES[@]}" "${LIBDIR}"/*; do
  [[ -e "$f" ]] || continue
  while IFS= read -r line; do
    soname="$(awk '{print $1}' <<<"$line")"
    is_system "$soname" && continue
    case "$line" in
      *"not found"*)
        echo "  LEAK: $(basename "$f") -> $soname not found" >&2; fail=1
        ;;
      *"=> /"*)
        path="$(awk '{print $3}' <<<"$line")"
        is_system "$path" && continue
        if [[ "$(realso "$path")" != "${LIBDIR}/"* ]]; then
          echo "  LEAK: $(basename "$f") -> $path (unbundled)" >&2; fail=1
        fi
        ;;
    esac
  done < <(LD_LIBRARY_PATH="$LIBDIR" ldd "$f" 2>/dev/null || true)
done
[[ "$fail" == 0 ]] || { echo "unbundled deps remain - bundle is not portable" >&2; exit 1; }

echo "==> verifying the bundle is symlink-free (installer copy_tree rejects symlinks)"
if find "$STAGE" -type l -print -quit | grep -q .; then
  echo "symlink found in bundle - copy_tree would reject it" >&2
  find "$STAGE" -type l >&2
  exit 1
fi

echo "==> zipping + sha256"
ZIP="${OUT}/${NAME}.zip"
( cd "$OUT" && rm -f "${NAME}.zip" && zip -qry "${NAME}.zip" "${NAME}" )
SHA="$(sha256sum "$ZIP" | awk '{print $1}')"
SIZE_MB="$(python3 -c "import os,sys;print(round(os.path.getsize(sys.argv[1])/1048576,1))" "$ZIP")"

echo ""
echo "bundle : $ZIP"
echo "sha256 : $SHA"
echo "sizeMb : $SIZE_MB"
echo "platform-key: linux-${ARCH}"
