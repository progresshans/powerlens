POWERLENS_ROOT_DIR="${POWERLENS_ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
POWERLENS_APP_NAME="${POWERLENS_APP_NAME:-PowerLens}"
POWERLENS_BUNDLE_ID="${POWERLENS_BUNDLE_ID:-com.progresshans.powerlens}"
POWERLENS_MIN_SYSTEM_VERSION="${POWERLENS_MIN_SYSTEM_VERSION:-13.0}"
POWERLENS_PACKAGING_DIR="${POWERLENS_PACKAGING_DIR:-$POWERLENS_ROOT_DIR/Packaging}"
POWERLENS_SOURCE_INFO_PLIST="${POWERLENS_SOURCE_INFO_PLIST:-$POWERLENS_PACKAGING_DIR/Info.plist}"
POWERLENS_SOURCE_ICON="${POWERLENS_SOURCE_ICON:-$POWERLENS_PACKAGING_DIR/AppIcon.icns}"
POWERLENS_ENTITLEMENTS="${POWERLENS_ENTITLEMENTS:-$POWERLENS_PACKAGING_DIR/PowerLens.entitlements}"
POWERLENS_SPARKLE_FRAMEWORK_SOURCE="${POWERLENS_SPARKLE_FRAMEWORK_SOURCE:-$POWERLENS_ROOT_DIR/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework}"
POWERLENS_SPARKLE_GENERATE_APPCAST_TOOL="${POWERLENS_SPARKLE_GENERATE_APPCAST_TOOL:-$POWERLENS_ROOT_DIR/.build/artifacts/sparkle/Sparkle/bin/generate_appcast}"

powerlens_default_build_number() {
  git -C "$POWERLENS_ROOT_DIR" rev-list --count HEAD 2>/dev/null || echo 1
}

powerlens_require_file() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    echo "missing required file: $path" >&2
    exit 2
  fi
}

powerlens_require_directory() {
  local path="$1"
  if [[ ! -d "$path" ]]; then
    echo "missing required directory: $path" >&2
    exit 2
  fi
}

powerlens_set_plist_string() {
  local plist="$1"
  local key="$2"
  local value="$3"

  if /usr/libexec/PlistBuddy -c "Print :$key" "$plist" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c "Set :$key $value" "$plist"
  else
    /usr/libexec/PlistBuddy -c "Add :$key string $value" "$plist"
  fi
}

powerlens_set_plist_bool() {
  local plist="$1"
  local key="$2"
  local value="$3"

  if /usr/libexec/PlistBuddy -c "Print :$key" "$plist" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c "Set :$key $value" "$plist"
  else
    /usr/libexec/PlistBuddy -c "Add :$key bool $value" "$plist"
  fi
}

powerlens_set_plist_integer() {
  local plist="$1"
  local key="$2"
  local value="$3"

  if /usr/libexec/PlistBuddy -c "Print :$key" "$plist" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c "Set :$key $value" "$plist"
  else
    /usr/libexec/PlistBuddy -c "Add :$key integer $value" "$plist"
  fi
}

powerlens_delete_plist_key_if_present() {
  local plist="$1"
  local key="$2"
  /usr/libexec/PlistBuddy -c "Delete :$key" "$plist" >/dev/null 2>&1 || true
}

powerlens_strip_extended_attributes() {
  local path="$1"

  if command -v xattr >/dev/null 2>&1 && [[ -e "$path" ]]; then
    xattr -cr "$path" 2>/dev/null || true
  fi
}

powerlens_copy_sparkle_framework() {
  local app_frameworks="$1"
  local app_binary="$2"

  powerlens_require_directory "$POWERLENS_SPARKLE_FRAMEWORK_SOURCE"
  ditto --noqtn --noextattr "$POWERLENS_SPARKLE_FRAMEWORK_SOURCE" "$app_frameworks/Sparkle.framework"
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$app_binary" 2>/dev/null || true
}

powerlens_copy_resource_bundle() {
  local build_dir="$1"
  local app_resources="$2"
  local resource_bundle="$build_dir/${POWERLENS_APP_NAME}_${POWERLENS_APP_NAME}.bundle"

  if [[ -d "$resource_bundle" ]]; then
    ditto --noqtn --noextattr "$resource_bundle" "$app_resources/$(basename "$resource_bundle")"
  fi
}

powerlens_apply_common_info_plist() {
  local plist="$1"
  local version="$2"
  local build_number="$3"
  local sparkle_feed_url="$4"
  local sparkle_alpha_feed_url="$5"
  local sparkle_public_ed_key="$6"
  local include_display_name="${7:-0}"

  powerlens_set_plist_string "$plist" "CFBundleExecutable" "$POWERLENS_APP_NAME"
  powerlens_set_plist_string "$plist" "CFBundleIdentifier" "$POWERLENS_BUNDLE_ID"
  powerlens_set_plist_string "$plist" "CFBundleName" "$POWERLENS_APP_NAME"
  if [[ "$include_display_name" == "1" ]]; then
    powerlens_set_plist_string "$plist" "CFBundleDisplayName" "$POWERLENS_APP_NAME"
  fi
  powerlens_set_plist_string "$plist" "CFBundleShortVersionString" "$version"
  powerlens_set_plist_string "$plist" "CFBundleVersion" "$build_number"
  powerlens_set_plist_string "$plist" "LSMinimumSystemVersion" "$POWERLENS_MIN_SYSTEM_VERSION"
  powerlens_set_plist_string "$plist" "SUFeedURL" "$sparkle_feed_url"
  powerlens_set_plist_string "$plist" "SUAlphaFeedURL" "$sparkle_alpha_feed_url"
  powerlens_set_plist_bool "$plist" "SUAutomaticallyUpdate" "false"
  powerlens_set_plist_bool "$plist" "SUEnableAutomaticChecks" "false"
  powerlens_set_plist_bool "$plist" "SUEnableSystemProfiling" "false"
  powerlens_set_plist_integer "$plist" "SUScheduledCheckInterval" "86400"

  if [[ -n "$sparkle_public_ed_key" ]]; then
    powerlens_set_plist_string "$plist" "SUPublicEDKey" "$sparkle_public_ed_key"
  else
    powerlens_delete_plist_key_if_present "$plist" "SUPublicEDKey"
  fi
}

powerlens_copy_app_icon() {
  local plist="$1"
  local app_resources="$2"

  if [[ -f "$POWERLENS_SOURCE_ICON" ]]; then
    cp "$POWERLENS_SOURCE_ICON" "$app_resources/AppIcon.icns"
    powerlens_set_plist_string "$plist" "CFBundleIconFile" "AppIcon"
  fi
}
