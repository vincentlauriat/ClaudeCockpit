import SwiftUI
import AppKit

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
    @AppStorage(SettingsKey.usageRefreshSeconds) private var refreshSeconds = 30
    @AppStorage(SettingsKey.currency) private var currency = "USD"
    @AppStorage(SettingsKey.eurRate) private var eurRate = 0.92

    /// Mirrors `SMAppService`'s real state: the store exposes it read-only, so the toggle
    /// keeps its own copy and reverts it when registration throws.
    @State private var launchAtLogin = false
    @State private var loginError: String?

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
