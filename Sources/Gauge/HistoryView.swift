import SwiftUI
import Charts
import GaugeCore

struct HistoryView: View {
    @EnvironmentObject var store: AppStore
    @State private var accountID: UUID?
    @State private var days = 1
    @State private var windowID: String?
    private var account: Account? { store.accounts.first { $0.id == accountID } ?? store.accounts.first }
    private var samples: [HistorySample] {
        guard let account else { return [] }
        return store.history[account.id.uuidString, default: []].filter { $0.date >= store.now.addingTimeInterval(-Double(days) * 86400) }
    }
    private var windows: [UsageWindow] { account.flatMap { store.snapshots[$0.id.uuidString]?.windows } ?? [] }
    private var selectedWindow: UsageWindow? { windows.first { $0.id == windowID } ?? windows.first }
    private var points: [(date: Date, percent: Double)] {
        guard let selectedWindow else { return [] }
        return samples.compactMap { sample in
            sample.windows.first { $0.id == selectedWindow.id }.map { (sample.date, $0.usedPercent) }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 25) {
            PageHeading(eyebrow: "A LITTLE PERSPECTIVE", title: "나의 작업 리듬.", subtitle: "기록된 사용률로 계정의 여유를 살펴보세요.")
            if store.accounts.isEmpty { EmptyAccountsView() }
            else {
                Card {
                    VStack(alignment: .leading, spacing: 25) {
                        HStack {
                            if let account { ProviderMark(provider: account.provider, size: 30) }
                            Picker("계정", selection: Binding(get: { account?.id }, set: { accountID = $0; windowID = nil })) {
                                ForEach(store.accounts) { Text($0.name + " · " + $0.provider.title).tag(Optional($0.id)) }
                            }.labelsHidden().frame(maxWidth: 235)
                            Spacer()
                            Picker("기간", selection: $days) {
                                Text("24시간").tag(1); Text("7일").tag(7); Text("30일").tag(30)
                            }.pickerStyle(.segmented).frame(width: 180)
                        }
                        HStack {
                            VStack(alignment: .leading, spacing: 7) {
                                Text("한도 사용률").font(.system(size: 15, weight: .semibold))
                                Text("\(points.count)개 측정값 · 약 5분 간격으로 기록").font(.system(size: 12)).foregroundStyle(Palette.secondary)
                            }
                            Spacer()
                            Picker("사용 한도", selection: Binding(get: { selectedWindow?.id }, set: { windowID = $0 })) {
                                ForEach(windows) { Text($0.title).tag(Optional($0.id)) }
                            }.labelsHidden().frame(maxWidth: 210)
                        }
                        if points.count >= 2 {
                            Chart {
                                ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                                    AreaMark(x: .value("시간", point.date), yStart: .value("기준", 0), yEnd: .value("사용률", point.percent))
                                        .foregroundStyle(LinearGradient(colors: [Palette.provider(account!.provider).opacity(0.17), Palette.provider(account!.provider).opacity(0.01)], startPoint: .top, endPoint: .bottom))
                                    LineMark(x: .value("시간", point.date), y: .value("사용률", point.percent))
                                        .foregroundStyle(Palette.provider(account!.provider)).lineStyle(StrokeStyle(lineWidth: 2))
                                }
                                RuleMark(y: .value("주의", 80)).foregroundStyle(Palette.amber.opacity(0.55))
                                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                                    .annotation(position: .top, alignment: .trailing) { Text("주의 80%").font(.system(size: 12)).foregroundStyle(Palette.amber) }
                            }
                            .chartYScale(domain: 0...100)
                            .chartXScale(domain: store.now.addingTimeInterval(-Double(days) * 86400)...store.now)
                            .chartYAxis { AxisMarks(position: .leading, values: [0, 25, 50, 75, 100]) { value in
                                AxisGridLine().foregroundStyle(Palette.line)
                                AxisValueLabel { if let number = value.as(Int.self) { Text("\(number)%").font(.system(size: 12)).foregroundStyle(Palette.secondary) } }
                            } }
                            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                                AxisValueLabel(format: days == 1 ? .dateTime.hour().minute() : .dateTime.month().day()).font(.system(size: 12)).foregroundStyle(Palette.secondary)
                            } }
                            .frame(height: 270).padding(.top, 8)
                        } else {
                            VStack(spacing: 12) {
                                Image(systemName: "chart.xyaxis.line").font(.system(size: 29)).foregroundStyle(Palette.secondary.opacity(0.5))
                                Text("작업 리듬을 기록하고 있어요").font(.system(size: 14, weight: .medium))
                                Text("측정값이 두 개 이상 쌓이면 그래프가 표시됩니다.").font(.system(size: 13)).foregroundStyle(Palette.secondary)
                            }.frame(maxWidth: .infinity).frame(height: 270)
                        }
                        HStack(spacing: 30) {
                            historyStat("기간 내 최고", value: points.map(\.percent).max())
                            historyStat("최근 측정값", value: points.last?.percent)
                            Spacer()
                            Text("한도가 초기화되면 그래프가 내려갑니다.").font(.system(size: 12)).foregroundStyle(Palette.secondary)
                        }.padding(.top, 18).overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 1) }
                    }
                }
                Label("앱이 실행 중일 때 측정한 사용률만 최대 30일 보관합니다. 토큰 소비량이나 결제 금액을 의미하지 않습니다.", systemImage: "info.circle")
                    .font(.system(size: 12)).foregroundStyle(Palette.secondary)
            }
        }
    }
    private func historyStat(_ title: String, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12)).foregroundStyle(Palette.secondary)
            Text(value.map { "\(Int($0.rounded()))%" } ?? "—").font(.system(size: 22, weight: .semibold, design: .rounded))
        }
    }
}
