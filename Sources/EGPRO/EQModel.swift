import AppKit
import EGAudio
import Foundation

struct EQPreset: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let gains: [Double]
}

/// Starea egalizatorului: benzile, setarile salvate, pornit/oprit.
final class EQModel: ObservableObject {
    static let bandLabels = ["32", "64", "125", "250", "500", "1K", "2K", "4K", "8K", "16K"]
    static let customName = "Personalizat"

    static let presets: [EQPreset] = [
        EQPreset(name: "Normal", gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        EQPreset(name: "Bas puternic", gains: [6, 5, 4, 2, 0, 0, 0, 0, 0, 0]),
        EQPreset(name: "Bas extrem", gains: [9, 8, 6, 3, 0, -1, 0, 0, 0, 0]),
        EQPreset(name: "Voce clară", gains: [-2, -2, -1, 0, 2, 4, 4, 3, 1, 0]),
        EQPreset(name: "Înalte", gains: [0, 0, 0, 0, 0, 1, 2, 4, 5, 6]),
        EQPreset(name: "Petrecere", gains: [6, 5, 2, 0, -1, 0, 1, 3, 4, 4]),
        EQPreset(name: "Rock", gains: [4, 3, 2, 0, -1, -1, 1, 3, 4, 4]),
        EQPreset(name: "Pop", gains: [-1, 0, 2, 3, 4, 3, 1, 0, -1, -1]),
        EQPreset(name: "Căști", gains: [3, 2, 1, 0, 0, 0, 1, 2, 3, 2]),
        EQPreset(name: "Noaptea", gains: [-4, -3, -2, -1, 0, 0, 0, 0, -1, -2]),
    ]

    @Published private(set) var gains: [Double]
    @Published private(set) var presetName: String
    @Published private(set) var enabled = false
    @Published private(set) var outputName = ""
    @Published private(set) var errorMessage = ""

    private var observer: NSObjectProtocol?
    private let defaults = UserDefaults.standard

    init() {
        if let saved = defaults.array(forKey: "gains") as? [Double], saved.count == 10 {
            gains = saved
        } else {
            gains = Array(repeating: 0, count: 10)
        }
        presetName = defaults.string(forKey: "preset") ?? "Normal"
        pushToEngine()

        observer = NotificationCenter.default.addObserver(
            forName: .EGEngineDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshStatus()
        }

        // Pornim automat, daca ultima data era pornit (sau la prima pornire).
        let shouldStart = defaults.object(forKey: "enabled") == nil || defaults.bool(forKey: "enabled")
        if shouldStart {
            DispatchQueue.main.async { [weak self] in self?.setEnabled(true) }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: - Actiuni

    func setEnabled(_ on: Bool) {
        if on {
            if !EGEngineIsSupported() {
                errorMessage = "EGPRO are nevoie de macOS 14.2 sau mai nou."
            } else if let err = EGEngineStart() {
                errorMessage = err
            } else {
                errorMessage = ""
            }
        } else {
            EGEngineStop()
            errorMessage = ""
        }
        refreshStatus()
        defaults.set(enabled, forKey: "enabled")
    }

    func setGain(_ index: Int, _ value: Double) {
        guard gains.indices.contains(index) else { return }
        let clamped = min(max(value, -12), 12)
        guard gains[index] != clamped else { return }
        gains[index] = clamped
        presetName = Self.customName
        pushToEngine()
        save()
    }

    func applyPreset(named name: String) {
        guard let preset = Self.presets.first(where: { $0.name == name }) else { return }
        gains = preset.gains
        presetName = preset.name
        pushToEngine()
        save()
    }

    func quit() {
        EGEngineStop()
        NSApp.terminate(nil)
    }

    // MARK: - Intern

    private func refreshStatus() {
        enabled = EGEngineIsRunning()
        outputName = EGEngineOutputDeviceName()
    }

    /// Trimite benzile la motor. Pre-amplificarea scade automat volumul cand ridici o banda,
    /// ca sunetul sa nu se "sparga" (distorsioneze).
    private func pushToEngine() {
        let floats = gains.map { Float($0) }
        let maxBoost = max(0, gains.max() ?? 0)
        let preamp = Float(-maxBoost)
        floats.withUnsafeBufferPointer { buf in
            EGEngineSetBands(buf.baseAddress!, Int32(buf.count), preamp)
        }
    }

    private func save() {
        defaults.set(gains, forKey: "gains")
        defaults.set(presetName, forKey: "preset")
    }
}
