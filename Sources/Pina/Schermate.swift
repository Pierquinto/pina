import SwiftUI
import AppKit

// MARK: - Pulizia

@MainActor
final class StatoPulizia: ObservableObject {
    @Published var categorie: [Categoria] = []
    @Published var scelte: Set<String> = []
    @Published var analisi = false
    @Published var lavoro = false
    @Published var conferma = false
    @Published var esito: String?

    private var osservatori: [NSObjectProtocol] = []

    /// Quando un'app si apre o si chiude, le sue cache si bloccano o si sbloccano da sole.
    init() {
        let centro = NSWorkspace.shared.notificationCenter
        for nome in [NSWorkspace.didTerminateApplicationNotification, NSWorkspace.didLaunchApplicationNotification] {
            osservatori.append(centro.addObserver(forName: nome, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.aggiornaBlocchi() }
            })
        }
    }

    deinit { osservatori.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) } }

    func aggiornaBlocchi() {
        let blocchi = Dictionary(uniqueKeysWithValues: Catalogo.cacheApp().map { ($0.id, $0.bloccata) })
        for c in categorie.indices {
            for v in categorie[c].voci.indices {
                if let b = blocchi[categorie[c].voci[v].id] { categorie[c].voci[v].bloccata = b }
            }
        }
        scelte = scelte.filter { id in categorie.flatMap(\.voci).contains { $0.id == id && $0.bloccata == nil } }
    }

    var selezionate: [Voce] { categorie.flatMap(\.voci).filter { scelte.contains($0.id) && $0.bloccata == nil } }
    var totale: Int64 { selezionate.reduce(0) { $0 + $1.byte } }

    /// Le voci bloccate (app aperta) restano fuori.
    func selezionaTutto() {
        scelte = Set(categorie.flatMap(\.voci).filter { $0.bloccata == nil }.map(\.id))
    }

    func analizza() async {
        analisi = true
        let risultato = await Task.detached { () -> [Categoria] in
            Catalogo.tutte().map { c in
                var c = c
                c.voci = c.voci.compactMap { v in
                    var v = v
                    switch v.tipo {
                    case .cartella(let p):
                        guard Sistema.esiste(p), Sistema.percorsoReale(p) else { return nil }
                        v.byte = Sistema.dimensione(p)
                    case .comando:
                        v.byte = Sistema.dimensione(Sistema.home + "/Library/Caches/Homebrew")
                    }
                    return v.byte > 0 ? v : nil
                }.sorted { $0.byte > $1.byte }
                return c
            }.filter { !$0.voci.isEmpty }
        }.value
        categorie = risultato
        scelte = scelte.filter { id in risultato.contains { $0.voci.contains { $0.id == id } } }
        analisi = false
    }

    enum Fase: Equatable { case attesa, inCorso(Double), fatta, parziale(Int), saltata(String) }

    @Published var coda: [Voce] = []
    @Published var fasi: [String: Fase] = [:]
    @Published var liberati: Int64 = 0
    @Published var finito = false

    var progresso: Double {
        guard !coda.isEmpty else { return 0 }
        let somma = coda.reduce(0.0) { acc, v in
            switch fasi[v.id] ?? .attesa {
            case .attesa: acc
            case .inCorso(let f): acc + f
            default: acc + 1
            }
        }
        return somma / Double(coda.count)
    }

    func pulisci() async {
        coda = selezionate
        fasi = Dictionary(uniqueKeysWithValues: coda.map { ($0.id, Fase.attesa) })
        liberati = 0
        finito = false
        lavoro = true
        let prima = Sistema.disco().libero
        for v in coda {
            fasi[v.id] = .inCorso(0)
            let esitoVoce = await Task.detached {
                Catalogo.pulisci(v) { f in Task { @MainActor in
                    if case .inCorso = self.fasi[v.id] { self.fasi[v.id] = .inCorso(f) }
                } }
            }.value
            if let m = esitoVoce.motivo { fasi[v.id] = .saltata(m) }
            else if esitoVoce.falliti > 0 { fasi[v.id] = .parziale(esitoVoce.falliti) }
            else { fasi[v.id] = .fatta }
            liberati = max(0, Sistema.disco().libero - prima)
        }
        let problemi = fasi.values.filter { if case .fatta = $0 { false } else { true } }.count
        esito = "Liberati \(Sistema.formato(liberati))" + (problemi == 0 ? "." : ", \(problemi) voci non del tutto pulite.")
        finito = true
        scelte = []
        await analizza()
    }

    func chiudiAvanzamento() { lavoro = false; coda = [] }
}

