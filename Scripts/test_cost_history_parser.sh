#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
MODULE_CACHE="$TMP/module-cache"
mkdir -p "$MODULE_CACHE"

cp "$ROOT/Scripts/cost_history_parser_regression.swift" "$TMP/main.swift"
swiftc \
  -module-cache-path "$MODULE_CACHE" \
  "$ROOT/Sources/AIUsageBar/CostHistoryPayload.swift" \
  "$TMP/main.swift" \
  -o "$TMP/cost-history-regression"
"$TMP/cost-history-regression"

cp "$ROOT/Scripts/quota_trend_store_regression.swift" "$TMP/main.swift"
swiftc \
  -module-cache-path "$MODULE_CACHE" \
  "$ROOT/Sources/AIUsageBar/Models.swift" \
  "$ROOT/Sources/AIUsageBar/JSONHelpers.swift" \
  "$ROOT"/Sources/AIUsageBar/L10n*.swift \
  "$ROOT/Sources/AIUsageBar/LocalQuotaTrendStore.swift" \
  "$TMP/main.swift" \
  -o "$TMP/quota-trend-regression"
"$TMP/quota-trend-regression"

cp "$ROOT/Scripts/local_spend_history_regression.swift" "$TMP/main.swift"
swiftc \
  -module-cache-path "$MODULE_CACHE" \
  "$ROOT/Sources/AIUsageBar/Models.swift" \
  "$ROOT/Sources/AIUsageBar/JSONHelpers.swift" \
  "$ROOT"/Sources/AIUsageBar/L10n*.swift \
  "$ROOT/Sources/AIUsageBar/ProviderFinance.swift" \
  "$ROOT/Sources/AIUsageBar/LocalSpendHistoryStore.swift" \
  "$TMP/main.swift" \
  -o "$TMP/local-spend-regression"
"$TMP/local-spend-regression"

cp "$ROOT/Scripts/token_history_store_regression.swift" "$TMP/main.swift"
swiftc \
  -module-cache-path "$MODULE_CACHE" \
  "$ROOT/Sources/AIUsageBar/Models.swift" \
  "$ROOT/Sources/AIUsageBar/JSONHelpers.swift" \
  "$ROOT"/Sources/AIUsageBar/L10n*.swift \
  "$ROOT/Sources/AIUsageBar/CostHistoryPayload.swift" \
  "$ROOT/Sources/AIUsageBar/LocalTokenHistoryStore.swift" \
  "$TMP/main.swift" \
  -o "$TMP/token-history-regression"
"$TMP/token-history-regression"

cp "$ROOT/Scripts/model_attribution_regression.swift" "$TMP/main.swift"
swiftc \
  -module-cache-path "$MODULE_CACHE" \
  "$ROOT/Sources/AIUsageBar/Models.swift" \
  "$ROOT/Sources/AIUsageBar/JSONHelpers.swift" \
  "$ROOT"/Sources/AIUsageBar/L10n*.swift \
  "$ROOT/Sources/AIUsageBar/CostHistoryPayload.swift" \
  "$ROOT/Sources/AIUsageBar/LocalTokenHistoryStore.swift" \
  "$TMP/main.swift" \
  -o "$TMP/model-attribution-regression"
"$TMP/model-attribution-regression"

swiftc -module-cache-path "$MODULE_CACHE" \
  "$ROOT/Sources/AIUsageBar/CostHistoryPayload.swift" \
  "$ROOT/Sources/AIUsageBar/CurrencyDisplay.swift" \
  "$ROOT/Scripts/usage_value_regression.swift" \
  -o "$TMP/usage-value-regression"
"$TMP/usage-value-regression"

swiftc -module-cache-path "$MODULE_CACHE" \
  "$ROOT/Sources/AIUsageBar/Models.swift" \
  "$ROOT/Sources/AIUsageBar/JSONHelpers.swift" \
  "$ROOT"/Sources/AIUsageBar/L10n*.swift \
  "$ROOT/Sources/AIUsageBar/SubscriptionTiming.swift" \
  "$ROOT/Scripts/subscription_timing_regression.swift" \
  -o "$TMP/subscription-timing-regression"
"$TMP/subscription-timing-regression"

swiftc -module-cache-path "$MODULE_CACHE" \
  "$ROOT/Sources/AIUsageBar/Models.swift" \
  "$ROOT/Sources/AIUsageBar/JSONHelpers.swift" \
  "$ROOT"/Sources/AIUsageBar/L10n*.swift \
  "$ROOT/Sources/AIUsageBar/ClaudeQuotaHistory.swift" \
  "$ROOT/Scripts/claude_quota_history_regression.swift" \
  -o "$TMP/claude-quota-history-regression"
"$TMP/claude-quota-history-regression"
