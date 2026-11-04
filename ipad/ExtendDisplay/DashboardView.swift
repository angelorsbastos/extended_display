import SwiftUI

/// The laptop's temperatures, fans, usage, memory and battery health, every 2 s
/// (pc/stats.py), with the last 3 minutes as small graphs.
struct DashboardView: View {
    @ObservedObject var model: AppModel

    private let columns = [GridItem(.adaptive(minimum: 340), spacing: 20, alignment: .top)]

    var body: some View {
        VStack(spacing: 24) {
            TopBar(title: "Dashboard", model: model)
            if let stats = model.stats {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 20) {
                        cpuCard(stats.cpu)
                        gpuCard(stats.gpu)
                        memoryCard(stats.memory, plan: stats.powerPlan)
                        batteryCard(stats.battery)
                    }
                }
            } else {
                Spacer()
                ProgressView(model.connected ? "Reading the laptop's sensors…" : "Laptop not connected")
                    .tint(.white)
                Spacer()
            }
        }
        .screenPadding()
        .foregroundStyle(.white)
    }

    // MARK: cards

    private func cpuCard(_ cpu: LaptopStats.CPU) -> some View {
        Card(title: "Processor", icon: "cpu", tint: temperatureColor(cpu.temp)) {
            BigNumbers(items: [("Temperature", degrees(cpu.temp), temperatureColor(cpu.temp)),
                               ("Usage", percent(cpu.usage), .white)])
            Graph(values: model.statsHistory.map(\.cpu.temp), range: 30...100,
                  color: temperatureColor(cpu.temp), label: "temperature, last 3 min")
            Graph(values: model.statsHistory.map(\.cpu.usage), range: 0...100, color: .blue,
                  label: "usage")
            Detail(icon: "fan", text: rpm(cpu.fan))
        }
    }

    private func gpuCard(_ gpu: LaptopStats.GPU) -> some View {
        Card(title: gpu.name.map(shortGPUName) ?? "Graphics", icon: "rectangle.3.group",
             tint: temperatureColor(gpu.temp)) {
            BigNumbers(items: [("Temperature", degrees(gpu.temp), temperatureColor(gpu.temp)),
                               ("Usage", percent(gpu.usage), .white)])
            Graph(values: model.statsHistory.map(\.gpu.temp), range: 30...100,
                  color: temperatureColor(gpu.temp), label: "temperature, last 3 min")
            Graph(values: model.statsHistory.map(\.gpu.usage), range: 0...100, color: .blue,
                  label: "usage")
            HStack(spacing: 18) {
                Detail(icon: "bolt.fill", text: gpu.power.map { String(format: "%.1f W", $0) } ?? "–")
                Detail(icon: "speedometer", text: gpu.clock.map { "\(Int($0)) MHz" } ?? "–")
                Detail(icon: "fan", text: rpm(gpu.fan))
            }
            if let used = gpu.memoryUsed, let total = gpu.memoryTotal, total > 0 {
                Meter(label: "Video memory", value: used / total,
                      text: String(format: "%.1f of %.0f GB", used / 1024, total / 1024))
            }
        }
    }

    private func memoryCard(_ memory: LaptopStats.Memory, plan: String?) -> some View {
        Card(title: "Memory", icon: "memorychip", tint: Theme.secondary) {
            if let used = memory.used, let total = memory.total, total > 0 {
                Meter(label: "In use", value: used / total, text: String(format: "%.1f of %.1f GB", used, total))
            }
            if let plan {
                Detail(icon: "gauge.with.dots.needle.67percent", text: "Power plan: \(plan)")
            }
        }
    }

    private func batteryCard(_ battery: LaptopStats.BatteryInfo?) -> some View {
        Card(title: "Battery", icon: batteryIcon(battery), tint: Theme.secondary) {
            BigNumbers(items: [("Charge", battery?.percent.map { "\($0)%" } ?? "–", .white),
                               ("Health", battery?.health.map { "\($0)%" } ?? "–", healthColor(battery?.health))])
            if let full = battery?.fullWh, let design = battery?.designWh {
                Text(String(format: "Holds %.1f Wh of the %.1f Wh it had when new.", full, design))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let plugged = battery?.pluggedIn {
                Detail(icon: plugged ? "powerplug.fill" : "minus.plus.batteryblock",
                       text: plugged ? "Plugged in" : "On battery")
            }
        }
    }

    // MARK: formatting

    private func degrees(_ value: Double?) -> String { value.map { "\(Int($0.rounded()))°" } ?? "–" }
    private func percent(_ value: Double?) -> String { value.map { "\(Int($0.rounded()))%" } ?? "–" }
    private func rpm(_ value: Int?) -> String { value.map { $0 == 0 ? "Fan off" : "\($0) RPM" } ?? "Fan: –" }

    private func shortGPUName(_ name: String) -> String {
        name.replacingOccurrences(of: "NVIDIA GeForce ", with: "").replacingOccurrences(of: " Laptop GPU", with: "")
    }

    private func temperatureColor(_ value: Double?) -> Color {
        guard let value else { return .gray }
        return value < 60 ? .green : value < 80 ? .yellow : .red
    }

    private func healthColor(_ value: Int?) -> Color {
        guard let value else { return .white }
        return value >= 80 ? .green : value >= 60 ? .yellow : .red
    }

    private func batteryIcon(_ battery: LaptopStats.BatteryInfo?) -> String {
        if battery?.pluggedIn == true { return "battery.100.bolt" }
        switch battery?.percent ?? 100 {
        case ..<15: return "battery.0"
        case ..<40: return "battery.25"
        case ..<65: return "battery.50"
        case ..<90: return "battery.75"
        default: return "battery.100"
        }
    }
}

/// Two big numbers side by side, with small labels.
private struct BigNumbers: View {
    let items: [(String, String, Color)]

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 30) {
            ForEach(items.indices, id: \.self) { i in
                VStack(alignment: .leading, spacing: 2) {
                    Text(items[i].1)
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .foregroundStyle(items[i].2)
                        .monospacedDigit()
                    Text(items[i].0)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }
}

/// A small line graph of recent values (missing ones leave a gap).
private struct Graph: View {
    let values: [Double?]
    let range: ClosedRange<Double>
    let color: Color
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geometry in
                let size = geometry.size
                let step = size.width / CGFloat(max(AppModel.statsHistoryLength - 1, 1))
                let start = CGFloat(AppModel.statsHistoryLength - values.count) * step
                Path { path in
                    var drawing = false
                    for (i, value) in values.enumerated() {
                        guard let value else { drawing = false; continue }
                        let clamped = min(max(value, range.lowerBound), range.upperBound)
                        let y = size.height * (1 - CGFloat((clamped - range.lowerBound) / (range.upperBound - range.lowerBound)))
                        let point = CGPoint(x: start + CGFloat(i) * step, y: y)
                        if drawing { path.addLine(to: point) } else { path.move(to: point) }
                        drawing = true
                    }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
            .frame(height: 44)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.tileRaised.opacity(0.5)))
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

/// A labelled bar for something that fills up (memory).
private struct Meter: View {
    let label: String
    let value: Double  // 0...1
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label).font(.callout)
                Spacer()
                Text(text).font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.tileRaised)
                    Capsule().fill(value > 0.85 ? Color.red : Color.purple)
                        .frame(width: geometry.size.width * CGFloat(min(max(value, 0), 1)))
                }
            }
            .frame(height: 10)
        }
    }
}

private struct Detail: View {
    let icon: String
    let text: String

    var body: some View {
        Label(text, systemImage: icon)
            .font(.callout)
            .foregroundStyle(.secondary)
    }
}
