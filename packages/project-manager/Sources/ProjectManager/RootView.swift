import SwiftUI

/// The window's content: a welcome until a folder is open, then the library.
struct RootView: View {
  @EnvironmentObject var app: AppModel

  var body: some View {
    Group {
      if app.root == nil {
        WelcomeView()
      } else {
        NavigationSplitView {
          LibrarySidebar()
            .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 440)
        } detail: {
          detail
        }
      }
    }
    .frame(minWidth: 920, minHeight: 520)
    .sheet(item: $app.batchRequest) { request in
      BatchSheet(title: request.title, candidates: request.candidates,
                 replacing: Substitution.allCases.filter(app.catalogs.substitutions.contains)) { chosen, destination in
        app.batchRequest = nil
        app.startBatch(sets: chosen, destination: destination)
      } onCancel: {
        app.batchRequest = nil
      }
    }
  }

  @ViewBuilder private var detail: some View {
    if let batch = app.batch {
      BatchProgressView(run: batch)
    } else if app.selection.count > 1 {
      SelectionPage()
    } else {
      switch app.focus {
      case .set(let url)?:
        SetDetailView(url: url)
      case .plugins?:
        PluginsPage()
      case .project(let url)?:
        SetsPage(project: url)
      case .overview?, nil:
        SetsPage(project: nil)
      }
    }
  }
}

private struct WelcomeView: View {
  @EnvironmentObject var app: AppModel

  var body: some View {
    ContentUnavailableView {
      Label("Ableton Projects", systemImage: "slider.horizontal.2.square.on.square")
    } description: {
      Text(app.openError ?? "Open your Projects folder, or one project folder.")
    } actions: {
      Button("Open…") { app.presentOpenPanel() }
    }
  }
}

/// One set's page, with its own state object.
private struct SetDetailView: View {
  @EnvironmentObject var app: AppModel
  let url: URL

  var body: some View {
    let model = app.model(for: url)
    SetPageView()
      .environmentObject(model)
      .id(ObjectIdentifier(model))
  }
}
