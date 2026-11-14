import Foundation
import AppKit

/// Letture di sistema e utilità su file, tutte senza effetti collaterali.
enum Sistema {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path

    @discardableResult
    static func esegui(_ comando: String, _ argomenti: [String]) -> (codice: Int32, uscita: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: comando)
        p.arguments = argomenti
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return (-1, "") }
        let dati = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: dati, as: UTF8.self))
    }

    struct Disco: Equatable { var libero: Int64; var totale: Int64 }

    static func disco() -> Disco {
        var s = statfs()
        guard statfs("/System/Volumes/Data", &s) == 0 else { return Disco(libero: 0, totale: 0) }
        return Disco(libero: Int64(s.f_bavail) * Int64(s.f_bsize), totale: Int64(s.f_blocks) * Int64(s.f_bsize))
    }

    /// 1 normale, 2 elevata, 4 critica.
    static func pressioneRAM() -> Int {
        var livello: Int32 = 0
        var size = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &livello, &size, nil, 0)
        return Int(livello)
    }

    static func swapUsato() -> Int64 {
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &size, nil, 0)
        return Int64(swap.xsu_used)
    }

    static let ramTotale = Int64(ProcessInfo.processInfo.physicalMemory)

    /// Memoria usata come la conta Monitoraggio Attività: app, wired e compressa.
    /// La cache dei file e la memoria purgabile restano fuori, perché macOS le cede appena servono.
    static func ramUsata() -> Int64 {
        var stat = vm_statistics64()
        var n = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let esito = withUnsafeMutablePointer(to: &stat) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &n) }
        }
        guard esito == KERN_SUCCESS else { return 0 }
        let pagine = Int64(stat.internal_page_count) - Int64(stat.purgeable_count)
            + Int64(stat.wire_count) + Int64(stat.compressor_page_count)
        return max(0, pagine) * Int64(sysconf(_SC_PAGESIZE))
    }

    static func giorniAcceso() -> Int {
        Int(ProcessInfo.processInfo.systemUptime / 86_400)
    }

    struct Peso: Identifiable {
        let nome: String, percorso: String?, byte: Int64
        var id: String { percorso ?? nome }
    }

    /// Memoria per app, dalla più pesante, con gli helper accorpati all'app che li contiene.
    /// Legge il "phys footprint" dei processi dell'utente (lo stesso numero di Monitoraggio
    /// Attività) direttamente dal kernel, senza lanciare `ps`.
    static func memoriaApp() -> [Peso] {
        var pid = [pid_t](repeating: 0, count: Int(proc_listallpids(nil, 0)) + 64)
        let scritti = proc_listallpids(&pid, Int32(pid.count * MemoryLayout<pid_t>.size))
        guard scritti > 0 else { return [] }
        var totali: [String: (nome: String, percorso: String?, byte: Int64)] = [:]
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for p in pid.prefix(Int(scritti)) where p > 0 {
            var uso = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &uso) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(p, RUSAGE_INFO_V4, $0) }
            }
            guard ok == 0, uso.ri_phys_footprint > 0, proc_pidpath(p, &buffer, UInt32(buffer.count)) > 0 else { continue }
            let eseguibile = String(cString: buffer)
            var chiave = eseguibile, percorso: String? = nil
            if let r = eseguibile.range(of: ".app/") {
                chiave = String(eseguibile[..<r.lowerBound]) + ".app"
                percorso = chiave
            }
            var nome = (chiave as NSString).lastPathComponent
            if percorso != nil { nome = (nome as NSString).deletingPathExtension }
            else if let r = nome.range(of: " Helper") { nome = String(nome[..<r.lowerBound]); chiave = nome }
            totali[chiave, default: (nome, percorso, 0)].byte += Int64(uso.ri_phys_footprint)
        }
        return totali.values.map { Peso(nome: $0.nome, percorso: $0.percorso, byte: $0.byte) }.sorted { $0.byte > $1.byte }
    }

    // MARK: Dimensioni

    /// Permette di interrompere una misura lunga da un altro thread.
    final class Interruttore: @unchecked Sendable {
        private let lucchetto = NSLock()
        private var valore = false
        var spento: Bool { lucchetto.lock(); defer { lucchetto.unlock() }; return valore }
        func spegni() { lucchetto.lock(); valore = true; lucchetto.unlock() }
    }

    /// I file con più nomi (hard link) vanno contati una volta sola, anche tra thread diversi.
    private final class Inode: @unchecked Sendable {
        private let lucchetto = NSLock()
        private var visti = Set<UInt64>()
        func nuovo(_ i: UInt64) -> Bool { lucchetto.lock(); defer { lucchetto.unlock() }; return visti.insert(i).inserted }
    }

    private static func stato(_ percorso: String) -> stat? {
        var st = stat()
        return lstat(percorso, &st) == 0 ? st : nil
    }

    private static func tipo(_ st: stat) -> mode_t { st.st_mode & S_IFMT }

    /// Blocchi occupati da un albero, senza seguire symlink né attraversare volumi.
    /// FTS_NOCHDIR è obbligatorio: senza, fts cambia la cartella corrente del processo
    /// e due visite in parallelo si pesterebbero i piedi.
    private static func blocchi(_ radice: String, volume: dev_t, inode: Inode, annulla: Interruttore?) -> Int64 {
        guard let c = strdup(radice) else { return 0 }
        defer { free(c) }
        var argomenti: [UnsafeMutablePointer<CChar>?] = [c, nil]
        guard let fts = fts_open(&argomenti, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, nil) else { return 0 }
        defer { fts_close(fts) }
        var somma: Int64 = 0, giri = 0
        while let e = fts_read(fts) {
            giri += 1
            if giri & 1023 == 0, annulla?.spento == true { break }
            let info = Int32(e.pointee.fts_info)
            // Le cartelle si contano all'uscita (FTS_DP), come fa du.
            if info == FTS_D || info == FTS_NS || info == FTS_ERR || info == FTS_DC { continue }
            guard let st = e.pointee.fts_statp?.pointee, st.st_dev == volume else { continue }
            if info == FTS_F, st.st_nlink > 1, !inode.nuovo(UInt64(st.st_ino)) { continue }
            somma += Int64(st.st_blocks)
        }
        return somma * 512
    }

    /// Dimensione su disco di più percorsi insieme, usando tutti i core.
    /// Ogni cartella viene spezzata nelle sue sottocartelle, così anche una sola cartella
    /// enorme si misura in parallelo. Non segue symlink e non attraversa volumi.
    static func dimensioni(_ percorsi: [String], annulla: Interruttore? = nil) -> [Int64] {
        var totali = [Int64](repeating: 0, count: percorsi.count)
        var lavori: [(indice: Int, percorso: String, volume: dev_t)] = []
        let inode = Inode()
        let fm = FileManager.default
        for (i, p) in percorsi.enumerated() {
            guard let st = stato(p) else { continue }
            totali[i] = Int64(st.st_blocks) * 512
            guard tipo(st) == S_IFDIR else { continue }
            for nome in (try? fm.contentsOfDirectory(atPath: p)) ?? [] {
                let figlio = p + "/" + nome
                guard let sf = stato(figlio), sf.st_dev == st.st_dev else { continue }
                if tipo(sf) == S_IFDIR {
                    lavori.append((i, figlio, st.st_dev))
                } else if tipo(sf) != S_IFREG || sf.st_nlink == 1 || inode.nuovo(UInt64(sf.st_ino)) {
                    totali[i] += Int64(sf.st_blocks) * 512
                }
            }
        }
        guard !lavori.isEmpty else { return totali }
        var parziali = [Int64](repeating: 0, count: lavori.count)
        parziali.withUnsafeMutableBufferPointer { buffer in
            let base = buffer.baseAddress!
            DispatchQueue.concurrentPerform(iterations: lavori.count) { n in
                if annulla?.spento == true { return }
                base[n] = blocchi(lavori[n].percorso, volume: lavori[n].volume, inode: inode, annulla: annulla)
            }
        }
        for (n, l) in lavori.enumerated() { totali[l.indice] += parziali[n] }
        return totali
    }

    /// Cartelle e file diretti con la loro dimensione, dal più grande.
    static func contenuto(_ percorso: String, annulla: Interruttore? = nil) -> [(percorso: String, byte: Int64, cartella: Bool)] {
        guard let radice = stato(percorso) else { return [] }
        let figli = ((try? FileManager.default.contentsOfDirectory(atPath: percorso)) ?? []).compactMap { nome -> (String, Bool)? in
            let p = percorso + "/" + nome
            guard let st = stato(p), st.st_dev == radice.st_dev else { return nil }
            return (p, tipo(st) == S_IFDIR)
        }
        let byte = dimensioni(figli.map(\.0), annulla: annulla)
        return zip(figli, byte).map { ($0.0, $1, $0.1) }.filter { $0.byte > 0 }.sorted { $0.byte > $1.byte }
    }

    /// Cerca dentro `radici` le cartelle che si chiamano come uno dei `nomi`, senza entrare
    /// in quelle da `saltare` né in quelle trovate. Non segue symlink e non attraversa volumi.
    static func cercaCartelle(in radici: [String], nomi: Set<String>, saltare: Set<String>) -> [String] {
        var trovate: [String] = []
        var lavori: [String] = []
        let fm = FileManager.default
        // Il primo livello si legge qui, così ogni progetto diventa un lavoro a sé.
        for radice in radici {
            guard let sr = stato(radice), tipo(sr) == S_IFDIR else { continue }
            for nome in (try? fm.contentsOfDirectory(atPath: radice)) ?? [] where !saltare.contains(nome) {
                let p = radice + "/" + nome
                guard let st = stato(p), tipo(st) == S_IFDIR, st.st_dev == sr.st_dev else { continue }
                if nomi.contains(nome) { trovate.append(p) } else { lavori.append(p) }
            }
        }
        let lucchetto = NSLock()
        DispatchQueue.concurrentPerform(iterations: lavori.count) { n in
            guard let c = strdup(lavori[n]) else { return }
            defer { free(c) }
            var argomenti: [UnsafeMutablePointer<CChar>?] = [c, nil]
            // FTS_NOSTAT: per riconoscere le cartelle basta il tipo scritto nella directory.
            guard let fts = fts_open(&argomenti, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR | FTS_NOSTAT, nil) else { return }
            defer { fts_close(fts) }
            var locali: [String] = []
            while let e = fts_read(fts) {
                guard Int32(e.pointee.fts_info) == FTS_D, e.pointee.fts_level > 0 else { continue }
                // Il nome è la coda del percorso: si legge da lì senza allocare altro.
                let nome = String(cString: e.pointee.fts_path + Int(e.pointee.fts_pathlen) - Int(e.pointee.fts_namelen))
                if saltare.contains(nome) {
                    fts_set(fts, e, FTS_SKIP)
                } else if nomi.contains(nome) {
                    locali.append(String(cString: e.pointee.fts_path))
                    fts_set(fts, e, FTS_SKIP)
                }
            }
            if !locali.isEmpty { lucchetto.lock(); trovate += locali; lucchetto.unlock() }
        }
        return trovate.sorted()
    }

    // MARK: Percorsi

    /// Rifiuta componenti "." o ".." e caratteri di controllo (a capo compreso).
    static func percorsoSemplice(_ percorso: String) -> Bool {
        let parti = percorso.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        return !parti.contains { $0 == "." || $0 == ".." || $0.isEmpty }
            && !percorso.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    /// Rifiuta percorsi fuori dalla home o con symlink in qualsiasi componente.
    static func percorsoReale(_ percorso: String) -> Bool {
        guard percorso.hasPrefix(home + "/") else { return false }
        var corrente = percorso
        let fm = FileManager.default
        while corrente != home {
            if let attr = try? fm.attributesOfItem(atPath: corrente),
               attr[.type] as? FileAttributeType == .typeSymbolicLink { return false }
            corrente = (corrente as NSString).deletingLastPathComponent
        }
        return true
    }

    static func esiste(_ percorso: String) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: percorso, isDirectory: &dir) && dir.boolValue
    }

    static func appAperta(_ nomi: [String]) -> Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            nomi.contains { app.localizedName?.caseInsensitiveCompare($0) == .orderedSame }
        }
    }

    static func formato(_ byte: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: byte, countStyle: .file)
    }

    /// La memoria si conta in potenze di due, come fa Monitoraggio Attività: 8 GB di RAM sono "8 GB", non "8,59".
    static func formatoRAM(_ byte: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: byte, countStyle: .memory)
    }

    private static let icone = NSCache<NSString, NSImage>()

    /// Chiedere l'icona a NSWorkspace a ogni ridisegno di una riga costa: si tiene da parte.
    static func icona(_ percorso: String) -> NSImage {
        if let i = icone.object(forKey: percorso as NSString) { return i }
        let i = NSWorkspace.shared.icon(forFile: percorso)
        icone.setObject(i, forKey: percorso as NSString)
        return i
    }
}
