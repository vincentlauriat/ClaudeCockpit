import SwiftUI
import AppKit
import CockpitShared

/// The preferences surface, shown both in the `Settings` scene (⌘,) and embedded in the
/// main window's detail area — hence flexible sizing rather than a fixed frame.
struct SettingsView: View {
    private enum Tab: String, Hashable {
        case general, pricing, rtk, projects, updates
    }

    @State private var selection: Tab = .general

    var body: some View {
        TabView(selection: $selection) {
            GeneralSettingsTab()
                .tabItem { Label("Général", systemImage: "gearshape") }
                .tag(Tab.general)
            PricingEditorView()
                .tabItem { Label("Tarifs", systemImage: "dollarsign.circle") }
                .tag(Tab.pricing)
            RTKSettingsTab()
                .tabItem { Label("RTK", systemImage: "leaf.fill") }
                .tag(Tab.rtk)
            ProjectsSettingsTab()
                .tabItem { Label("Projets", systemImage: "folder") }
                .tag(Tab.projects)
            UpdatesSettingsTab()
                .tabItem { Label("Mises à jour", systemImage: "arrow.triangle.2.circlepath") }
                .tag(Tab.updates)
        }
        .frame(
            minWidth: 560, idealWidth: 560, maxWidth: .infinity,
            minHeight: 520, idealHeight: 520, maxHeight: .infinity)
    }
}

// MARK: - Général

private struct GeneralSettingsTab: View {
    @Environment(CockpitStore.self) private var store

    @AppStorage(SettingsKey.menuBarOnly) private var menuBarOnly = false
    @AppStorage(SettingsKey.menuBarMeter) private var menuBarMeter = MenuBarMeter.week.rawValue
    @AppStorage(SettingsKey.usageRefreshSeconds) private var refreshSeconds = 30
    @AppStorage(SettingsKey.currency) private var currency = "USD"
    @AppStorage(SettingsKey.eurRate) private var eurRate = 0.92
    @AppStorage(SettingsKey.sessionsIndexEnabled) private var sessionsIndexEnabled = true
    @AppStorage(SettingsKey.sessionsShowSystemLines) private var sessionsShowSystemLines = false

