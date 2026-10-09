#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
MODULE_CACHE="$TMP/module-cache"
mkdir -p "$MODULE_CACHE"

cp "$ROOT/Scripts/provider_auth_config_regression.swift" "$TMP/main.swift"
swiftc \
  -module-cache-path "$MODULE_CACHE" \
  "$ROOT/Sources/AIUsageBar/ProviderAuthentication.swift" \
  "$ROOT/Sources/AIUsageBar/ProviderConfigStore.swift" \
  "$ROOT/Sources/AIUsageBar/Models.swift" \
  "$ROOT/Sources/AIUsageBar/JSONHelpers.swift" \
  "$ROOT"/Sources/AIUsageBar/L10n*.swift \
  "$TMP/main.swift" \
  -o "$TMP/provider-auth-regression"

"$TMP/provider-auth-regression"
