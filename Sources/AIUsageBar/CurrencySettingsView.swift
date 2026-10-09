import SwiftUI

struct CurrencySettingsView: View {
    @ObservedObject var currency: CurrencySettingsStore = .shared
    @AppStorage("subscriptionDefaultUSD.codex") private var codexFee = ""
    @AppStorage("subscriptionDefaultUSD.claude") private var claudeFee = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsSection(
                title: L("Currency & subscriptions"),
                footer: L("Checks automatically every hour. Frankfurter publishes daily reference rates, not live trading quotes. Converted costs use the latest saved rate; original usage and exports keep their source currency."))
            {
                SettingsRow(
                    title: L("Display currency"),
                    symbol: "dollarsign.circle.fill",
                    symbolColor: Color(nsColor: .systemGreen))
                {
                    Picker(L("Display currency"), selection: Binding(get: { currency.selection }, set: { currency.select($0) })) {
                        ForEach(DisplayCurrency.allCases) { Text(L($0.title)).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                SettingsRowDivider(inset: 50)
                SettingsRow(
                    title: rateTitle,
                    subtitle: currency.checkedAt.map {
                        L("Last checked: %@", $0.formatted(date: .abbreviated, time: .shortened))
                    },
                    symbol: "arrow.left.arrow.right",
                    symbolColor: Color(nsColor: .systemTeal))
                {
                    Button(action: { Task { await currency.refresh(force: true) } }) {
                        if currency.isRefreshing {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 12, height: 12)
                                Text(L("Updating…"))
                            }
                        } else {
                            Text(L("Refresh rate"))
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(currency.isRefreshing)
                }
                if let error = currency.error {
                    SettingsBanner(text: error, tone: .warning)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
                }
            }

            SettingsSection(
                title: L("Subscription fees"),
                footer: L("Enter your actual monthly payment in USD (annual plans: monthly average). These defaults apply unless an account has its own fee set in its Usage value card."))
            {
                subscriptionField("Codex", providerID: "codex", value: $codexFee)
                SettingsRowDivider(inset: 50)
                subscriptionField("Claude", providerID: "claude", value: $claudeFee)
            }
        }
    }

    private var rateTitle: String {
        if let quote = currency.quote {
            return "1 USD = \(String(format: "%.4f", quote.rate)) CNY · \(quote.date)"
        }
        return L("No exchange rate yet")
    }

    private func subscriptionField(_ name: String, providerID: String, value: Binding<String>) -> some View {
        let invalid = !value.wrappedValue.isEmpty && SubscriptionComparison.monthlyUSD(value.wrappedValue) == nil
        return HStack(spacing: 12) {
            ProviderBadge(providerID: providerID, size: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("%@ subscription", name))
                    .font(.system(size: 13))
                if invalid {
                    Text(L("Enter a nonnegative USD amount with up to 2 decimal places."))
                        .font(.system(size: 11))
                        .foregroundColor(Color(nsColor: .systemOrange))
                        .fixedSize(horizontal: false, vertical: true)
                } else if let fee = SubscriptionComparison.monthlyUSD(value.wrappedValue) {
                    Text(L("%@ / mo", currency.display.format(fee)))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            TextField(L("Monthly USD"), text: value)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 110)
                .accessibilityLabel(Text(L("%@ monthly subscription in USD", name)))
            Text(L("USD / mo"))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(minHeight: 42)
    }
}
