import Foundation
import Zupersign
import ZIPFoundation
#if canImport(OpenSSL)
import OpenSSL
#endif

struct ProfileData {
    let name: String
    let expires: Date
    let entitlements: [String: Any]
    let certs: [Data]
}

enum Signer {

    // MARK: Профиль

    static func readProfile(_ url: URL) throws -> ProfileData {
        guard let data = try? Data(contentsOf: url),
              let s = String(data: data, encoding: .isoLatin1),
              let a = s.range(of: "<?xml"),
              let b = s.range(of: "</plist>"),
              let d = String(s[a.lowerBound..<b.upperBound]).data(using: .isoLatin1),
              let obj = try? PropertyListSerialization.propertyList(from: d, options: [], format: nil) as? [String: Any]
        else { throw AppError(message: "Не удалось прочитать .mobileprovision") }

        let name = obj["Name"] as? String ?? "Профиль"
        let exp = obj["ExpirationDate"] as? Date ?? Date.distantPast
        let ents = obj["Entitlements"] as? [String: Any] ?? [:]
        let certs = obj["DeveloperCertificates"] as? [Data] ?? []
        return ProfileData(name: name, expires: exp, entitlements: ents, certs: certs)
    }

    // MARK: Ключ и сертификат из .p12

    static func extractIdentity(p12 data: Data, password: String) throws -> (certDER: Data, keyPEM: Data) {
        #if canImport(OpenSSL)
        var failure: String?
        var certOut = Data()
        var keyOut = Data()

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                failure = "Файл .p12 пустой"
                return
            }
            var ptr: UnsafePointer<UInt8>? = base
            guard let p12 = d2i_PKCS12(nil, &ptr, data.count) else {
                failure = "Файл не похож на .p12"
                return
            }
            defer { PKCS12_free(p12) }

            var pkey: OpaquePointer?
            var cert: OpaquePointer?
            if PKCS12_parse(p12, password, &pkey, &cert, nil) != 1 || pkey == nil || cert == nil {
                failure = "Не удалось открыть .p12: неверный пароль или неподдерживаемый формат"
                return
            }
            defer {
                if let c = cert { X509_free(c) }
                if let k = pkey { EVP_PKEY_free(k) }
            }

            // Сертификат в формате DER
            let len = i2d_X509(cert, nil)
            if len <= 0 {
                failure = "Не удалось прочитать сертификат"
                return
            }
            var der = [UInt8](repeating: 0, count: Int(len))
            der.withUnsafeMutableBufferPointer { bp in
                var p: UnsafeMutablePointer<UInt8>? = bp.baseAddress
                _ = i2d_X509(cert, &p)
            }
            certOut = Data(der)

