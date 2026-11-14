import SwiftUI
import AppKit

// MARK: - Memoria

/// macOS gestisce la RAM da solo: "svuotarla" serve poco. Quello che aiuta davvero
/// è chiudere le app pesanti; purge libera la memoria inattiva, con effetto temporaneo.
struct MemoriaView: View {
    @ObservedObject var m: Monitor

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                Scheda(titolo: "Pressione RAM", valore: m.testoPressione, colore: m.colorePressione)
                Scheda(titolo: "RAM in uso", valore: "\(Sistema.formatoRAM(m.lettura.ram)) di \(Sistema.formatoRAM(Sistema.ramTotale))", colore: .secondary)
                Scheda(titolo: "Swap", valore: Sistema.formatoRAM(m.lettura.swap), colore: .secondary)
                VStack(alignment: .leading, spacing: 6) {
                    Button { Task { await m.liberaInattiva() } } label: {
                        Label(m.lavoro ? "Libero…" : "Libera memoria inattiva", systemImage: "wind")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(m.lavoro)
                    Text("Chiede la password. Effetto temporaneo.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(20)
            Divider()
            Text("Chiudere le app pesanti è il modo più efficace per alleggerire la RAM.")
                .font(.callout).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.top, 12)
            List(m.attive) { a in
                HStack(spacing: 10) {
                    if let i = a.icona { Image(nsImage: i).resizable().frame(width: 24, height: 24) }
                    Text(a.nome)
                    Spacer()
                    Text(a.byte > 0 ? Sistema.formatoRAM(a.byte) : "—").monospacedDigit().foregroundStyle(.secondary)
                    Button("Chiudi") { m.chiudi(a) }
                }
            }
            if let t = m.messaggio { Text(t).font(.callout).foregroundStyle(.secondary).padding(14) }
        }
        .toolbar { Button { m.aggiorna() } label: { Label("Aggiorna", systemImage: "arrow.clockwise") } }
        .task { m.aggiorna() }
    }
}

// MARK: - Disinstalla

struct AppInstallata: Identifiable, Hashable {
    var id: String { percorso }
    let percorso: String
    let nome: String
    let bundleID: String?
    var byte: Int64 = 0
}

struct Residuo: Identifiable, Hashable {
    var id: String { percorso }
    let percorso: String
    let byte: Int64
}

enum Disinstallatore {
    static let cartelle = ["/Applications", Sistema.home + "/Applications"]

    static func elencoApp() -> [AppInstallata] {
        let fm = FileManager.default
        return cartelle.flatMap { dir in
            ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".app") }.map { nome in
                let p = (dir as NSString).appendingPathComponent(nome)
                return AppInstallata(percorso: p, nome: (nome as NSString).deletingPathExtension,
                                     bundleID: Bundle(path: p)?.bundleIdentifier)
            }
        }
        .filter { $0.bundleID != Bundle.main.bundleIdentifier }
        .sorted { $0.nome.localizedCaseInsensitiveCompare($1.nome) == .orderedAscending }
    }

    /// File che l'app lascia nella Libreria. Si confrontano solo nomi identici al bundle ID
    /// (o che iniziano con "bundleID.") e al nome esatto dell'app, mai sottostringhe:
    /// "Claude" non deve trascinarsi dietro "Claude Code".
    static func residui(di a: AppInstallata) -> [Residuo] {
        let lib = Sistema.home + "/Library"
        let sotto = ["Application Support", "Caches", "Preferences", "Containers", "Group Containers",
                     "Saved Application State", "Logs", "HTTPStorages", "WebKit", "Cookies", "LaunchAgents",
                     "Application Scripts", "Preferences/ByHost"]
        let fm = FileManager.default
        var percorsi: [String] = []
        for s in sotto {
            let dir = "\(lib)/\(s)"
            for voce in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where corrisponde(voce, a) {
                let p = "\(dir)/\(voce)"
                if Sistema.percorsoReale(p) { percorsi.append(p) }
            }
        }
        return zip(percorsi, Sistema.dimensioni(percorsi)).map { Residuo(percorso: $0, byte: $1) }.sorted { $0.byte > $1.byte }
    }

    static func corrisponde(_ voce: String, _ a: AppInstallata) -> Bool {
        let base = voce.replacingOccurrences(of: ".plist", with: "").replacingOccurrences(of: ".savedState", with: "")
        if let id = a.bundleID?.lowercased() {
            let b = base.lowercased()
            // Group Containers usano il prefisso del team: "ABCDE12345.com.esempio.app".
            if b == id || b.hasPrefix(id + ".") || b.hasSuffix("." + id) { return true }
        }
        return base.caseInsensitiveCompare(a.nome) == .orderedSame
    }
}

@MainActor
final class StatoDisinstalla: ObservableObject {
    @Published var app: [AppInstallata] = []
    @Published var filtro = ""
    @Published var scelta: AppInstallata?
    @Published var residui: [Residuo] = []
    @Published var esclusi: Set<String> = []
    @Published var carico = false
    @Published var conferma = false
    @Published var messaggio: String?

