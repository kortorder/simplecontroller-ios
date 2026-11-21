import SwiftUI
import ControllerCore

@MainActor
struct TouchAimInspectorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var inspector = TouchAimInspector()
    @State private var resetID = UUID()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Touch this pad normally, then change your finger's contact and move it around. These are measurements reported by your phone. Contact size is not pressure.")
                    Text("No game or mouse actions are sent.").font(.headline)
                    TouchMetricPad(enabled: scenePhase == .active, resetID: resetID,
                                   onSample: { try? inspector.observe($0.metrics) }, onEnd: { _, _ in })
                        .frame(height: 230)
                    metric("Contact radius", metric: .majorRadius, unit: "points")
                    metric("Force", metric: .normalizedForce, unit: "normalized")
                    if let tolerance = inspector.latest.radiusTolerance {
                        Text("Radius uncertainty: ±\(tolerance.formatted(.number.precision(.fractionLength(2)))) points")
                    }
                    Text("Unavailable means iOS did not provide a usable measurement. The app will not substitute a made-up pressure value. Compare repeated still and moving touches before using automatic thresholds.")
                        .foregroundStyle(.secondary)
                    Button("Clear measurements") { inspector.reset(); resetID = UUID() }
                }.padding()
            }
            .navigationTitle("Touch inspector").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { inspector.reset(); resetID = UUID() }
            }
        }
    }
    private func metric(_ title: String, metric: TouchAimMetric, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            if let value = inspector.latest.value(for: metric), let summary = inspector.summaries[metric] {
                Text("Now \(value.formatted(.number.precision(.fractionLength(3)))) \(unit)")
                Text("Range \(summary.minimum.formatted(.number.precision(.fractionLength(3))))–\(summary.maximum.formatted(.number.precision(.fractionLength(3)))) • \(summary.count) samples")
                    .font(.caption).foregroundStyle(.secondary)
            } else { Text("Unavailable").foregroundStyle(.secondary) }
        }
    }
}

/// Calibration records stay in this view's memory and are discarded on close.
/// Only the fitted summary is returned after fresh, separate validation passes.
@MainActor
struct TouchAimCalibrationView: View {
    private let existingCalibration: TouchAimCalibrationProfile?
    private let savedPresetName: String?
    private let onSaveValidatedPreset: ((TouchAimCalibrationProfile) -> Bool)?
    private let onApply: (TouchAimCalibrationProfile) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var training: [TouchAimCalibrationPass] = []
    @State private var validation: [TouchAimCalibrationPass] = []
    @State private var samples: [TouchAimCalibrationSample] = []
    @State private var candidate: TouchAimCalibrationProfile?
    @State private var explanation = ""
    @State private var error: String?
    @State private var busy = false
    @State private var resetID = UUID()
    @State private var analysisID = UUID()
    @State private var name = "iPhone touch calibration"
    @State private var presetUpdated = false

    init(existingCalibration: TouchAimCalibrationProfile? = nil,
         savedPresetName: String? = nil,
         onSaveValidatedPreset: ((TouchAimCalibrationProfile) -> Bool)? = nil,
         onApply: @escaping (TouchAimCalibrationProfile) -> Void) {
        self.existingCalibration = existingCalibration
        self.savedPresetName = savedPresetName
        self.onSaveValidatedPreset = onSaveValidatedPreset
        self.onApply = onApply
        var initial = existingCalibration
        initial?.validationCompleted = false
        _candidate = State(initialValue: initial)
        _name = State(initialValue: existingCalibration?.name ?? "iPhone touch calibration")
        _explanation = State(initialValue: existingCalibration == nil ? "" : "The saved fit stays unchanged. Record one fresh Aim touch and one fresh Aim + Shoot touch to check it on this phone.")
    }

