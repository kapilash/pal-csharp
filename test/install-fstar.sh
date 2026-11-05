#!/usr/bin/env bash
# Exercise the source installer without downloading or compiling a toolchain.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export REAL_GIT="$(command -v git)"
export BUILD_LOG="$TMP/build.log"
mkdir -p "$TMP/tools/fstar-patches" "$TMP/bin" "$TMP/source/.scripts"
cp "$ROOT/tools/install-fstar.sh" "$TMP/tools/"

cat > "$TMP/bin/git" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  fetch|submodule) exit 0 ;;
  *) exec "$REAL_GIT" "$@" ;;
esac
EOF
cat > "$TMP/bin/gmake" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == --version ]]; then
  echo "GNU Make 4.4"
  exit
fi
printf '%s %s\n' "$(basename "$0")" "$*" >> "$BUILD_LOG"
grep -qx patched proof.txt
mkdir -p out/bin out/lib/fstar/pulse/pulse/lib/effects
printf '#!/usr/bin/env bash\nexit 0\n' > out/bin/fstar.exe
chmod +x out/bin/fstar.exe
touch out/lib/fstar/pulse/pulse/lib/fstar.include
EOF
cat > "$TMP/bin/make" <<'EOF'
#!/usr/bin/env bash
echo "GNU Make 3.81"
EOF
cat > "$TMP/source/.scripts/get_fstar_z3.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == --full ]]; then
  mkdir -p "$2/z3-5.3.0/bin" "$2/z3-4.13.3/bin"
fi
EOF
chmod +x "$TMP/bin/"* "$TMP/source/.scripts/get_fstar_z3.sh"
export PATH="$TMP/bin:$PATH"
export FSTAR_SRC="$TMP/source" FSTAR_JOBS=2 FSTAR_OPAM_DEPS=0
unset FSTAR_MAKE
git -C "$FSTAR_SRC" init --quiet
printf 'original\n' > "$FSTAR_SRC/proof.txt"
git -C "$FSTAR_SRC" add .
git -C "$FSTAR_SRC" -c user.name=Test -c user.email=test@invalid commit --quiet -m fixture
COMMIT="$(git -C "$FSTAR_SRC" rev-parse HEAD)"
printf 'commit=%s\nresult=%s\nz3=5.3.0\n' "$COMMIT" "$COMMIT" > "$TMP/tools/fstar-source.txt"
cat > "$TMP/tools/fstar-patches/proof.patch" <<'EOF'
diff --git a/proof.txt b/proof.txt
--- a/proof.txt
+++ b/proof.txt
@@ -1 +1 @@
-original
+patched
EOF

install_toolchain() { bash "$TMP/tools/install-fstar.sh"; }
expect_failure() {
  if install_toolchain > "$TMP/error.log" 2>&1; then
    echo "expected installer failure" >&2
    exit 1
  fi
}

# Reject old make before fetching or building, even with no patches (Bash 3.2).
mv "$TMP/tools/fstar-patches/proof.patch" "$TMP/proof.patch"
export FSTAR_MAKE=make
expect_failure
grep -q 'GNU make >= 4' "$TMP/error.log"
mv "$TMP/proof.patch" "$TMP/tools/fstar-patches/proof.patch"
unset FSTAR_MAKE

install_toolchain
grep -qx 'gmake -j2 3' "$BUILD_LOG"
test "$(cat "$TMP/tools/fstar/version.txt")" = "$COMMIT"
test "$(git -C "$FSTAR_SRC" rev-parse HEAD)" = "$COMMIT"
grep -qx effects "$TMP/tools/fstar/lib/fstar/pulse/pulse/lib/fstar.include"
test -d "$TMP/tools/fstar/lib/fstar/z3-5.3.0"
test ! -e "$TMP/tools/fstar/lib/fstar/z3-4.13.3"

# A second install must reuse the patched build; a legacy commit-only stamp must not.
install_toolchain
test "$(wc -l < "$BUILD_LOG" | tr -d ' ')" = 1
rm "$TMP/tools/fstar/build-id.txt"
install_toolchain
test "$(wc -l < "$BUILD_LOG" | tr -d ' ')" = 2
OLD_ID="$(cat "$TMP/tools/fstar/build-id.txt")"

# Patch edits and installer edits must each invalidate the build stamp.
printf '\n' >> "$TMP/tools/fstar-patches/proof.patch"
cp "$TMP/bin/gmake" "$TMP/bin/custom-make"
export FSTAR_MAKE="$TMP/bin/custom-make"
install_toolchain
test "$(wc -l < "$BUILD_LOG" | tr -d ' ')" = 3
grep -qx 'custom-make -j2 3' "$BUILD_LOG"
test "$(cat "$TMP/tools/fstar/build-id.txt")" != "$OLD_ID"
printf '\n' >> "$TMP/tools/install-fstar.sh"
install_toolchain
test "$(wc -l < "$BUILD_LOG" | tr -d ' ')" = 4

# Fail closed if a patch no longer applies, leaving the previous install intact.
printf 'not a patch\n' > "$TMP/tools/fstar-patches/proof.patch"
expect_failure
test "$(wc -l < "$BUILD_LOG" | tr -d ' ')" = 4
test -x "$TMP/tools/fstar/bin/fstar.exe"
echo "Source installer tests passed"