            // Ключ в формате PEM
            guard let bio = BIO_new(BIO_s_mem()) else {
                failure = "Ошибка OpenSSL (BIO)"
                return
            }
            defer { BIO_free(bio) }
            if PEM_write_bio_PrivateKey(bio, pkey, nil, nil, 0, nil, nil) != 1 {
                failure = "Не удалось прочитать закрытый ключ"
                return
            }
            var buf = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = BIO_read(bio, &buf, 4096)
                if n <= 0 { break }
                keyOut.append(contentsOf: buf[0..<Int(n)])
            }
        }

        if let failure { throw AppError(message: failure) }
        return (certOut, keyOut)
        #else
        throw AppError(message: "OpenSSL не подключён в сборке")
        #endif
    }

    // MARK: Подпись

    static func sign(ipa: URL,
                     p12: URL,
                     password: String,
                     profile: URL,
                     outURL: URL,
                     report: @escaping (String, Double) -> Void) throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("opsign_" + UUID().uuidString)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        report("Чтение сертификата…", 0.05)
        let p12Data = try Data(contentsOf: p12)
        let identity = try extractIdentity(p12: p12Data, password: password)

        report("Проверка профиля…", 0.12)
        let prof = try readProfile(profile)
        if prof.expires < Date() {
            throw AppError(message: "Профиль «\(prof.name)» истёк. Нужен новый .mobileprovision.")
        }
        if !prof.certs.isEmpty && !prof.certs.contains(identity.certDER) {
            throw AppError(message: "Этот .p12 не входит в выбранный профиль. Нужна пара из одного аккаунта.")
        }

        report("Распаковка IPA…", 0.2)
        try fm.unzipItem(at: ipa, to: work)
        let payload = work.appendingPathComponent("Payload")
        guard let appName = (try? fm.contentsOfDirectory(atPath: payload.path))?.first(where: { $0.hasSuffix(".app") }) else {
            throw AppError(message: "В IPA не найдена папка Payload/*.app")
        }
        let appURL = payload.appendingPathComponent(appName)

        guard let info = NSDictionary(contentsOf: appURL.appendingPathComponent("Info.plist")),
              let bundleID = info["CFBundleIdentifier"] as? String else {
            throw AppError(message: "Не удалось прочитать Info.plist приложения")
        }

        report("Подготовка прав…", 0.35)
        var ents = prof.entitlements
        if let appid = ents["application-identifier"] as? String,
           let dot = appid.firstIndex(of: ".") {
            let team = String(appid[..<dot])
            let pattern = String(appid[appid.index(after: dot)...])
            let matches: Bool
            if pattern == "*" {
                matches = true
            } else if pattern.hasSuffix("*") {
                matches = bundleID.hasPrefix(String(pattern.dropLast()))
            } else {
                matches = pattern == bundleID
            }
            if !matches {
                throw AppError(message: "Профиль выдан для «\(pattern)», а у приложения bundle ID «\(bundleID)». Нужен подходящий профиль.")
            }
            ents["application-identifier"] = "\(team).\(bundleID)"
            if let groups = ents["keychain-access-groups"] as? [String] {
                ents["keychain-access-groups"] = groups.map { $0.hasSuffix("*") ? "\(team).\(bundleID)" : $0 }
            }
        }
        let entData = try PropertyListSerialization.data(fromPropertyList: ents, format: .xml, options: 0)

        // Профиль внутрь приложения
        let embedded = appURL.appendingPathComponent("embedded.mobileprovision")
        if fm.fileExists(atPath: embedded.path) { try fm.removeItem(at: embedded) }
        try fm.copyItem(at: profile, to: embedded)

        report("Подписываю приложение…", 0.5)
        fm.changeCurrentDirectoryPath(work.path)

        var exception: UnsafeMutablePointer<CChar>? = nil
        var rc: Int32 = -1

        identity.certDER.withUnsafeBytes { certBuf in
            identity.keyPEM.withUnsafeBytes { keyBuf in
                entData.withUnsafeBytes { entBuf in
                    "".withCString { rootPath in
                        let entPtr = UnsafeMutablePointer<entitlements_data_t>.allocate(capacity: 1)
                        defer { entPtr.deallocate() }
                        memset(entPtr, 0, MemoryLayout<entitlements_data_t>.stride)
                        entPtr.pointee.data = entBuf.baseAddress!
                        entPtr.pointee.len = entBuf.count
                        entPtr.pointee.bundle_path = rootPath

                        rc = zsign_sign(
                            appURL.path,
                            certBuf.baseAddress, certBuf.count,
                            keyBuf.baseAddress, keyBuf.count,
                            entPtr, 1,
                            { _, _ in },
                            nil,
                            &exception
                        )
                    }
                }
            }
        }

        if rc != 0 {
            var msg = "Ошибка подписи (код \(rc))"
            if let e = exception {
                msg = String(cString: e)
                free(e)
            }
            throw AppError(message: msg)
        }

        report("Упаковка IPA…", 0.9)
        if fm.fileExists(atPath: outURL.path) { try fm.removeItem(at: outURL) }
        try fm.zipItem(at: payload, to: outURL, shouldKeepParent: true)
        report("Готово", 1.0)
    }
}
