import SwiftUI
import AppKit

// MARK: - Monitor

/// Lo stato vivo del Mac, condiviso tra la finestra e la barra dei menu.
/// Le letture veloci (pressione, RAM, swap, disco) girano con un timer; l'elenco delle app,
/// più costoso, si aggiorna solo quando qualcuno lo sta guardando.
@MainActor
final class Monitor: ObservableObject {
    struct Lettura {
        var disco = Sistema.disco()
        var pressione = Sistema.pressioneRAM()
        var swap = Sistema.swapUsato()
        var ram = Sistema.ramUsata()

        /// Le variazioni minime non meritano un ridisegno.
        func simile(a l: Lettura) -> Bool {
            pressione == l.pressione && abs(ram - l.ram) < 32 << 20 && abs(swap - l.swap) < 32 << 20
                && abs(disco.libero - l.disco.libero) < 64 << 20
        }
    }

    struct AppAttiva: Identifiable {
        let id: pid_t
        let nome: String
        let icona: NSImage?
        let byte: Int64
        let app: NSRunningApplication
    }

    /// Quello che mostra la barra dei menu. Sta in un oggetto a parte e cambia di rado,
    /// così l'icona non si ridisegna a ogni lettura.
    final class Spia: ObservableObject {
        @Published var percentuale = 0
        @Published var critico = false
    }

    let spia = Spia()
    @Published private(set) var lettura = Lettura()
    @Published private(set) var pesi: [Sistema.Peso] = []
    @Published private(set) var attive: [AppAttiva] = []
    @Published var messaggio: String?
    @Published var lavoro = false

    /// La finestra principale e il pannello della barra dei menu: finché nessuno dei due
    /// è a schermo, i numeri di dettaglio non si aggiornano e non ridisegnano niente.
    weak var finestra: NSWindow?
    weak var pannello: NSWindow?
    private var timer: Timer?
    private var aSchermo: Bool {
        finestra?.occlusionState.contains(.visible) == true || pannello?.isVisible == true
    }

    init() {
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.leggi() }
        }
        t.tolerance = 1
        RunLoop.main.add(t, forMode: .common)
        timer = t
        segnala(lettura)
    }

    var percentualeRAM: Int { Self.percentuale(lettura) }
    private static func percentuale(_ l: Lettura) -> Int { Int((Double(l.ram) / Double(max(Sistema.ramTotale, 1)) * 100).rounded()) }

    private func segnala(_ l: Lettura) {
        let percentuale = Self.percentuale(l), critico = l.pressione >= 4 || l.disco.libero < 5 << 30
        if spia.percentuale != percentuale { spia.percentuale = percentuale }
        if spia.critico != critico { spia.critico = critico }
    }
    var testoPressione: String { [1: "normale", 2: "elevata", 4: "critica"][lettura.pressione] ?? "n/d" }
    var colorePressione: Color { [1: Color.abrasivo, 2: .orange, 4: .red][lettura.pressione] ?? .secondary }
    var coloreDisco: Color { lettura.disco.libero < 5 << 30 ? .red : lettura.disco.libero < 40 << 30 ? .orange : .abrasivo }
    /// Le app sopra i 150 MB, per la Panoramica.
    var pesanti: [Sistema.Peso] { Array(pesi.filter { $0.byte > 150 << 20 }.prefix(8)) }

    func leggi() {
        let nuova = Lettura()
        segnala(nuova)
        if aSchermo, !nuova.simile(a: lettura) { lettura = nuova }
    }

    /// Letture veloci subito, elenco delle app appena pronto.
    func aggiorna() {
        lettura = Lettura()
        segnala(lettura)
        Task.detached(priority: .userInitiated) {
            let pesi = Sistema.memoriaApp()
            await MainActor.run { self.imposta(pesi) }
        }
    }

    private func imposta(_ nuovi: [Sistema.Peso]) {
        pesi = nuovi
        let perPercorso = Dictionary(nuovi.compactMap { p in p.percorso.map { ($0, p.byte) } }, uniquingKeysWith: +)
        let mie = Bundle.main.bundleIdentifier
        attive = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != mie && $0.bundleIdentifier != "com.apple.finder" }
            .compactMap { r in
                guard let nome = r.localizedName else { return nil }
                let byte = r.bundleURL.flatMap { perPercorso[$0.path] } ?? 0
                return AppAttiva(id: r.processIdentifier, nome: nome, icona: r.icon, byte: byte, app: r)
            }
            .sorted { $0.byte > $1.byte }
    }

    /// Chiusura normale: l'app può chiedere di salvare i documenti aperti.
    func chiudi(_ a: AppAttiva) {
        a.app.terminate()
        messaggio = "Chiesto a \(a.nome) di chiudersi."
        Task { try? await Task.sleep(for: .seconds(2)); aggiorna() }
    }

    /// purge richiede la password di amministratore, chiesta da macOS stesso.
    func liberaInattiva() async {
        lavoro = true
        let prima = Sistema.ramUsata()
        let codice = await Task.detached {
            Sistema.esegui("/usr/bin/osascript", ["-e", "do shell script \"/usr/sbin/purge\" with administrator privileges"]).codice
        }.value
        lavoro = false
        messaggio = codice == 0
            ? "Memoria inattiva liberata. In uso: \(Sistema.formatoRAM(prima)) → \(Sistema.formatoRAM(Sistema.ramUsata()))."
            : "Operazione annullata."
        aggiorna()
    }
}

