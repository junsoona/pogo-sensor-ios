import SwiftUI

/// Home-style accessory tile used throughout the app.
struct SensorCard: View {
    let reading: SensorReading
    let contextLabel: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 8) {
                    sensorIcon
                    Spacer(minLength: 0)
                    StatusBadge(status: reading.status)
                }
                VStack(alignment: .leading, spacing: 8) {
                    sensorIcon
                    StatusBadge(status: reading.status)
                }
            }

            Spacer(minLength: 14)

            Text(reading.formattedValue)
                .font(.title2.weight(.bold))
                .foregroundStyle(.primary)
                .minimumScaleFactor(0.6)
                .lineLimit(1)

            Text(reading.kind.displayName)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)

            Text("\(contextLabel) · \(reading.timestamp.formatted(.relative(presentation: .numeric)))")
                .font(.caption2)
                .lineLimit(1)
                .foregroundStyle(.secondary)
        }
        .padding(PogoTheme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 154, alignment: .topLeading)
        .background(PogoTheme.tile, in: RoundedRectangle(cornerRadius: PogoTheme.cardCornerRadius, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(reading.kind.displayName)
        .accessibilityValue(
            "\(reading.formattedValue), \(reading.status.displayName), 마지막 갱신 \(reading.timestamp.formatted(.relative(presentation: .named))), \(contextLabel)"
        )
    }

    private var sensorIcon: some View {
        Image(systemName: reading.kind.symbolName)
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: 36, height: 36)
            .background(PogoTheme.color(for: reading.kind), in: Circle())
            .accessibilityHidden(true)
    }
}

#Preview {
    ScrollView {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
            ForEach(MockSensorFixtures.previewSnapshot.allReadings) { reading in
                SensorCard(reading: reading, contextLabel: "거실 환경 모듈")
            }
        }
        .padding()
    }
}
