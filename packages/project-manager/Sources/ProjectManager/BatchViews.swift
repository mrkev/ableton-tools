import AppKit
import SwiftUI

/// Chooses what a batch converts and where it writes.
struct BatchSheet: View {
  let title: String
  let candidates: BatchCandidates
  /// Opted-in substitutions the batch will make.
  let replacing: [Substitution]
  let onStart: ([LiveSetEntry], BatchDestination) -> Void
  let onCancel: () -> Void

  @AppStorage("batchDestination") private var folderPath = ""
  @State private var includePartial = false
  @State private var includeOptional = false
  @State private var besideOriginals = false

  private var chosen: [LiveSetEntry] {
    candidates.required + (includePartial ? candidates.partial : [])
      + (includeOptional ? candidates.optional : [])
  }

  private var destination: BatchDestination? {
    if besideOriginals { return .besideOriginals }
    return folderPath.isEmpty ? nil : .folder(URL(fileURLWithPath: folderPath))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Fix \(plural(chosen.count, "set"))").font(.headline)
        Text(title).font(.caption).foregroundStyle(.secondary)
      }

      VStack(alignment: .leading, spacing: 4) {
        Text(candidates.required.isEmpty
          ? "No sets here need fixing to open."
          : "\(candidates.required.count) need fixing to open")
        if !candidates.partial.isEmpty {
          Toggle("Also \(candidates.partial.count) held back by other plugins", isOn: $includePartial)
            .toggleStyle(.checkbox)
          Text("Converts what it can, but they still won't open fully.")
            .font(.caption).foregroundStyle(.secondary)
        }
        if !candidates.optional.isEmpty {
          Toggle("Also \(candidates.optional.count) that already open", isOn: $includeOptional)
            .toggleStyle(.checkbox)
          Text("Their VST2 plugins are native, so this only moves them to VST3 for the future.")
            .font(.caption).foregroundStyle(.secondary)
        }
      }

      VStack(alignment: .leading, spacing: 6) {
        Text("Save new files to").font(.subheadline.weight(.medium))
        Picker("Save new files to", selection: $besideOriginals) {
          Text("Another folder").tag(false)
          Text("Next to each original").tag(true)
        }
        .pickerStyle(.radioGroup)
        .labelsHidden()

        if besideOriginals {
          Text("Adds a -vst3.als file to each project folder, and the library marks those sets converted.")
            .font(.caption).foregroundStyle(.secondary)
        } else {
          HStack {
            Text(folderPath.isEmpty ? "No folder chosen" : folderPath)
              .font(.caption).foregroundStyle(.secondary)
              .lineLimit(1).truncationMode(.middle)
            Spacer()
            Button("Choose…") { chooseFolder() }
          }
          Text("Project folders stay untouched, and the library won't mark these sets converted.")
            .font(.caption).foregroundStyle(.secondary)
        }
      }

      ForEach(replacing) { sub in
        Text("\(sub.sourceName) devices will be replaced with \(sub.targetName), which doesn't sound identical.")
          .font(.caption).foregroundStyle(.orange)
      }

      Text("Originals are never changed, and existing output files are skipped.")
        .font(.caption).foregroundStyle(.secondary)

      HStack {
        Spacer()
        Button("Cancel") { onCancel() }.keyboardShortcut(.cancelAction)
        Button("Fix") {
          if let destination { onStart(chosen, destination) }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(destination == nil || chosen.isEmpty)
      }
    }
    .padding(20)
    .frame(width: 480)
  }

  private func chooseFolder() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.prompt = "Choose"
    if panel.runModal() == .OK, let url = panel.url { folderPath = url.path }
  }
}

/// A batch's progress, then its per-set results.
struct BatchProgressView: View {
  @EnvironmentObject var app: AppModel
  @ObservedObject var run: BatchController

  private func count(_ matches: (BatchSetResult.Outcome) -> Bool) -> Int {
    run.results.filter { matches($0.outcome) }.count
  }

  private var converted: Int {
    count { if case .converted = $0 { return true } else { return false } }
  }
  private var skipped: Int {
    count { if case .skipped = $0 { return true } else { return false } }
  }
  private var failed: Int {
    count { if case .failed = $0 { return true } else { return false } }
  }

  private var title: String {
    if !run.isFinished { return run.isCancelled ? "Cancelling…" : "Converting sets" }
    return run.isCancelled ? "Batch cancelled" : "Batch finished"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(title).font(.title2.weight(.semibold))
      ProgressView(value: Double(run.results.count), total: Double(max(run.jobs.count, 1)))
      Text(run.isFinished ? totals : "\(run.results.count) of \(run.jobs.count) · \(run.currentStep)")
        .font(.caption).foregroundStyle(.secondary).lineLimit(1)

      List(run.results.reversed()) { result in
        HStack(spacing: 8) {
          outcomeIcon(result.outcome)
          Text(result.set.name).lineLimit(1)
          Spacer(minLength: 8)
          Text(result.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .help(notes(of: result))
      }
      .listStyle(.plain)

      HStack {
        Spacer()
        if run.isFinished {
          if case .folder(let folder) = run.destination, converted > 0 {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
          }
          Button("Done") { app.dismissBatch() }.keyboardShortcut(.defaultAction)
        } else {
          Button("Cancel") { run.cancel() }.disabled(run.isCancelled)
        }
      }
    }
    .padding(24)
  }

  private var totals: String {
    let notStarted = run.jobs.count - run.results.count
    return "\(converted) converted · \(skipped) skipped · \(failed) failed"
      + (notStarted > 0 ? " · \(notStarted) not started" : "")
  }

  private func notes(of result: BatchSetResult) -> String {
    if case .converted(let output, _, _, _, _, let notes) = result.outcome {
      return ([output.path] + notes).joined(separator: "\n")
    }
    return result.summary
  }

  @ViewBuilder private func outcomeIcon(_ outcome: BatchSetResult.Outcome) -> some View {
    switch outcome {
    case .converted:
      Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Converted")
    case .skipped:
      Image(systemName: "minus.circle").foregroundStyle(.secondary).accessibilityLabel("Skipped")
    case .failed:
      Image(systemName: "xmark.circle.fill").foregroundStyle(.red).accessibilityLabel("Failed")
    }
  }
}
