import Foundation

/// Una cosa eliminabile: una cartella rigenerabile oppure un comando di pulizia.
struct Voce: Identifiable, Hashable {
    enum Tipo: Hashable { case cartella(String), comando(String, [String]) }
    let id: String
    let titolo: String
    let dettaglio: String
    let tipo: Tipo
    var byte: Int64 = 0
    var bloccata: String? = nil   // motivo per cui ora non si può pulire
}

struct Categoria: Identifiable {
    let id: String
    let titolo: String
    let simbolo: String
    let nota: String
    var voci: [Voce]
}

enum Catalogo {
    static let h = Sistema.home
    // Cartelle in cui si cercano le build: le più comuni, più i worktree degli agenti di codice.
    static let radiciProgetti = ["Development", "Developer", "Projects", "Code", "Sites", "src", "GitHub", ".codex/worktrees", ".cursor/worktrees"].map { "\(h)/\($0)" }

    static func cacheSviluppo() -> [Voce] {
        let elenco: [(String, String)] = [
            ("npm", ".npm/_cacache"), ("npx", ".npm/_npx"), ("Bun", ".bun/install/cache"),
            ("pnpm", "Library/Caches/pnpm"), ("pip", "Library/Caches/pip"), ("pip", ".cache/pip"),
            ("uv", ".cache/uv"), ("Yarn", "Library/Caches/Yarn"), ("Composer", "Library/Caches/composer"),
            ("Xcode DerivedData", "Library/Developer/Xcode/DerivedData"),
            ("Playwright", "Library/Caches/ms-playwright"), ("node-gyp", "Library/Caches/node-gyp"),
        ]
        var voci = elenco.map { nome, rel in
            Voce(id: rel, titolo: nome, dettaglio: "~/\(rel)", tipo: .cartella("\(h)/\(rel)"))
        }
        if FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/brew") {
            voci.append(Voce(id: "brew", titolo: "Homebrew", dettaglio: "brew cleanup: download e versioni vecchie",
                             tipo: .comando("/opt/homebrew/bin/brew", ["cleanup", "-s", "--prune=all"])))
        }
        return voci
    }

    /// Solo cache vere delle app: chat, sessioni e database restano fuori.
    static func cacheApp() -> [Voce] {
        let app: [(nome: String, processi: [String], percorsi: [String])] = [
            ("Cursor", ["Cursor"], ["Library/Application Support/Cursor/Cache", "Library/Application Support/Cursor/Code Cache",
                                    "Library/Application Support/Cursor/GPUCache", "Library/Caches/com.todesktop.230313mzl4w4u92.ShipIt"]),
            ("Claude", ["Claude"], ["Library/Application Support/Claude/Cache", "Library/Application Support/Claude/Code Cache",
                                    "Library/Application Support/Claude/GPUCache"]),
            ("Codex", ["Codex", "ChatGPT"], ["Library/Application Support/Codex/Cache", "Library/Application Support/Codex/Code Cache",
                                             "Library/Application Support/Codex/GPUCache", "Library/Caches/com.openai.codex", "Library/Caches/Codex"]),
            ("Spotify", ["Spotify"], ["Library/Caches/com.spotify.client"]),
            ("Chrome", ["Google Chrome"], ["Library/Caches/Google"]),
        ]
        return app.flatMap { a in
            let aperta = Sistema.appAperta(a.processi)
            return a.percorsi.map { rel in
                Voce(id: rel, titolo: "\(a.nome): \((rel as NSString).lastPathComponent)", dettaglio: "~/\(rel)",
                     tipo: .cartella("\(h)/\(rel)"), bloccata: aperta ? "chiudi \(a.nome)" : nil)
            }
        }
    }

    static func buildProgetti() -> [Voce] {
        let nomi: Set = [".next", ".turbo", ".parcel-cache", ".nuxt", ".svelte-kit", ".astro"]
        let radici = radiciProgetti.filter { Sistema.esiste($0) && Sistema.percorsoReale($0) }
        return Sistema.cercaCartelle(in: radici, nomi: nomi, saltare: [".git", "node_modules", ".venv", "venv"])
            // Un nome di cartella con un "a capo" o un ".." non deve diventare una voce.
            .filter { p in Sistema.percorsoSemplice(p) && radici.contains { p.hasPrefix($0 + "/") } }
            .map { p in
                let progetto = (p as NSString).deletingLastPathComponent.replacingOccurrences(of: h, with: "~")
                return Voce(id: p, titolo: progetto, dettaglio: (p as NSString).lastPathComponent, tipo: .cartella(p))
            }
    }

    static func tutte() -> [Categoria] {
        [
            Categoria(id: "dev", titolo: "Cache di sviluppo", simbolo: "hammer",
                      nota: "Si riscaricano da sole al prossimo install.", voci: cacheSviluppo()),
            Categoria(id: "app", titolo: "Cache delle app", simbolo: "app.badge",
                      nota: "Solo ad app chiusa. Chat, sessioni e database non vengono toccati.", voci: cacheApp()),
            Categoria(id: "build", titolo: "Build dei progetti", simbolo: "shippingbox",
                      nota: "Cartelle generate da Next, Astro, Nuxt e simili: si ricreano alla prossima build.", voci: buildProgetti()),
        ]
    }

    /// Il catalogo con le dimensioni, senza le voci vuote o non più valide.
    /// Tutte le cartelle si misurano insieme, così il lavoro si divide tra i core.
    static func misurate() -> [Categoria] {
        let categorie = tutte()
        var percorsi: [String: String] = [:]   // id della voce → cartella da misurare
        for v in categorie.flatMap(\.voci) {
            switch v.tipo {
            case .cartella(let p): if Sistema.esiste(p), Sistema.percorsoReale(p) { percorsi[v.id] = p }
            case .comando: percorsi[v.id] = h + "/Library/Caches/Homebrew"
            }
        }
        let ordine = Array(percorsi)
        let byte = Dictionary(uniqueKeysWithValues: zip(ordine.map(\.key), Sistema.dimensioni(ordine.map(\.value))))
        return categorie.map { c in
            var c = c
            c.voci = c.voci.compactMap { v in
                guard let b = byte[v.id], b > 0 else { return nil }
                var v = v
                v.byte = b
                return v
            }.sorted { $0.byte > $1.byte }
            return c
        }.filter { !$0.voci.isEmpty }
    }

    /// Elimina una voce un elemento alla volta, dopo aver ricontrollato che sia ancora sicuro farlo.
    /// removeItem sull'intera cartella si ferma al primo file bloccato e lascia il resto:
    /// qui si salta il file in uso e si continua. `avanzamento` riceve una frazione tra 0 e 1.
    /// Restituisce quanti elementi non è stato possibile eliminare, o un motivo se la voce è saltata.
    static func pulisci(_ v: Voce, avanzamento: (Double) -> Void) -> (falliti: Int, motivo: String?) {
        switch v.tipo {
        case .cartella(let p):
            guard Sistema.esiste(p), Sistema.percorsoSemplice(p), Sistema.percorsoReale(p) else { return (0, "saltata: percorso cambiato o collegamento") }
            let fm = FileManager.default
            let figli = (try? fm.contentsOfDirectory(atPath: p)) ?? []
            var falliti = 0
            for (i, nome) in figli.enumerated() {
                let figlio = (p as NSString).appendingPathComponent(nome)
                if (try? fm.removeItem(atPath: figlio)) == nil, fm.fileExists(atPath: figlio) { falliti += 1 }
                avanzamento(Double(i + 1) / Double(max(figli.count, 1)))
            }
            if falliti == 0 { try? fm.removeItem(atPath: p) }
            return (falliti, nil)
        case .comando(let c, let a):
            avanzamento(0.5)
            let ok = Sistema.esegui(c, a).codice == 0
            avanzamento(1)
            return (0, ok ? nil : "comando terminato con errore")
        }
    }
}
