import SwiftUI

struct DashboardBatteryPage: View {
    let snapshot: TelemetrySnapshot

    var body: some View {
        let health = snapshot.chargeHealthPercent
        let assessment = BatteryHealthPresentation(snapshot.batteryHealthAssessment)
        let temperature = snapshot.batteryTemperatureC.flatMap { $0.isFinite ? $0 : nil }

        return VStack(alignment: .leading, spacing: 20) {
            DashboardPageHeader(
                capsule: StatusCapsule(title: assessment.capsuleTitle, systemImage: "heart.fill", tone: assessment.tone),
                meta: { _ in snapshot.cycleCount.map { L10n.tr("battery.meta.cycles", $0) } },
                title: assessment.title,
                subtitle: health.map { L10n.tr("battery.subtitle.capacity", Formatters.percent($0)) },
                showsRefresh: false
            )

            capacityCard(snapshot)

            HStack(alignment: .top, spacing: 16) {
                DashboardMetricCard(
                    title: L10n.text("ui.metric.cycles"),
                    systemImage: "arrow.triangle.2.circlepath",
                    iconTint: .secondary,
                    value: snapshot.cycleCount.map(String.init) ?? L10n.text("common.none"),
                    unit: snapshot.cycleCount != nil ? L10n.text("format.cycleUnit") : nil,
                    caption: snapshot.designCycleCount.map { L10n.tr("ui.metric.designTarget", $0) }
                        ?? L10n.text("ui.metric.cycleTargetUnknown")
                ) {
                    BarGauge(fraction: DashboardGauge.cycles(snapshot), tint: .secondary)
                }

                DashboardMetricCard(
                    title: L10n.text("ui.metric.batteryTemp"),
                    systemImage: "thermometer.medium",
                    iconTint: .secondary,
                    value: temperature.map(Formatters.temperature) ?? L10n.text("common.none"),
                    caption: L10n.tr(
                        "battery.temperature.caption",
                        BatteryTemperatureAssessment(temperature).caption,
                        Formatters.wholeTemperature(BatteryTemperatureAssessment.elevatedThreshold)
                    )
                ) {
                    TemperatureZones(temperature: temperature)
                }

                chargingMethodCard(snapshot)
            }
            .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 16) {
                detailCard(title: L10n.text("ui.detail.batteryPack"), rows: TelemetryDetailRows.batteryPack(snapshot))
                detailCard(title: L10n.text("ui.detail.batteryFlow"), rows: TelemetryDetailRows.batteryFlow(snapshot))
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func capacityCard(_ snapshot: TelemetrySnapshot) -> some View {
        let health = snapshot.chargeHealthPercent
        let tint = (health ?? 100) < 80 ? LensPalette.caution : LensPalette.battery

        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Label(L10n.text("ui.metric.health"), systemImage: "heart.fill")
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                        .labelStyle(TintedIconLabelStyle(tint: tint))
                    Text(health.map(Formatters.percent) ?? L10n.text("common.none"))
                        .font(.system(size: 32, weight: .semibold))
                        .monospacedDigit()
                }
                Spacer()
                capacityFact(L10n.text("ui.detail.designCapacity"), snapshot.designCapacityMah)
                capacityFact(L10n.text("ui.detail.fullChargeCapacity"), snapshot.fullChargeCapacityMah)
            }

            VStack(spacing: 8) {
                BarGauge(fraction: DashboardGauge.capacity(snapshot), tint: tint, marker: 0.8)
                HStack {
                    Text("0%")
                    Spacer()
                    Text(L10n.text("battery.capacity.serviceMark"))
                    Spacer()
                    Text("100%")
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(24)
        .cardSurface()
    }

    private func capacityFact(_ title: String, _ mah: Int?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text(mah.map(Formatters.capacity) ?? L10n.text("common.none"))
                .font(.headline)
                .monospacedDigit()
        }
        .padding(.top, 6)
    }

    private func chargingMethodCard(_ snapshot: TelemetrySnapshot) -> some View {
        let method = ChargingMethodPresentation(policy: snapshot.chargingPolicyStatus)

        return DashboardMetricCard(
            title: L10n.text("battery.charging.title"),
            systemImage: "bolt.batteryblock",
            iconTint: LensPalette.charger,
            value: method.value,
            caption: method.caption
        ) {
            BarGauge(fraction: method.fraction, tint: LensPalette.charger)
        }
    }

    private func detailCard(title: String, rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)

            DetailRows(rows: rows, style: .window)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cardSurface()
    }

}

/// Cool / warm / hot bands with the current temperature marked.
private struct TemperatureZones: View {
    let temperature: Double?
    private let scale = BatteryTemperatureAssessment.chartMaximum

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                HStack(spacing: 3) {
                    Capsule().fill(LensPalette.battery.opacity(0.35)).frame(width: width * BatteryTemperatureAssessment.elevatedThreshold / scale - 3)
                    Capsule().fill(LensPalette.caution.opacity(0.35)).frame(width: width * (BatteryTemperatureAssessment.hotThreshold - BatteryTemperatureAssessment.elevatedThreshold) / scale - 3)
                    Capsule().fill(LensPalette.warning.opacity(0.35))
                }
                if let temperature {
                    Circle()
                        .strokeBorder(.primary, lineWidth: 3)
                        .background(Circle().fill(Color.lensWindowCard))
                        .frame(width: 14, height: 14)
                        .offset(x: width * min(max(temperature, 0), scale) / scale - 7)
                }
            }
        }
        .frame(height: 8)
    }
}

private struct TintedIconLabelStyle: LabelStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.foregroundStyle(tint)
            configuration.title
        }
    }
}