    /// Mirrors `SMAppService`'s real state: the store exposes it read-only, so the toggle
    /// keeps its own copy and reverts it when registration throws.
    @State private var launchAtLogin = false
    @State private var loginError: String?
    @State private var confirmRebuild = false

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    var body: some View {
        Form {
            Section("Démarrage") {
                Toggle("Lancer à la connexion", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in setLaunchAtLogin(newValue) }
                Toggle("Barre de menus seulement (masquer l'icône du Dock)", isOn: $menuBarOnly)
                    .onChange(of: menuBarOnly) { _, newValue in store.setMenuBarOnly(newValue) }
                Text("L'icône de la barre de menus reste visible dans tous les cas.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.slate)
                Picker("Pourcentage affiché dans la barre de menus", selection: $menuBarMeter) {
                    ForEach(MenuBarMeter.allCases) { meter in
                        Text(meter.label).tag(meter.rawValue)
                    }
                }
                .onChange(of: menuBarMeter) { _, raw in
                    // The store keeps its own observable copy; a bare defaults
                    // read would not redraw the menu bar until the next fetch.
                    store.setMenuBarMeter(MenuBarMeter(rawValue: raw) ?? .week)
                }
                Text("La session de 5 h dit si vous pouvez continuer maintenant, la fenêtre de 7 jours si la semaine tient.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.slate)
            }

            Section("Données") {
                Picker("Rafraîchissement de l'usage local", selection: $refreshSeconds) {
                    Text("10 secondes").tag(10)
                    Text("30 secondes").tag(30)
                    Text("60 secondes").tag(60)
                    Text("120 secondes").tag(120)
                }
                Text("Le nouvel intervalle s'applique après le cycle en cours.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.slate)
            }

            Section("Affichage") {
                Picker("Devise", selection: $currency) {
                    Text("Dollar (USD)").tag("USD")
                    Text("Euro (EUR)").tag("EUR")
                }
                if currency == "EUR" {
                    TextField(
                        "Taux USD → EUR",
                        value: $eurRate,
                        format: .number.precision(.fractionLength(0...4)))
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                    Text("Les montants sont calculés en dollars puis convertis avec ce taux.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.slate)
                }
            }

            sessionsSection
        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin = store.launchAtLogin }
        .alert(
            "Lancement à la connexion",
            isPresented: Binding(get: { loginError != nil }, set: { if !$0 { loginError = nil } })
        ) {
            Button("OK", role: .cancel) { loginError = nil }
        } message: {
            Text(loginError ?? "")
        }
        .alert("Reconstruire l'index des sessions ?", isPresented: $confirmRebuild) {
            Button("Annuler", role: .cancel) { confirmRebuild = false }
            Button("Reconstruire", role: .destructive) {
                Task { await store.rebuildSessionIndex() }
            }
        } message: {
            Text("Tous les transcripts de ~/.claude/projects seront relus depuis le début, ce qui peut prendre plusieurs minutes. Les transcripts eux-mêmes ne sont jamais modifiés.")
        }
    }

    // MARK: Sessions

    private var sessionsSection: some View {
        Section("Sessions") {
            Toggle("Indexer les transcripts", isOn: $sessionsIndexEnabled)
                // Restarts indexing and arms the FSEvents watcher, or stops both when the
                // toggle goes off. The store reads the flag itself.
                .onChange(of: sessionsIndexEnabled) { _, _ in store.sessionsIndexingDidChange() }
            Text("La section Sessions ne fonctionne qu'avec cet index. Il est reconstructible à tout moment et ne modifie jamais les transcripts.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.slate)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Afficher les lignes système dans les transcripts", isOn: $sessionsShowSystemLines)
            Text("Hooks, méta-lignes et pièces jointes, masqués par défaut.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.slate)
                .fixedSize(horizontal: false, vertical: true)

            LabeledContent("État de l'index") {
                Text(indexStateLabel)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(Theme.slate)
                    .multilineTextAlignment(.trailing)
            }
            HStack {
                Button("Reconstruire l'index") { confirmRebuild = true }
                    .disabled(store.sessionIndex.isRunning)
                if store.sessionIndex.isRunning {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Text("Taille : \(Self.byteFormatter.string(fromByteCount: store.sessionIndex.dbSizeBytes))")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(Theme.slate)
            }
        }
    }

    private var indexStateLabel: String {
        let progress = store.sessionIndex
        if progress.isRunning {
            return "\(FRFormat.integer(progress.filesDone)) / \(FRFormat.integer(progress.filesTotal)) transcripts"
        }
        guard let last = progress.lastRun else { return "jamais indexé" }
        // `filesDone` counts the files the last pass actually read, which is a handful
        // on an incremental tick — so it is shown against `filesTotal`, never alone.
        return "dernier passage : \(FRFormat.integer(progress.filesDone)) / \(FRFormat.integer(progress.filesTotal)) · \(FRFormat.relative(last))"
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try store.setLaunchAtLogin(enabled)
        } catch let error as NSError {
            // Code 3 = l'app doit être installée dans /Applications ; fréquent en debug.
            loginError = error.code == 3
                ? "L'application doit se trouver dans /Applications pour être lancée à la connexion."
                : "Impossible de modifier le réglage : \(error.localizedDescription)"
            launchAtLogin = store.launchAtLogin
        }
    }
}

// MARK: - RTK

private struct RTKSettingsTab: View {
    @Environment(CockpitStore.self) private var store
    @AppStorage(SettingsKey.rtkDBPath) private var rtkPath = ""

    var body: some View {
        Form {
            Section("Base de données RTK") {
                LabeledContent("Base utilisée") {
                    Text(store.rtkDatabaseURL?.path ?? "introuvable")
                        .font(.data(11))
                        .foregroundStyle(store.rtkDatabaseURL == nil ? Color.orange : Theme.slate)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                }
                TextField("Chemin personnalisé", text: $rtkPath, prompt: Text("Automatique"))
                    .font(.data(11))
                    .onSubmit { store.rtkPathDidChange() }
                HStack {
                    Button("Choisir…") { chooseDatabase() }
                    Button("Automatique") {
                        rtkPath = ""
                        store.rtkPathDidChange()
                    }
                    .disabled(rtkPath.isEmpty)
                    Spacer()
                    Button("Recharger") { Task { await store.refreshRTK() } }
                }
                Text("Laisser vide pour la détection automatique (Application Support, puis ~/.local/share/rtk).")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.slate)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    private func chooseDatabase() {
        let panel = NSOpenPanel()
        panel.title = "Choisir la base de données RTK"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        rtkPath = url.path
        store.rtkPathDidChange()
    }
}

// MARK: - Projets

private struct ProjectsSettingsTab: View {
    @Environment(CockpitStore.self) private var store
    @AppStorage(SettingsKey.projectRoots) private var projectRoots = ""

    var body: some View {
        Form {
            Section("Racines de projets") {
                TextEditor(text: $projectRoots)
                    .font(.data(11))
                    .frame(minHeight: 140)
                Text("Une racine par ligne, le « ~ » est accepté. Vide = ~/DevApps et ~/Documents/GitHub.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.slate)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Rescanner") { Task { await store.refreshSkills() } }
                    Spacer()
                    Text("\(store.projectRoots.count) racine(s) analysée(s)")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.slate)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Mises à jour

private struct UpdatesSettingsTab: View {
    @EnvironmentObject private var updater: UpdaterController

    var body: some View {
        Form {
            Section("Mises à jour") {
                LabeledContent("Version installée") {
                    Text(updater.currentVersion).monospacedDigit().foregroundStyle(Theme.slate)
                }
                if let pending = updater.pendingVersion {
                    Label("Version \(pending) disponible", systemImage: "arrow.down.circle.fill")
                        .foregroundStyle(Theme.accent)
                }
                HStack {
                    Button("Rechercher des mises à jour") { updater.checkForUpdates() }
                        .disabled(!updater.canCheck)
                    Spacer()
                    Link("Toutes les versions", destination: releasesURL)
                }
            }

            Section("À propos") {
                Text("Claude Cockpit — tableau de bord local pour Claude Code.")
                    .font(.system(size: 12))
                Text("© 2026 Vincent Lauriat — licence MIT")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.slate)
                Link("lauriat.fr", destination: URL(string: "https://lauriat.fr")!)
                Link("Site du projet", destination: URL(string: "https://vincentlauriat.github.io/ClaudeCockpit/")!)
            }
        }
        .formStyle(.grouped)
    }

    private var releasesURL: URL {
        URL(string: "https://github.com/vincentlauriat/ClaudeCockpit/releases")!
    }
}
