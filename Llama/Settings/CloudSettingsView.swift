import LocalchatGateway
import SwiftUI

// FORK: localchat. Settings › Cloud: providers, their keys and which models to show.
struct CloudSettingsView: View {
  @ObservedObject private var settings = CloudSettings.shared

  var body: some View {
    Form {
      Section {
        Text(
          "Use cloud models next to your local ones. Messages to a cloud model are sent to that provider over the internet. Keys are kept in your Keychain, and the chat page never sees them."
        )
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }

      ForEach(CloudProviderPreset.all) { preset in
        CloudProviderSection(preset: preset, settings: settings)
      }
    }
    .formStyle(.grouped)
  }
}

private struct CloudProviderSection: View {
  let preset: CloudProviderPreset
  @ObservedObject var settings: CloudSettings

  @State private var showingKeySheet = false
  @State private var showingModels = false
  @State private var testResult: String?
  @State private var testFailed = false
  @State private var testing = false

  private var entry: CloudSettings.Stored { settings.settings(for: preset) }
  private var hasKey: Bool { !(settings.key(for: preset)?.isEmpty ?? true) }

  var body: some View {
    Section {
      Toggle(
        isOn: Binding(
          get: { entry.enabled },
          set: { value in settings.update(preset) { $0.enabled = value } })
      ) {
        VStack(alignment: .leading, spacing: 2) {
          Text(preset.displayName)
          Text(preset.needsKey ? preset.baseURL.host() ?? "" : "Runs on this Mac: \(preset.baseURL.absoluteString)")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
      }

      if entry.enabled {
        if preset.needsKey {
          SettingRow(title: "API key", description: hasKey ? "Saved in your Keychain." : "Not set.") {
            HStack(spacing: 6) {
              if hasKey {
                Button("Remove") { settings.setKey(nil, for: preset) }
              }
              Button(hasKey ? "Replace…" : "Add…") { showingKeySheet = true }
            }
          }
        }

        SettingRow(
          title: "Models",
          description: entry.models.isEmpty
            ? "None chosen yet. Chosen models appear in the chat's model picker."
            : entry.models.count == 1 ? "1 model chosen." : "\(entry.models.count) models chosen."
        ) {
          Button("Choose…") { showingModels = true }
            .disabled(preset.needsKey && !hasKey)
        }

        HStack {
          if let testResult {
            Image(systemName: testFailed ? "xmark.circle.fill" : "checkmark.circle.fill")
              .foregroundStyle(testFailed ? .red : .green)
            Text(testResult)
              .font(.system(size: 11))
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          Spacer()
          if testing { ProgressView().controlSize(.small) }
          Button("Test Connection") { test() }
            .disabled(testing || (preset.needsKey && !hasKey))
        }
      }
    }
    .sheet(isPresented: $showingKeySheet) {
      CloudKeySheet(preset: preset) { key in
        settings.setKey(key, for: preset)
        testResult = nil
      }
    }
    .sheet(isPresented: $showingModels) {
      CloudModelPicker(provider: settings.provider(for: preset), chosen: Set(entry.models)) { chosen in
        settings.update(preset) { $0.models = chosen.sorted() }
      }
    }
  }

  private func test() {
    testing = true
    testResult = nil
    let provider = settings.provider(for: preset)
    Task {
      do {
        let count = try await CloudCatalog.test(provider)
        testResult = "Connected. \(count) models available."
        testFailed = false
      } catch {
        testResult = error.localizedDescription
        testFailed = true
      }
      testing = false
    }
  }
}

private struct CloudKeySheet: View {
  let preset: CloudProviderPreset
  let onSave: (String) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var key = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("\(preset.displayName) API key").font(.headline)
      SecureField("Paste your key", text: $key)
        .textFieldStyle(.roundedBorder)
        .frame(width: 360)
      if let url = preset.keyURL {
        Link("Get a key from \(preset.displayName)", destination: url)
          .font(.system(size: 11))
      }
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Save") {
          onSave(key)
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    }
    .padding(20)
  }
}

private struct CloudModelPicker: View {
  let provider: CloudProvider
  @State var chosen: Set<String>
  let onDone: (Set<String>) -> Void
  @Environment(\.dismiss) private var dismiss

  @State private var models: [CloudModelInfo] = []
  @State private var error: String?
  @State private var loading = true
  @State private var search = ""

  init(provider: CloudProvider, chosen: Set<String>, onDone: @escaping (Set<String>) -> Void) {
    self.provider = provider
    self._chosen = State(initialValue: chosen)
    self.onDone = onDone
  }

  private var filtered: [CloudModelInfo] {
    let query = search.trimmingCharacters(in: .whitespaces).lowercased()
    let list = query.isEmpty
      ? models
      : models.filter { $0.id.lowercased().contains(query) || ($0.name?.lowercased().contains(query) ?? false) }
    // Chosen ones first, so they're easy to review and remove.
    return list.sorted { chosen.contains($0.id) && !chosen.contains($1.id) }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("\(provider.displayName) models").font(.headline)
      TextField("Search", text: $search)
        .textFieldStyle(.roundedBorder)

      Group {
        if loading {
          ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error {
          Text(error).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          List(filtered) { model in
            Toggle(
              isOn: Binding(
                get: { chosen.contains(model.id) },
                set: { on in if on { chosen.insert(model.id) } else { chosen.remove(model.id) } })
            ) {
              VStack(alignment: .leading, spacing: 1) {
                Text(model.name ?? model.id)
                Text(details(model))
                  .font(.system(size: 10))
                  .foregroundStyle(.secondary)
              }
            }
            .toggleStyle(.checkbox)
          }
        }
      }
      .frame(width: 460, height: 380)

      HStack {
        Text(chosen.count == 1 ? "1 chosen" : "\(chosen.count) chosen")
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
        Spacer()
        Button("Cancel") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Done") {
          onDone(chosen)
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .task {
      do {
        models = try await CloudCatalog.fetch(provider)
      } catch {
        self.error = error.localizedDescription
      }
      loading = false
    }
  }

  private func details(_ model: CloudModelInfo) -> String {
    var parts = [model.id]
    if let context = model.contextLength, context > 0 { parts.append("\(context / 1000)K context") }
    if model.vision { parts.append("images") }
    if model.reasoning { parts.append("reasoning") }
    return parts.joined(separator: " · ")
  }
}
