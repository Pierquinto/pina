import SwiftUI
import AppKit

/// Controlla una volta al giorno se su GitHub c'è una versione più nuova e, se c'è, lo dice.
/// È l'unica chiamata di rete dell'app: non manda dati, non scarica e non installa niente.
/// Si spegne con: defaults write app.pina.mac ControlloAggiornamenti -bool NO
@MainActor
final class Aggiornamenti: ObservableObject {
    /// La pagina da cui scaricare. È fissa: dalla risposta si legge solo il numero di versione.
    static let pagina = URL(string: "https://github.com/Pierquinto/pina/releases/latest")!
    private static let indirizzo = URL(string: "https://api.github.com/repos/Pierquinto/pina/releases/latest")!

    @Published private(set) var nuova: String?

    private let attuale: String?
    private var timer: Timer?

    init(attuale: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) {
        self.attuale = attuale
        // Senza versione (app lanciata fuori dal bundle) o con il controllo spento, non si chiama nessuno.
        guard attuale != nil, UserDefaults.standard.object(forKey: "ControlloAggiornamenti") as? Bool != false else { return }
        let t = Timer(timeInterval: 86_400, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.controlla() }
        }
        t.tolerance = 3_600
        RunLoop.main.add(t, forMode: .common)
        timer = t
        Task { await controlla() }
    }

    func controlla() async {
        guard let attuale else { return }
        var richiesta = URLRequest(url: Self.indirizzo, timeoutInterval: 15)
        richiesta.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        richiesta.setValue("Pina", forHTTPHeaderField: "User-Agent")
        // Sessione effimera: niente cookie né cache lasciati sul disco.
        guard let (dati, risposta) = try? await URLSession(configuration: .ephemeral).data(for: richiesta),
              (risposta as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: dati) as? [String: Any],
              let etichetta = json["tag_name"] as? String else { return }
        let versione = etichetta.hasPrefix("v") ? String(etichetta.dropFirst()) : etichetta
        nuova = Self.precede(attuale, versione) ? versione : nil
    }

    /// "0.2.0" → [0, 2, 0]. Qualsiasi cosa non sia fatta di soli numeri e punti non è una versione.
    static func numeri(_ versione: String) -> [Int]? {
        let parti = versione.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        return parti.isEmpty || parti.contains { $0 == nil || $0! < 0 } ? nil : parti.map { $0! }
    }

    /// Vero se `a` è più vecchia di `b`. "0.2" e "0.2.0" sono la stessa versione.
    static func precede(_ a: String, _ b: String) -> Bool {
        guard let x = numeri(a), let y = numeri(b) else { return false }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p < q }
        }
        return false
    }
}

/// Compare solo quando c'è una versione più nuova. Apre la pagina delle release nel browser.
struct AvvisoAggiornamento: View {
    @ObservedObject var a: Aggiornamenti
    var inColonna = false

    var body: some View {
        if let versione = a.nuova {
            let testo = Label("Pina \(versione) disponibile", systemImage: "arrow.down.circle.fill")
                .foregroundStyle(Color.pina).lineLimit(1)
            let scarica = Button("Scarica") { NSWorkspace.shared.open(Aggiornamenti.pagina) }.controlSize(.small)
            if inColonna {
                VStack(alignment: .leading, spacing: 6) { testo.font(.caption); scarica }
            } else {
                HStack { testo; Spacer(); scarica }
            }
        }
    }
}