    private var isValidating: Bool { candidate != nil && candidate?.isApplicable != true && (existingCalibration != nil || training.count == 4) }
    private var passIndex: Int { isValidating ? validation.count : training.count }
    private var label: TouchAimCalibrationLabel { passIndex % 2 == 0 ? .aim : .shoot }
    private var canRecord: Bool {
        !busy && scenePhase == .active && candidate?.isApplicable != true &&
        ((existingCalibration == nil && training.count < 4) || (isValidating && validation.count < 2 && (candidate?.quality == .good || candidate?.quality == .borderline)))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("No game or mouse actions are sent during calibration.").font(.headline)
                    if let existingCalibration {
                        Text("Validate saved calibration: \(savedPresetName ?? existingCalibration.name)").font(.headline)
                        Text("Use the same finger and phone position as when playing. This checks the saved fit without retraining it. Your saved profile and preset stay unchanged until you explicitly apply or update them.")
                    } else if training.isEmpty {
                        TextField("Calibration name", text: $name).textFieldStyle(.roundedBorder)
                        Text("Use the same finger and phone position as when playing. Record two normal Aim touches and two Aim + Shoot touches. Use a comfortable change in finger contact; pressing harder may not change the sensor reading.")
                    }
                    if canRecord {
                        Text(isValidating ? "Fresh validation \(passIndex + 1) of 2" : "Recording \(passIndex + 1) of 4").font(.headline)
                        Text(label == .aim ? "Use your normal Aim touch" : "Use your Aim + Shoot touch").font(.title3)
                        Text("Touch and hold still for about one second, then make small circles for about two seconds. Lift to finish this recording.")
                        // Reserve progress space before touching so the pad never jumps under the finger.
                        ZStack(alignment: .leading) {
                            Text("Move gently in small circles, then lift.").hidden()
                            Text(samples.isEmpty ? "Touch the pad when ready." : (samples.last!.elapsed < 1 ? "Hold still…" : "Move gently in small circles, then lift."))
                        }.foregroundStyle(.teal).font(.headline)
                        Text("\(samples.filter { !$0.moving }.count) still • \(samples.filter(\.moving).count) moving samples")
                            .font(.caption).monospacedDigit()
                        TouchMetricPad(enabled: canRecord, resetID: resetID,
                                       onSample: record, onEnd: finish)
                            .frame(height: 230)
                    }
                    if busy { ProgressView("Checking repeatability…") }
                    if let error { Text(error).foregroundStyle(.orange) }
                    if let candidate {
                        Text("Result: \(candidate.quality.rawValue.capitalized)").font(.headline)
                        Text(explanation)
                        // No-fit results have conservative placeholder rates and
                        // no measured movement comparison. Show their specific
                        // explanation without presenting placeholders as findings.
                        if !candidate.transforms.isEmpty {
                            Text("Unexpected activation rate: \(candidate.falseActivationRate.formatted(.percent.precision(.fractionLength(1))))")
                            Text("Missed activation rate: \(candidate.missedActivationRate.formatted(.percent.precision(.fractionLength(1))))")
                            if candidate.movementReducedReliability {
                                Text(movementExplanation(for: candidate)).foregroundStyle(.orange)
                            }
                        }
                        if candidate.isApplicable {
                            Button("Use this calibration") { onApply(candidate); dismiss() }
                                .buttonStyle(.borderedProminent)
                            Text("This saves the calibration summary in this control's draft. Save layout afterward to keep it.")
                            if let onSaveValidatedPreset {
                                Button(presetUpdated ? "Saved preset updated" : "Update saved preset\(savedPresetName.map { ": \($0)" } ?? "")") {
                                    if onSaveValidatedPreset(candidate) { presetUpdated = true; error = nil }
                                    else { error = "The saved preset could not be updated. You can retry, or use this calibration in the control draft without updating the preset." }
                                }.disabled(presetUpdated)
                                Text("Updating the preset is a separate save. It keeps this validated result in your reusable library, even if you later cancel the controller draft.")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        } else if candidate.quality == .good || candidate.quality == .borderline {
                            if !busy && validation.count >= 2 {
                                Text("Fresh validation did not pass. Start over or leave sensor actions off.")
                            } else {
                                Text("Complete one fresh Aim and one fresh Aim + Shoot recording above before using this result.")
                            }
                        } else {
                            Text("This result cannot be applied. Repeat with more distinct, comfortable touches or use manual thresholds.")
                        }
                    }
                    if !training.isEmpty || !samples.isEmpty || candidate != nil {
                        Button(existingCalibration == nil ? "Start over" : "Restart validation") { reset() }.disabled(busy)
                    }
                    Text("Raw touch samples are kept only while this screen is open. The saved calibration contains fitted settings and a quality summary. It does not turn contact size into measured pressure, and Android calibrations are not applied to iPhone sensors.")
                        .font(.footnote).foregroundStyle(.secondary)
                }.padding()
            }
            .navigationTitle(existingCalibration == nil ? "Calibrate TouchAim" : "Validate TouchAim").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { reset(); dismiss() } } }
            .onDisappear { reset() }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { reset(); error = "The recording was interrupted. Begin again when ready." }
            }
        }
    }

    private func movementExplanation(for profile: TouchAimCalibrationProfile) -> String {
        if profile.isApplicable {
            return "Movement affected the training measurements. Fresh validation passed for these recordings. Check the response in Practice; a different grip or movement may behave differently."
        }
        if profile.quality == .good || profile.quality == .borderline {
            if !busy && validation.count >= 2 {
                return "Movement affected the training measurements, and fresh validation did not pass. This result cannot activate sensor actions."
            }
            return "Movement made the training measurements less reliable. Separate fresh validation must pass before this result can be used."
        }
        return "Movement affected the measurements, and the recordings did not establish a reliable boundary. This result cannot activate sensor actions."
    }

    private func record(_ sample: TouchAimCalibrationSample) {
        guard canRecord, samples.count < 256 else { return }
        if samples.isEmpty { error = nil }
        samples.append(sample)
    }
    private func finish(_ completed: Bool, _ duration: Double) {
        defer { samples.removeAll(); resetID = UUID() }
        guard canRecord else { return }
        guard completed, duration >= 0.3, duration <= 30, samples.count >= 12,
              samples.filter({ !$0.moving }).count >= 6, samples.filter(\.moving).count >= 6,
              samples.allSatisfy({ !$0.metrics.availableMetrics.isEmpty }) else {
            error = "Recording incomplete. Keep one finger down: first hold still, then move in small circles and lift after about three seconds. If both sensors remain unavailable in Touch inspector, this phone cannot calibrate this gesture."
            return
        }
        let pass = TouchAimCalibrationPass(label: label, repetition: isValidating ? 2 : passIndex / 2,
                                           samples: samples, duration: duration)
        if isValidating {
            validation.append(pass)
            if validation.count == 2 { analyzeValidation() }
        } else {
            training.append(pass)
            if training.count == 4 { analyzeTraining() }
        }
    }
    private func analyzeTraining() {
        busy = true
        let passes = training, token = UUID(), proposedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        analysisID = token
        Task { @MainActor in
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try TouchAimCalibrationAnalyzer.analyze(passes, name: proposedName.isEmpty ? "iPhone touch calibration" : String(proposedName.prefix(64)))
                }.value
                guard analysisID == token else { return }
                candidate = result.profile; explanation = result.explanation; busy = false
            } catch {
                guard analysisID == token else { return }
                self.error = error.localizedDescription; busy = false
            }
        }
    }
    private func analyzeValidation() {
        guard let profile = candidate else { return }
        busy = true
        let passes = validation, token = UUID(); analysisID = token
        Task { @MainActor in
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try TouchAimCalibrationAnalyzer.validate(profile, passes: passes)
                }.value
                guard analysisID == token else { return }
                candidate = result.profile; explanation = result.report.explanation; busy = false
                if !result.report.passed { error = "Fresh validation did not pass. Start over or use manual controls." }
            } catch {
                guard analysisID == token else { return }
                self.error = error.localizedDescription; busy = false
            }
        }
    }
    private func reset() {
        analysisID = UUID(); resetID = UUID(); busy = false
        samples.removeAll(); training.removeAll(); validation.removeAll(); error = nil; presetUpdated = false
        candidate = existingCalibration; candidate?.validationCompleted = false
        explanation = existingCalibration == nil ? "" : "The saved fit stays unchanged. Record two fresh validation touches before applying it."
    }
}
