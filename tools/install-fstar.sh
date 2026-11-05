#!/usr/bin/env bash
# Install a pinned F*/Pulse toolchain into tools/fstar.
#
# There are two kinds of pin, so that the local toolchain and CI cannot drift:
#
#  * tools/fstar-source.txt, if it exists: F* built from source at a fixed commit,
#    optionally with a second fixed commit merged in. This is how the repository
#    tracks an F* pull request that has no nightly yet.
#  * otherwise tools/fstar-version.txt: a nightly binary release.
#
# Either way the result has the binary-release layout (bin/fstar.exe,
# lib/fstar/{ulib,pulse,z3-*}), so tools/run-fstar.sh does not care which it is.
#
# Usage:  tools/install-fstar.sh [extra install-fstar.sh options]
#         tools/install-fstar.sh --list      # show available nightlies
#
# A source build needs an OCaml switch with F*'s dependencies (see F*'s
# INSTALL.md); FSTAR_SRC overrides where the checkout is kept, and FSTAR_JOBS the
# build parallelism, FSTAR_MAKE overrides GNU make (4.x or newer), and
# FSTAR_OPAM_DEPS=1 installs F*'s opam dependencies first.

set -euo pipefail

TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_PIN="$TOOLS_DIR/fstar-source.txt"

if [[ ! -f "$SOURCE_PIN" ]]; then
  VERSION="$(tr -d '[:space:]' < "$TOOLS_DIR/fstar-version.txt")"
  curl -fsSL https://aka.ms/install-fstar | bash -s -- \
    --nightly \
    --version "$VERSION" \
    --dest "$TOOLS_DIR/fstar" \
    --no-link \
    "$@"
  exit 0
fi

pin() { sed -n "s/^$1=//p" "$SOURCE_PIN" | tr -d '[:space:]'; }
REPO="$(pin repo)"; PR="$(pin pr)"; COMMIT="$(pin commit)"
MERGE="$(pin merge)"; Z3="$(pin z3)"
SRC="${FSTAR_SRC:-$TOOLS_DIR/fstar-src}"
shopt -s nullglob
PATCHES=("$TOOLS_DIR"/fstar-patches/*.patch)
BUILD_ID="$(cat "$SOURCE_PIN" "$TOOLS_DIR/install-fstar.sh" ${PATCHES[@]+"${PATCHES[@]}"} | git hash-object --stdin)"

# Already installed at the pinned, patched tree: nothing to do. `make` decides by timestamps, and
# a checkout or merge that rewrites the pin file must not cost a full F* rebuild.
if [[ -n "$(pin result)" && -x "$TOOLS_DIR/fstar/bin/fstar.exe" &&
      "$(cat "$TOOLS_DIR/fstar/version.txt" 2>/dev/null)" == "$(pin result)" &&
      "$(cat "$TOOLS_DIR/fstar/build-id.txt" 2>/dev/null)" == "$BUILD_ID" ]]; then
  touch "$TOOLS_DIR/fstar/bin/fstar.exe"
  exit 0
fi
JOBS="${FSTAR_JOBS:-$(nproc 2>/dev/null || echo 4)}"

MAKE_BIN="${FSTAR_MAKE:-}"
if [[ -z "$MAKE_BIN" ]]; then
  if command -v gmake >/dev/null 2>&1; then
    MAKE_BIN=gmake
  else
    MAKE_BIN=make
  fi
fi
MAKE_VERSION="$("$MAKE_BIN" --version 2>/dev/null | sed -n '1s/^GNU Make \([0-9]*\).*/\1/p')" || true
if [[ ! "$MAKE_VERSION" =~ ^[0-9]+$ ]] || (( MAKE_VERSION < 4 )); then
  echo "error: F* needs GNU make >= 4; on macOS run 'brew install make', or set FSTAR_MAKE" >&2
  exit 1
fi

if [[ ! -d "$SRC/.git" ]]; then
  git clone --filter=blob:none "$REPO" "$SRC"
fi
cd "$SRC"
git fetch --quiet origin ${PR:+"pull/$PR/head"} "$COMMIT" ${MERGE:+"$MERGE"} || git fetch --quiet origin
git -c advice.detachedHead=false checkout --quiet --force "$COMMIT"
if [[ -n "$MERGE" ]]; then
  # A fixed identity and date make the merge commit, and so `fstar.exe --version`,
  # the same on every machine.
  GIT_AUTHOR_DATE=2000-01-01T00:00:00Z GIT_COMMITTER_DATE=2000-01-01T00:00:00Z \
    git -c user.name=pal-csharp -c user.email=pal-csharp@invalid \
      merge --quiet --no-edit --no-ff "$MERGE"
fi
RESULT="$(pin result)"
if [[ -n "$RESULT" && "$(git rev-parse HEAD)" != "$RESULT" ]]; then
  echo "error: built tree is $(git rev-parse HEAD), but $SOURCE_PIN pins result=$RESULT" >&2
  exit 1
fi
for patch in ${PATCHES[@]+"${PATCHES[@]}"}; do
  git apply --check "$patch"
  git apply "$patch"
done
git submodule update --init --quiet karamel
if [[ "${FSTAR_OPAM_DEPS:-0}" == 1 ]]; then
  opam install --yes --deps-only ./fstar.opam
fi
# Building F* checks ulib and Pulse, and F* looks for `z3-<version>` on PATH to do
# that. A fresh machine (CI) has none, so put the solvers on PATH for the build.
Z3_BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$Z3_BUILD_DIR"' EXIT
"$SRC/.scripts/get_fstar_z3.sh" "$Z3_BUILD_DIR" >/dev/null
PATH="$Z3_BUILD_DIR:$PATH" "$MAKE_BIN" -j"$JOBS" 3

rm -rf "$TOOLS_DIR/fstar"
mkdir -p "$TOOLS_DIR/fstar"
# `out` is a dev layout of symlinks into the source tree: copy what they point at,
# so that tools/fstar is self-contained (and cacheable) rather than links into $SRC.
cp -aL "$SRC/out/." "$TOOLS_DIR/fstar/"
# The PR's effects library (Pulse.Lib.Effects.*) is checked into lib.pulse.checked
# but its directory is missing from the installed lib/fstar.include, so its sources
# cannot be found. Add it.
PULSE_LIB="$TOOLS_DIR/fstar/lib/fstar/pulse/pulse/lib"
if [ -d "$PULSE_LIB/effects" ] && ! grep -qx effects "$PULSE_LIB/fstar.include"; then
  echo effects >> "$PULSE_LIB/fstar.include"
fi
"$SRC/.scripts/get_fstar_z3.sh" --full "$TOOLS_DIR/fstar/lib/fstar" >/dev/null
# Only the pinned solver is kept: F* chooses its solver by version, and a stray one
# would be a second, unpinned way for a proof to pass.
find "$TOOLS_DIR/fstar/lib/fstar" -maxdepth 1 -name 'z3-*' ! -name "z3-$Z3" -exec rm -rf {} +
git rev-parse HEAD > "$TOOLS_DIR/fstar/version.txt"
printf '%s\n' "$BUILD_ID" > "$TOOLS_DIR/fstar/build-id.txt"