struct PuliziaView: View {
    @StateObject private var s = StatoPulizia()

    var body: some View {
        VStack(spacing: 0) {
            if s.analisi && s.categorie.isEmpty {
                ProgressView("Misuro le cartelle…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(s.categorie) { c in
                        Section {
                            ForEach(c.voci) { v in riga(v) }
                        } header: {
                            HStack {
                                Label(c.titolo, systemImage: c.simbolo).font(.headline)
                                Spacer()
                                Text(Sistema.formato(c.voci.reduce(0) { $0 + $1.byte })).foregroundStyle(.secondary)
                                let ids = Set(c.voci.filter { $0.bloccata == nil }.map(\.id))
                                Button(ids.isSubset(of: s.scelte) ? "Nessuna" : "Tutte") {
                                    if ids.isSubset(of: s.scelte) { s.scelte.subtract(ids) } else { s.scelte.formUnion(ids) }
                                }
                                .buttonStyle(.link)
                                .disabled(ids.isEmpty)
                            }
                        } footer: { Text(c.nota).font(.caption) }
                    }
                }
            }
            Divider()
            HStack {
                Button { Task { await s.analizza() } } label: {
                    Label(s.analisi ? "Ricontrollo…" : "Ricontrolla", systemImage: "arrow.clockwise")
                }
                .disabled(s.analisi || s.lavoro)
                if let esito = s.esito { Text(esito).foregroundStyle(.secondary) }
                Spacer()
                Text("Selezionato: \(Sistema.formato(s.totale))").monospacedDigit()
                Button("Pulisci") { s.conferma = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(s.selezionate.isEmpty || s.lavoro)
            }
            .padding(14)
        }
        .toolbar {
            Button { s.selezionaTutto() } label: { Label("Seleziona tutto", systemImage: "checkmark.circle") }
                .keyboardShortcut("a", modifiers: .command)
            Button { s.scelte = [] } label: { Label("Deseleziona", systemImage: "circle") }
                .keyboardShortcut("a", modifiers: [.command, .shift])
            Button { Task { await s.analizza() } } label: { Label("Analizza", systemImage: "arrow.clockwise") }.disabled(s.analisi)
        }
        .task { if s.categorie.isEmpty { await s.analizza() } }
        .sheet(isPresented: Binding(get: { s.lavoro }, set: { if !$0 { s.chiudiAvanzamento() } })) {
            Avanzamento(s: s)
        }
        .confirmationDialog("Eliminare \(s.selezionate.count) elementi (\(Sistema.formato(s.totale)))?", isPresented: $s.conferma) {
            Button("Elimina", role: .destructive) { Task { await s.pulisci() } }
        } message: {
            Text(s.selezionate.map(\.dettaglio).joined(separator: "\n") + "\n\nL'eliminazione è definitiva, non passa dal Cestino.")
        }
    }

