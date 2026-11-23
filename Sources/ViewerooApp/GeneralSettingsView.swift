import SwiftUI

struct GeneralSettingsView: View {
    private enum Editor: String, Identifiable {
        case pin, key
        var id: Self { self }
    }

    @Bindable var model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var editor: Editor?

    var body: some View {
        VStack(alignment: .leading, spacing: VSpace.group) {
            Text("Settings").font(.title2.bold())
            LabeledContent("PIN protection") {
                Text(model.pinEnabled ? "On" : "Off").foregroundStyle(.secondary)
                IconActionButton(.edit, model.pinEnabled ? "Manage PIN…" : "Set PIN…") { editor = .pin }
            }
            Divider()
            LabeledContent("PRDB API key") {
                IconActionButton(.edit, "Change API Key…") { editor = .key }
            }
            if let status = model.networkStatus {
                Text(status).font(.callout).foregroundStyle(.secondary)
                if model.subscriptionRequired { IconActionButton(.refresh, "Retry PRDB", action: model.retrySubscription) }
            }
            Divider()
            VStack(alignment: .leading, spacing: VSpace.tight) {
                LabeledContent("Cinema recommendations") {
                    Picker("Cinema recommendations", selection: $model.cinemaRecommendationCount) {
                        ForEach(CinemaRecommendationCount.allCases, id: \.self) { count in
                            Text(String(count.rawValue)).tag(count)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 120)
                }
                Text("Smaller player windows show up to 4 videos.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(VSpace.section).frame(width: 400)
        .sheet(item: $editor) { selected in
            switch selected {
            case .pin: PrivacyView(model: model)
            case .key: PRDBKeyForm(model: model)
            }
        }
    }
}

private struct PRDBKeyForm: View {
    @Environment(\.dismiss) private var dismiss
    let model: LibraryModel
    @State private var key = ""
    @State private var verifying = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: VSpace.group) {
            Text("Change PRDB API Key").font(.title2.bold())
            SecureField("New PRDB API key", text: $key).disabled(verifying)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                if verifying { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Verify and Save") { error = nil; verifying = true }
                    .keyboardShortcut(.defaultAction)
                    .disabled(verifying || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(VSpace.section).frame(width: 380)
        .task(id: verifying) {
            guard verifying else { return }
            defer { verifying = false }
            do { try await model.replacePRDBKey(key); dismiss() }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}

private struct PrivacyView: View {
    @Environment(\.dismiss) var dismiss
    @Bindable var model: LibraryModel
    @State private var current = ""
    @State private var next = ""
    @State private var removing = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: VSpace.group) {
            Text("PIN Protection").font(.title2.bold())
            Text("Require a PIN at launch and use Shift–Command–L to lock during playback.")
                .foregroundStyle(.secondary)
            if model.pinEnabled {
                SecureField("Current PIN", text: $current)
                Toggle("Turn off PIN protection", isOn: $removing)
            }
            if !removing { SecureField("New PIN (4–12 digits)", text: $next) }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    do {
                        try model.access.setPIN(current: model.pinEnabled ? current : nil, new: removing ? nil : next)
                        model.pinEnabled = try model.access.hasPIN
                        model.notify(removing ? "PIN protection turned off" : "PIN saved")
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(VSpace.section).frame(width: 380)
    }
}
