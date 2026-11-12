import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: EQModel
    @AppStorage("transparency") private var transparency: Double = 0.45

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            presetPicker
            bands
            transparencyRow
            footer
        }
        .padding(16)
        .frame(width: 380)
        .background(GlassBackground(transparency: transparency))
    }

    // MARK: - Cat de transparent e fundalul

    private var transparencyRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "circle.lefthalf.filled")
                .foregroundStyle(.secondary)
            Text("Transparență")
                .font(.caption)
                .foregroundStyle(.secondary)
            Slider(value: $transparency, in: 0...1)
                .controlSize(.small)
            Text("\(Int((transparency * 100).rounded()))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
        }
    }

    // MARK: - Sus: nume, pornit/oprit, unde se aude

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("EGPRO")
                    .font(.title2.weight(.bold))
                Spacer()
                Toggle("", isOn: Binding(
                    get: { model.enabled },
                    set: { model.setEnabled($0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
            if !model.errorMessage.isEmpty {
                Text(model.errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var statusText: String {
        if model.enabled {
            return model.outputName.isEmpty ? "Pornit" : "Pornit · se aude pe \(model.outputName)"
        }
        return "Oprit · sunetul e normal"
    }

    // MARK: - Setari gata facute

    private var presetPicker: some View {
        Picker("Setare", selection: Binding(
            get: { model.presetName },
            set: { model.applyPreset(named: $0) }
        )) {
            ForEach(EQModel.presets) { preset in
                Text(preset.name).tag(preset.name)
            }
            if model.presetName == EQModel.customName {
                Text(EQModel.customName).tag(EQModel.customName)
            }
        }
    }

    // MARK: - Cele 10 benzi

    private var bands: some View {
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(0..<EQModel.bandLabels.count, id: \.self) { i in
                VStack(spacing: 6) {
                    Text(gainLabel(model.gains[i]))
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(model.gains[i] == 0 ? .secondary : .primary)
                    VerticalSlider(value: Binding(
                        get: { model.gains[i] },
                        set: { model.setGain(i, $0) }
                    ))
                    .frame(width: 30, height: 160)
                    Text(EQModel.bandLabels[i])
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 4)
    }

    private func gainLabel(_ value: Double) -> String {
        if value == 0 { return "0" }
        return value == value.rounded()
            ? String(format: "%+.0f", value)
            : String(format: "%+.1f", value)
    }

    // MARK: - Jos

    private var footer: some View {
        HStack {
            Button("Resetează") { model.applyPreset(named: "Normal") }
            Spacer()
            Text("Bas ← → Înalte")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Ieșire") { model.quit() }
        }
    }
}

/// Glisor vertical: tragi in sus pentru mai mult, in jos pentru mai putin (-12 ... +12 dB).
struct VerticalSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = -12...12

    var body: some View {
        GeometryReader { geo in
            let height = geo.size.height
            let span = range.upperBound - range.lowerBound
            let fraction = (value - range.lowerBound) / span
            let knobY = height * (1 - fraction)
            let zeroY = height * (1 - (0 - range.lowerBound) / span)

            ZStack(alignment: .top) {
                // sina
                Capsule()
                    .fill(Color.secondary.opacity(0.25))
                    .frame(width: 4, height: height)
                // portiunea colorata intre 0 si valoare
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 4, height: abs(knobY - zeroY))
                    .offset(y: min(knobY, zeroY))
                // linia de 0
                Rectangle()
                    .fill(Color.secondary.opacity(0.6))
                    .frame(width: 14, height: 1)
                    .offset(y: zeroY)
                // butonul
                Circle()
                    .fill(Color.white)
                    .overlay(Circle().stroke(Color.accentColor, lineWidth: 2))
                    .shadow(radius: 1)
                    .frame(width: 16, height: 16)
                    .offset(y: knobY - 8)
            }
            .frame(width: geo.size.width, height: height, alignment: .top)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let f = 1 - min(max(drag.location.y / height, 0), 1)
                        let raw = range.lowerBound + f * span
                        value = (raw * 2).rounded() / 2 // pasi de 0.5 dB
                    }
            )
        }
    }
}
