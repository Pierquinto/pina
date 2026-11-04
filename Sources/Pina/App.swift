import SwiftUI
import AppKit

@main
struct PinaApp: App {
    init() { NSApplication.shared.setActivationPolicy(.regular) }
    var body: some Scene {
        WindowGroup("Pina") { Radice().frame(minWidth: 860, minHeight: 560).tint(Color.pina) }
            .windowStyle(.hiddenTitleBar)
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
final class StatoRadice: ObservableObject { @Published var sezione: Sezione? = .panoramica }

struct Radice: View {
    @StateObject private var s = StatoRadice()
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
            .navigationSplitViewColumnWidth(200)
        } detail: {
            switch s.sezione ?? .panoramica {
            case .panoramica: Panoramica()
            case .pulizia: PuliziaView()
            case .memoria: MemoriaView()
            case .app: DisinstallaView()
            case .spazio: SpazioView(radice: Sistema.home)
            }
        }
    }
}

// MARK: - Panoramica

@MainActor
final class StatoPanoramica: ObservableObject {
    @Published var disco = Sistema.disco()
    @Published var pressione = Sistema.pressioneRAM()
    @Published var swap = Sistema.swapUsato()
    @Published var app: [(nome: String, byte: Int64)] = []

    func aggiorna() {
        disco = Sistema.disco(); pressione = Sistema.pressioneRAM(); swap = Sistema.swapUsato()
        Task.detached { let a = Sistema.appPesanti(); await MainActor.run { self.app = a } }
    }
}

struct Panoramica: View {
    @StateObject private var s = StatoPanoramica()
    var disco: Sistema.Disco { s.disco }
    var pressione: Int { s.pressione }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 32) {
                    Anello(valore: 1 - Double(disco.libero) / Double(max(disco.totale, 1)), colore: coloreDisco)
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
                    Scheda(titolo: "Pressione RAM", valore: testoPressione, colore: colorePressione)
                    Scheda(titolo: "Swap", valore: Sistema.formato(s.swap), colore: .secondary)
                    Scheda(titolo: "Acceso da", valore: "\(Sistema.giorniAcceso()) giorni", colore: .secondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("App che occupano più memoria").font(.headline)
                    ForEach(s.app, id: \.nome) { a in
                        HStack { Text(a.nome); Spacer(); Text(Sistema.formato(a.byte)).monospacedDigit().foregroundStyle(.secondary) }
                        Divider()
                    }
                }
            }
            .padding(28)
        }
        .toolbar { Button { s.aggiorna() } label: { Label("Aggiorna", systemImage: "arrow.clockwise") } }
        .task { s.aggiorna() }
    }

    var coloreDisco: Color { disco.libero < 5 << 30 ? .red : disco.libero < 40 << 30 ? .orange : .abrasivo }
    var testoPressione: String { [1: "normale", 2: "elevata", 4: "critica"][pressione] ?? "n/d" }
    var colorePressione: Color { [1: Color.abrasivo, 2: .orange, 4: .red][pressione] ?? .secondary }
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