    var visibili: [AppInstallata] {
        filtro.isEmpty ? app : app.filter { $0.nome.localizedCaseInsensitiveContains(filtro) }
    }
    var daRimuovere: [String] {
        guard let a = scelta else { return [] }
        return [a.percorso] + residui.map(\.percorso).filter { !esclusi.contains($0) }
    }
    var totale: Int64 { (scelta?.byte ?? 0) + residui.filter { !esclusi.contains($0.percorso) }.reduce(0) { $0 + $1.byte } }
    var aperta: Bool {
        guard let id = scelta?.bundleID else { return false }
        return !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty
    }

    func carica() async {
        let elenco = await Task.detached { Disinstallatore.elencoApp() }.value
        app = elenco
        // Le dimensioni arrivano dopo, per non far aspettare l'elenco.
        let misurate = await Task.detached(priority: .userInitiated) {
            zip(elenco, Sistema.dimensioni(elenco.map(\.percorso))).map { a, byte in var a = a; a.byte = byte; return a }
        }.value
        app = misurate
        if let s = scelta { scelta = misurate.first { $0.id == s.id } }
    }

    func seleziona(_ a: AppInstallata) async {
        scelta = a; residui = []; esclusi = []; messaggio = nil; carico = true
        let trovati = await Task.detached(priority: .userInitiated) { Disinstallatore.residui(di: a) }.value
        // Se nel frattempo è stata scelta un'altra app, questi residui non sono i suoi.
        guard scelta?.id == a.id else { return }
        residui = trovati
        carico = false
    }

    /// Sposta nel Cestino invece di cancellare: se qualcosa era da tenere, si recupera.
    /// NSWorkspace chiede la password da sé per le app installate dall'amministratore.
    func disinstalla() async {
        let url = daRimuovere.map { URL(fileURLWithPath: $0) }
        let nome = scelta?.nome ?? ""
        do {
            try await NSWorkspace.shared.recycle(url)
            messaggio = "\(nome) è nel Cestino con \(url.count - 1) file collegati. Svuota il Cestino per liberare lo spazio."
            scelta = nil; residui = []
        } catch {
            messaggio = "Non completata: \(error.localizedDescription)"
        }
        await carica()
    }
}

struct DisinstallaView: View {
    @ObservedObject var s: StatoDisinstalla

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                TextField("Cerca app", text: $s.filtro).textFieldStyle(.roundedBorder).padding(10)
                List(s.visibili, selection: Binding(get: { s.scelta?.id }, set: { id in
                    if let a = s.app.first(where: { $0.id == id }) { Task { await s.seleziona(a) } }
                })) { a in
                    HStack {
                        Image(nsImage: Sistema.icona(a.percorso)).resizable().frame(width: 22, height: 22)
                        Text(a.nome).lineLimit(1)
                        Spacer()
                        Text(a.byte > 0 ? Sistema.formato(a.byte) : "").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .tag(a.id)
                }
            }
            .frame(minWidth: 260, idealWidth: 290)

            dettaglio.frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { if s.app.isEmpty { await s.carica() } }
        .confirmationDialog("Spostare nel Cestino \(s.scelta?.nome ?? "") e \(s.daRimuovere.count - 1) file collegati?",
                            isPresented: $s.conferma) {
            Button("Sposta nel Cestino", role: .destructive) { Task { await s.disinstalla() } }
        } message: {
            Text("Totale \(Sistema.formato(s.totale)). Si recupera dal Cestino finché non lo svuoti.")
        }
    }

    @ViewBuilder var dettaglio: some View {
        if let a = s.scelta {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14) {
                    Image(nsImage: Sistema.icona(a.percorso)).resizable().frame(width: 48, height: 48)
                    VStack(alignment: .leading) {
                        Text(a.nome).font(.title2.bold())
                        Text(a.bundleID ?? "bundle ID sconosciuto").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(20)
                Divider()
                if s.carico {
                    ProgressView("Cerco i file collegati…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        Section("App") {
                            HStack { Text(a.percorso).font(.caption); Spacer(); Text(Sistema.formato(a.byte)).monospacedDigit() }
                        }
                        Section("File collegati nella Libreria (togli la spunta per tenerli)") {
                            if s.residui.isEmpty { Text("Nessuno trovato.").foregroundStyle(.secondary) }
                            ForEach(s.residui) { r in
                                Toggle(isOn: Binding(get: { !s.esclusi.contains(r.percorso) },
                                                     set: { if $0 { s.esclusi.remove(r.percorso) } else { s.esclusi.insert(r.percorso) } })) {
                                    HStack {
                                        Text(r.percorso.replacingOccurrences(of: Sistema.home, with: "~")).font(.caption).lineLimit(1).truncationMode(.middle)
                                        Spacer()
                                        Text(Sistema.formato(r.byte)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
                Divider()
                HStack {
                    if s.aperta { Label("Chiudi l'app prima di disinstallarla", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                    Spacer()
                    Text("Totale: \(Sistema.formato(s.totale))").monospacedDigit()
                    Button("Disinstalla") { s.conferma = true }
                        .buttonStyle(.borderedProminent).tint(.red)
                        .disabled(s.carico || s.aperta)
                }
                .padding(14)
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "trash.square").font(.system(size: 44)).foregroundStyle(.tertiary)
                Text("Scegli un'app per vedere cosa lascia sul disco.").foregroundStyle(.secondary)
                if let m = s.messaggio { Text(m).font(.callout).multilineTextAlignment(.center).padding(.top, 8) }
            }
            .padding(30)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
