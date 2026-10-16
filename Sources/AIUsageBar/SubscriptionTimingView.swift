import SwiftUI

struct SubscriptionTimingView: View {
    let dashboard: ProviderDashboard
    var compact = false

    var body: some View {
        if let key = dashboard.subscriptionDatePreferenceKey {
            SubscriptionTimingCard(dashboard: dashboard, preferenceKey: key, compact: compact)
                .id(key)
        }
    }
}

struct SubscriptionTimingCard: View {
    let dashboard: ProviderDashboard
    let compact: Bool
    @AppStorage private var manual: String
    @State private var editing: Bool
    @State private var draftDate = Date()
    @State private var draftKind = SubscriptionTiming.Kind.expires

    init(dashboard: ProviderDashboard, preferenceKey: String, compact: Bool = false,
         defaults: UserDefaults = .standard, editing: Bool = false) {
        self.dashboard = dashboard
        self.compact = compact
        _manual = AppStorage(wrappedValue: "", preferenceKey, store: defaults)
        _editing = State(initialValue: editing)
    }

    private var timing: SubscriptionTiming? { timing(now: Date()) }

    private func timing(now: Date) -> SubscriptionTiming? {
        dashboard.subscriptionTiming(manual: manual, now: now)
    }

    private func origin(of timing: SubscriptionTiming) -> String {
        if timing.isEstimated { return L("Estimated from subscription start") }
        if timing.rolledForward { return L("Manual · moved to next month") }
        return timing.isManual ? L("Manual") : L("Provider")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 3 : 8) {
            HStack(alignment: .firstTextBaseline) {
                Label(L(timing?.kind.title ?? "Subscription date"), systemImage: "calendar")
                    .font(.system(size: compact ? 10 : 11, weight: .medium))
                Spacer(minLength: 4)
                if !compact && (timing.map { $0.isManual || $0.isEstimated } ?? true) {
                    Button(timing == nil ? L("Set date") : L("Edit")) {
                        draftDate = timing?.date ?? Date()
                        draftKind = timing?.kind ?? .expires
                        editing = true
                    }.buttonStyle(BorderlessButtonStyle()).font(.system(size: 10))
                }
            }
            if timing != nil {
                TimelineView(.periodic(from: Date(), by: 60)) { context in
                    if let current = timing(now: context.date) {
                        VStack(alignment: .leading, spacing: compact ? 3 : 8) {
                            Text(current.dateText).font(.system(size: compact ? 10 : 12, weight: .medium))
                            Text(L(current.status(now: context.date)) + " · " + origin(of: current))
                                .font(.system(size: 10)).foregroundColor(.secondary)
                        }
                    }
                }
            } else {
                Text(compact ? L("Not provided · set in details") : L("Not provided by this source. You can set a date for this account."))
                    .font(.system(size: 10)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if editing && !compact {
                editor
            }
        }
        .padding(compact ? 0 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous)
            .fill(Color.primary.opacity(compact ? 0 : 0.045)))
        .overlay(RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous)
            .strokeBorder(Color.primary.opacity(compact ? 0 : 0.08), lineWidth: 0.5))
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(L("Date type"), selection: $draftKind) {
                Text(L("Expires")).tag(SubscriptionTiming.Kind.expires)
                Text(L("Renews")).tag(SubscriptionTiming.Kind.renews)
            }.pickerStyle(SegmentedPickerStyle())
            DatePicker(L("Date"), selection: $draftDate, displayedComponents: .date)
                .datePickerStyle(FieldDatePickerStyle())
            Text(L("Saved for this account. Moves to the same day next month while the plan still has quota."))
                .font(.system(size: 10)).foregroundColor(.secondary)
            HStack {
                if !manual.isEmpty {
                    Button(L("Clear")) { manual = ""; editing = false }
                }
                Spacer()
                Button(L("Cancel")) { editing = false }
                Button(L("Save")) {
                    manual = SubscriptionTiming.encode(date: draftDate, kind: draftKind)
                    editing = false
                }
            }.font(.system(size: 11))
        }
    }
}