// MARK: - Barra dei menu

struct EtichettaMenu: View {
    @ObservedObject var spia: Monitor.Spia
    var body: some View {
        Image(systemName: spia.critico ? "exclamationmark.triangle.fill" : "bubbles.and.sparkles")
        Text("\(spia.percentuale)%")
    }
}

struct Barra: View {
    let valore: Double
    let colore: Color
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(colore).frame(width: max(6, g.size.width * min(max(valore, 0), 1)))
            }
        }
        .frame(height: 6)
    }
}

/// Il pannello che si apre dall'icona: stato in breve e due azioni rapide,
/// liberare memoria e liberare spazio, senza aprire la finestra.
struct PannelloMenu: View {
    @ObservedObject var m: Monitor
    @ObservedObject var p: StatoPulizia
    @ObservedObject var radice: StatoRadice
    @Environment(\.openWindow) private var apriFinestra

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            memoria
            Divider()
            disco
            Divider()
            HStack {
                Button("Apri Pina") { apri(nil) }
                Spacer()
                Button("Esci") { NSApp.terminate(nil) }
            }
            .buttonStyle(.link)
        }
        .padding(14)
        .frame(width: 320)
        .tint(Color.pina)
        .background(Aggancio { m.pannello = $0 })
        .onAppear { rinfresca() }
        // onAppear vale per la prima apertura; le successive si riconoscono dalla finestra che torna attiva.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { n in
            if let f = n.object as? NSWindow, f === m.pannello { rinfresca() }
        }
    }

    /// A ogni apertura: dati freschi e nessuna conferma rimasta a metà.
    func rinfresca() {
        p.confermaRapida = false
        m.aggiorna()
        Task { await p.analizzaSeServe() }
    }

    // MARK: Memoria

    @ViewBuilder var memoria: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Memoria", systemImage: "memorychip").font(.headline)
                Spacer()
                Text("pressione \(m.testoPressione)").font(.caption).foregroundStyle(m.colorePressione)
            }
            Barra(valore: Double(m.lettura.ram) / Double(max(Sistema.ramTotale, 1)), colore: m.colorePressione)
            Text("\(Sistema.formatoRAM(m.lettura.ram)) di \(Sistema.formatoRAM(Sistema.ramTotale)) in uso · swap \(Sistema.formatoRAM(m.lettura.swap))")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            ForEach(m.attive.filter { $0.byte > 0 }.prefix(3)) { a in
                HStack(spacing: 8) {
                    if let i = a.icona { Image(nsImage: i).resizable().frame(width: 18, height: 18) }
                    Text(a.nome).lineLimit(1)
                    Spacer()
                    Text(Sistema.formatoRAM(a.byte)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    Button("Chiudi") { m.chiudi(a) }.controlSize(.small)
                }
            }
            HStack {
                Button { Task { await m.liberaInattiva() } } label: {
                    Label(m.lavoro ? "Libero…" : "Libera memoria inattiva", systemImage: "wind")
                }
                .disabled(m.lavoro)
                Spacer()
                Text("chiede la password").font(.caption).foregroundStyle(.secondary)
            }
            if let t = m.messaggio { Text(t).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }

    // MARK: Disco

    @ViewBuilder var disco: some View {
        let d = m.lettura.disco
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Disco", systemImage: "internaldrive").font(.headline)
                Spacer()
                Text("\(Sistema.formato(d.libero)) liberi").font(.caption).foregroundStyle(m.coloreDisco).monospacedDigit()
            }
            Barra(valore: 1 - Double(d.libero) / Double(max(d.totale, 1)), colore: m.coloreDisco)
            if p.lavoro {
                ProgressView(value: p.progresso)
                Text("Pulizia in corso… liberati \(Sistema.formato(p.liberati))").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            } else if p.confermaRapida {
                conferma
            } else {
                HStack {
                    if p.analisi && p.categorie.isEmpty {
                        ProgressView().controlSize(.small)
                        Text("Misuro le cache…").font(.caption).foregroundStyle(.secondary)
                    } else if p.pulibili.isEmpty {
                        Text(p.esito ?? "Niente da pulire.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(Sistema.formato(p.recuperabile)) recuperabili").monospacedDigit()
                            Text(p.esito ?? "\(p.pulibili.count) tra cache e build").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Dettagli") { apri(.pulizia) }.buttonStyle(.link).controlSize(.small)
                    Button("Pulisci…") { p.confermaRapida = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(p.pulibili.isEmpty || p.analisi)
                }
            }
        }
    }

    /// Niente si elimina senza aver mostrato i percorsi esatti, anche da qui.
    @ViewBuilder var conferma: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Eliminare \(p.pulibili.count) elementi (\(Sistema.formato(p.recuperabile)))?").font(.callout.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(p.pulibili) { v in
                        HStack {
                            Text(v.dettaglio == v.titolo ? v.titolo : "\(v.titolo) · \(v.dettaglio)").lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(Sistema.formato(v.byte)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                }
            }
            .frame(maxHeight: 130)
            Text("Sono cache e cartelle di build: si ricreano da sole. L'eliminazione è definitiva, non passa dal Cestino.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Annulla") { p.confermaRapida = false }.keyboardShortcut(.cancelAction)
                Button("Elimina", role: .destructive) { Task { await p.puliziaRapida() } }
                    .buttonStyle(.borderedProminent).tint(.red)
            }
        }
    }

    /// Porta in primo piano la finestra principale, riaprendola se era stata chiusa.
    func apri(_ sezione: Sezione?) {
        if let sezione { radice.sezione = sezione }
        NSApp.activate(ignoringOtherApps: true)
        if let f = radice.finestra, f.isVisible || f.isMiniaturized {
            if f.isMiniaturized { f.deminiaturize(nil) }
            f.makeKeyAndOrderFront(nil)
        } else {
            apriFinestra(id: PinaApp.finestra)
        }
    }
}

/// Dice a chi serve in quale finestra AppKit si trova una vista SwiftUI.
struct Aggancio: NSViewRepresentable {
    let trovata: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView { Vista(trovata) }
    func updateNSView(_ vista: NSView, context: Context) {}

    final class Vista: NSView {
        let trovata: (NSWindow) -> Void
        init(_ trovata: @escaping (NSWindow) -> Void) { self.trovata = trovata; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() { if let window { trovata(window) } }
    }
}
