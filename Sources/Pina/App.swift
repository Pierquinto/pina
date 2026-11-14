import SwiftUI
import AppKit

@main
struct PinaApp: App {
    static let finestra = "principale"

    // Lo stato vive qui e non nelle schermate: cambiare sezione non rifà le analisi,
    // e la barra dei menu vede gli stessi dati della finestra.
    @StateObject private var radice = StatoRadice()
    @StateObject private var monitor = Monitor()
    @StateObject private var pulizia = StatoPulizia()
    @StateObject private var disinstalla = StatoDisinstalla()
    @StateObject private var spazio = StatoSpazio()
    @StateObject private var aggiornamenti = Aggiornamenti()

    init() { NSApplication.shared.setActivationPolicy(.regular) }

    var body: some Scene {
        WindowGroup("Pina", id: Self.finestra) {
            Radice(s: radice, monitor: monitor, pulizia: pulizia, disinstalla: disinstalla, spazio: spazio, aggiornamenti: aggiornamenti)
                .frame(minWidth: 860, minHeight: 560).tint(Color.pina)
        }
        .windowStyle(.hiddenTitleBar)
        // Una finestra sola: senza "Nuova finestra" non se ne aprono di doppie.
        .commands { CommandGroup(replacing: .newItem) {} }

        MenuBarExtra {
            PannelloMenu(m: monitor, p: pulizia, radice: radice, aggiornamenti: aggiornamenti)
        } label: {
            EtichettaMenu(spia: monitor.spia)
        }
        .menuBarExtraStyle(.window)
    }
}

enum Sezione: String, CaseIterable, Identifiable {
    case panoramica = "Panoramica", pulizia = "Pulizia", memoria = "Memoria", app = "Disinstalla", spazio = "Spazio"
    var id: String { rawValue }
    var simbolo: String {
        switch self {
        case .panoramica: "gauge.with.dots.needle.67percent"; case .pulizia: "sparkles"
        case .memoria: "memorychip"; case .app: "trash.square"; case .spazio: "chart.pie"
        }
    }
}

// La toolchain senza Xcode non ha il plugin delle macro SwiftUI (@State):
// lo stato delle viste vive in ObservableObject.
final class StatoRadice: ObservableObject {
    @Published var sezione: Sezione? = .panoramica
    /// La finestra principale, per riportarla davanti dalla barra dei menu.
    weak var finestra: NSWindow?
}

struct Radice: View {
    @ObservedObject var s: StatoRadice
    let monitor: Monitor
    let pulizia: StatoPulizia
    let disinstalla: StatoDisinstalla
    let spazio: StatoSpazio
    let aggiornamenti: Aggiornamenti

    var body: some View {
        NavigationSplitView {
            List(Sezione.allCases, selection: $s.sezione) { s in
                Label(s.rawValue, systemImage: s.simbolo).tag(s)
            }
            .safeAreaInset(edge: .top) {
                HStack(spacing: 10) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 0) {
                        (Text("pina").foregroundStyle(Color.pina) + Text(".").foregroundStyle(Color.spugna))
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                        Text("strofina via i giga inutili").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
            }
            .safeAreaInset(edge: .bottom) {
                AvvisoAggiornamento(a: aggiornamenti, inColonna: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 10)
            }
            .navigationSplitViewColumnWidth(200)
        } detail: {
            switch s.sezione ?? .panoramica {
            case .panoramica: Panoramica(m: monitor)
            case .pulizia: PuliziaView(s: pulizia)
            case .memoria: MemoriaView(m: monitor)
            case .app: DisinstallaView(s: disinstalla)
            case .spazio: SpazioView(radice: Sistema.home, s: spazio)
            }
        }
        .background(Aggancio { s.finestra = $0; monitor.finestra = $0 })
    }
}

// MARK: - Panoramica

struct Panoramica: View {
    @ObservedObject var m: Monitor
    var disco: Sistema.Disco { m.lettura.disco }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 32) {
                    Anello(valore: 1 - Double(disco.libero) / Double(max(disco.totale, 1)), colore: m.coloreDisco)
                        .frame(width: 150, height: 150)
                        .overlay {
                            VStack {
                                Text(Sistema.formato(disco.libero)).font(.title2.bold())
                                Text("liberi").foregroundStyle(.secondary)
                            }
                        }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Disco").font(.headline)
                        Text("\(Sistema.formato(disco.totale - disco.libero)) usati su \(Sistema.formato(disco.totale))")
                        if disco.libero < 5 << 30 {
                            Label("Spazio critico: il Mac rallenta e lo swap non ha dove scrivere.", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                        } else if disco.libero < 40 << 30 {
                            Label("Sotto la soglia di 40 GB.", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                        }
                    }
                }
                HStack(spacing: 16) {
                    Scheda(titolo: "Pressione RAM", valore: m.testoPressione, colore: m.colorePressione)
                    Scheda(titolo: "RAM in uso", valore: "\(m.percentualeRAM)%", colore: .secondary)
                    Scheda(titolo: "Swap", valore: Sistema.formatoRAM(m.lettura.swap), colore: .secondary)
                    Scheda(titolo: "Acceso da", valore: "\(Sistema.giorniAcceso()) giorni", colore: .secondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("App che occupano più memoria").font(.headline)
                    ForEach(m.pesanti) { a in
                        HStack { Text(a.nome); Spacer(); Text(Sistema.formatoRAM(a.byte)).monospacedDigit().foregroundStyle(.secondary) }
                        Divider()
                    }
                }
            }
            .padding(28)
        }
        .toolbar { Button { m.aggiorna() } label: { Label("Aggiorna", systemImage: "arrow.clockwise") } }
        .task { m.aggiorna() }
    }
}

struct Anello: View {
    let valore: Double
    let colore: Color
    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 14)
            Circle().trim(from: 0, to: valore).stroke(colore, style: .init(lineWidth: 14, lineCap: .round)).rotationEffect(.degrees(-90))
        }
    }
}

struct Scheda: View {
    let titolo: String, valore: String, colore: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(titolo).font(.caption).foregroundStyle(.secondary)
            Text(valore).font(.title3.bold()).foregroundStyle(colore)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}


extension Color {
    // Palette della direzione "Spugna".
    static let pina = Color(red: 0.357, green: 0.247, blue: 0.769)    // lavanda #5B3FC4
    static let spugna = Color(red: 1, green: 0.784, blue: 0.239)      // giallo #FFC83D
    static let abrasivo = Color(red: 0.247, green: 0.725, blue: 0.541) // verde #3FB98A
}
