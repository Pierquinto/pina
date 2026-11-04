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

    struct Disco { var libero: Int64; var totale: Int64 }

    static func disco() -> Disco {
        let url = URL(fileURLWithPath: "/System/Volumes/Data")
        let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeTotalCapacityKey])
        return Disco(libero: Int64(v?.volumeAvailableCapacity ?? 0), totale: Int64(v?.volumeTotalCapacity ?? 0))
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

    static func giorniAcceso() -> Int {
        Int(ProcessInfo.processInfo.systemUptime / 86_400)
    }

    /// Memoria per app, con gli helper accorpati, come nello script `mac`.
    static func appPesanti() -> [(nome: String, byte: Int64)] {
        let out = esegui("/bin/ps", ["-A", "-o", "rss=,comm="]).uscita
        var totali: [String: Int64] = [:]
        for riga in out.split(separator: "\n") {
            let parti = riga.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
            guard parti.count == 2, let kb = Int64(parti[0]) else { continue }
            var nome = String(parti[1])
            if let r = nome.range(of: ".app/") { nome = String(nome[..<r.lowerBound]) }
            nome = (nome as NSString).lastPathComponent
            if let r = nome.range(of: " Helper") { nome = String(nome[..<r.lowerBound]) }
            totali[nome, default: 0] += kb * 1024
        }
        return totali.filter { $0.value > 150 << 20 }
            .sorted { $0.value > $1.value }
            .prefix(8)
            .map { ($0.key, $0.value) }
    }

    /// Dimensione su disco, senza seguire symlink né attraversare volumi.
    static func dimensione(_ percorso: String) -> Int64 {
        let out = esegui("/usr/bin/du", ["-sxk", percorso]).uscita
        return (Int64(out.split(separator: "\t").first ?? "") ?? 0) * 1024
    }

    /// Sottocartelle dirette con la loro dimensione, dalla più grande.
    static func contenuto(_ percorso: String) -> [(percorso: String, byte: Int64)] {
        let out = esegui("/usr/bin/du", ["-xk", "-d", "1", percorso]).uscita
        return out.split(separator: "\n").compactMap { riga in
            let parti = riga.split(separator: "\t", maxSplits: 1)
            guard parti.count == 2, let kb = Int64(parti[0]) else { return nil }
            let p = String(parti[1])
            return p == percorso ? nil : (p, kb * 1024)
        }.sorted { $0.byte > $1.byte }
    }

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
}