    func riga(_ v: Voce) -> some View {
        Toggle(isOn: Binding(get: { s.scelte.contains(v.id) },
                             set: { if $0 { s.scelte.insert(v.id) } else { s.scelte.remove(v.id) } })) {
            HStack {
                VStack(alignment: .leading) {
                    Text(v.titolo)
                    Text(v.dettaglio).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let b = v.bloccata { Text(b).font(.caption).foregroundStyle(.orange) }
                Text(Sistema.formato(v.byte)).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .disabled(v.bloccata != nil)
    }
}

// MARK: - Spazio

@MainActor
final class StatoSpazio: ObservableObject {
    @Published var percorso: [String] = []
    @Published var voci: [(percorso: String, byte: Int64)] = []
    @Published var carico = false
}

struct SpazioView: View {
    let radice: String
    @StateObject private var s = StatoSpazio()

    var corrente: String { s.percorso.last ?? radice }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button { s.percorso.removeLast() } label: { Image(systemName: "chevron.left") }.disabled(s.percorso.isEmpty)
                Text(corrente.replacingOccurrences(of: Sistema.home, with: "~")).font(.headline).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Mostra nel Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: corrente) }
            }
            .padding(14)
            Divider()
            if s.carico {
                ProgressView("Calcolo le dimensioni… può richiedere un minuto").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let massimo = Double(s.voci.first?.byte ?? 1)
                List(s.voci, id: \.percorso) { v in
                    Button { if Sistema.esiste(v.percorso) { s.percorso.append(v.percorso) } } label: {
                        HStack {
                            Text((v.percorso as NSString).lastPathComponent).frame(width: 260, alignment: .leading).lineLimit(1)
                            GeometryReader { g in
                                Capsule().fill(Color.accentColor.opacity(0.6)).frame(width: max(2, g.size.width * Double(v.byte) / massimo))
                            }
                            .frame(height: 8)
                            Text(Sistema.formato(v.byte)).monospacedDigit().frame(width: 80, alignment: .trailing)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu { Button("Mostra nel Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: v.percorso)]) } }
                }
            }
            Text("Sola lettura. Le dimensioni non dicono che una cartella sia eliminabile: chat, database e macchine virtuali vivono in Application Support.")
                .font(.caption).foregroundStyle(.secondary).padding(14)
        }
        .task(id: corrente) {
            s.carico = true
            let p = corrente
            s.voci = await Task.detached { Sistema.contenuto(p) }.value
            s.carico = false
        }
    }
}

// MARK: - Avanzamento

struct Avanzamento: View {
    @ObservedObject var s: StatoPulizia

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Anello(valore: s.progresso, colore: s.finito ? .abrasivo : .accentColor)
                    .animation(.easeInOut(duration: 0.4), value: s.progresso)
                VStack(spacing: 2) {
                    if s.finito {
                        Image(systemName: "checkmark").font(.largeTitle.bold()).foregroundStyle(Color.abrasivo)
                            .transition(.scale.combined(with: .opacity))
                    } else {
                        Text("\(Int(s.progresso * 100))%").font(.title.bold()).monospacedDigit()
                    }
                    Text(Sistema.formato(s.liberati)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .frame(width: 140, height: 140)
            .animation(.spring, value: s.finito)

            Text(s.finito ? "Pulizia completata" : "Pulizia in corso…").font(.headline)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(s.coda) { v in
                            HStack(spacing: 10) {
                                icona(s.fasi[v.id] ?? .attesa).frame(width: 18)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(v.titolo).lineLimit(1)
                                    if let n = nota(s.fasi[v.id] ?? .attesa) {
                                        Text(n).font(.caption).foregroundStyle(.orange)
                                    }
                                }
                                Spacer()
                                Text(Sistema.formato(v.byte)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            }
                            .id(v.id)
                            .opacity(s.fasi[v.id] == .attesa ? 0.45 : 1)
                            .animation(.easeOut(duration: 0.25), value: s.fasi[v.id])
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .onChange(of: s.fasi) { _, fasi in
                    if let attiva = s.coda.first(where: { if case .inCorso = fasi[$0.id] { true } else { false } }) {
                        withAnimation { proxy.scrollTo(attiva.id, anchor: .center) }
                    }
                }
            }
            .frame(height: 220)

            Button(s.finito ? "Fatto" : "In corso…") { s.chiudiAvanzamento() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!s.finito)
        }
        .padding(26)
        .frame(width: 460)
        .interactiveDismissDisabled(!s.finito)
    }

    @ViewBuilder func icona(_ f: StatoPulizia.Fase) -> some View {
        switch f {
        case .attesa: Image(systemName: "circle").foregroundStyle(.tertiary)
        case .inCorso: ProgressView().controlSize(.small)
        case .fatta: Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.abrasivo)
        case .parziale: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        case .saltata: Image(systemName: "minus.circle.fill").foregroundStyle(.orange)
        }
    }

    func nota(_ f: StatoPulizia.Fase) -> String? {
        switch f {
        case .parziale(let n): "\(n) elementi in uso o protetti, lasciati al loro posto"
        case .saltata(let m): m
        default: nil
        }
    }
}
