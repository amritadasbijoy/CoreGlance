import SwiftUI

/// The page behind the Network card: how much internet data this Mac has used.
struct UsageView: View {
    @ObservedObject var monitor: Monitor

    var body: some View {
        let log = monitor.usage
        let hours = log.lastHours()
        let days = log.lastDays()
        let months = log.months()

        Card {
            Text("Data used").font(Theme.title)
            UsageRow(label: "Today", amount: log.today())
            UsageRow(label: "This week", amount: log.thisWeek())
            UsageRow(label: "This month", amount: log.thisMonth())
            UsageRow(label: "This year", amount: log.thisYear())
        }

        Card {
            chartHeader("Last 24 hours", total: hours.reduce(UsageLog.Amount(), +))
            UsageBars(values: hours.map { Double($0.total) }, color: Theme.accent).frame(height: 44)
            axis("24 hours ago", "Now")
        }

        Card {
            chartHeader("Last 30 days", total: days.reduce(UsageLog.Amount(), +))
            UsageBars(values: days.map { Double($0.total) }, color: Theme.fill).frame(height: 44)
            axis("30 days ago", "Today")
        }

        if !months.isEmpty {
            Card {
                Text("By month").font(Theme.title)
                ForEach(months, id: \.yearMonth) { month in
                    UsageRow(label: Fmt.month(month.yearMonth), amount: month.amount)
                }
            }
        }

        VStack(alignment: .leading, spacing: 8) {
            Text("Counted on this Mac since \(log.since.formatted(date: .abbreviated, time: .omitted)), while CoreGlance is running. Your provider's own count will differ.")
                .font(Theme.label).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                if monitor.confirmingUsageReset {
                    Text("Delete all usage history?").font(Theme.label)
                    Spacer()
                    Button("Cancel") { monitor.confirmingUsageReset = false }.buttonStyle(.borderless)
                    Button("Delete") { monitor.resetUsage() }.buttonStyle(.borderless).foregroundStyle(Theme.critical)
                } else {
                    Spacer()
                    Button("Reset…") { monitor.confirmingUsageReset = true }.buttonStyle(.borderless)
                }
            }
            .font(Theme.label)
        }
        .padding(.horizontal, 4)
    }

    private func chartHeader(_ title: String, total: UsageLog.Amount) -> some View {
        HStack {
            Text(title).font(Theme.title)
            Spacer()
            Text(Fmt.data(total.total)).font(Theme.value)
        }
    }

    private func axis(_ left: String, _ right: String) -> some View {
        HStack {
            Text(left)
            Spacer()
            Text(right)
        }
        .font(Theme.label).foregroundStyle(.secondary)
    }
}

/// One line of the totals: a label, then download and upload.
struct UsageRow: View {
    let label: String
    let amount: UsageLog.Amount

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(Theme.label).foregroundStyle(.secondary)
            Spacer()
            figure("arrow.down", amount.down)
            figure("arrow.up", amount.up)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(Fmt.data(amount.down)) down, \(Fmt.data(amount.up)) up")
    }

    private func figure(_ icon: String, _ bytes: UInt64) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
            Text(Fmt.data(bytes)).font(Theme.value)
        }
        .frame(width: 88, alignment: .trailing)
    }
}

/// Plain bar chart, scaled to its largest value. Empty slots keep a faint stub so the time axis reads.
struct UsageBars: View {
    let values: [Double]
    let color: Color

    var body: some View {
        let peak = max(values.max() ?? 0, 1)
        GeometryReader { geo in
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(values.indices, id: \.self) { index in
                    let value = values[index]
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(value > 0 ? color : Theme.track)
                        .frame(height: value > 0 ? max(2, geo.size.height * value / peak) : 2)
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }
}
