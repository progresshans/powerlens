#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/lib/powerlens_packaging.sh"

BUILD_SYSTEM="${POWERLENS_BUILD_SYSTEM:-native}"

case "$BUILD_SYSTEM" in
  native|swiftbuild)
    ;;
  *)
    echo "unsupported SwiftPM build system: $BUILD_SYSTEM" >&2
    echo "expected native or swiftbuild" >&2
    exit 2
    ;;
esac

cd "$ROOT_DIR"

swiftpm_args=(
  --build-system "$BUILD_SYSTEM"
  --arch "$POWERLENS_BUILD_ARCH"
)

if [[ "$BUILD_SYSTEM" == "native" ]]; then
  swift test "${swiftpm_args[@]}"
  exit 0
fi

# SwiftBuild currently places Sparkle.framework beside the debug products but
# does not stage it in PackageFrameworks, even though the generated test bundle
# has an @rpath entry for that directory. Build first, fill only that missing
# runtime location, then execute the exact SwiftBuild-produced tests.
swift build --build-tests "${swiftpm_args[@]}"

build_dir="$(swift build "${swiftpm_args[@]}" --show-bin-path)"
sparkle_source="$build_dir/Sparkle.framework"
sparkle_destination="$build_dir/PackageFrameworks/Sparkle.framework"

if [[ ! -d "$sparkle_source" ]]; then
  sparkle_source="$POWERLENS_SPARKLE_FRAMEWORK_SOURCE"
fi

powerlens_require_directory "$sparkle_source"
mkdir -p "$(dirname "$sparkle_destination")"

if ! cmp -s \
  "$sparkle_source/Versions/Current/Sparkle" \
  "$sparkle_destination/Versions/Current/Sparkle"; then
  ditto --noqtn --noextattr "$sparkle_source" "$sparkle_destination"
fi

if [[ ! -x "$sparkle_destination/Versions/Current/Sparkle" ]]; then
  echo "failed to stage Sparkle.framework for SwiftBuild tests" >&2
  exit 2
fi

swift test --skip-build "${swiftpm_args[@]}"
