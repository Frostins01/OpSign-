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

struct SignedInfo {
    let bundleID: String
    let name: String
    let version: String
}

enum Signer {

    static func tr(_ lang: AppLanguage, _ ru: String, _ en: String) -> String {
        lang == .ru ? ru : en
    }

    // MARK: Профиль

    static func readProfile(_ url: URL, lang: AppLanguage) throws -> ProfileData {
        guard let data = try? Data(contentsOf: url),
              let s = String(data: data, encoding: .isoLatin1),
              let a = s.range(of: "<?xml"),
              let b = s.range(of: "</plist>"),
              let d = String(s[a.lowerBound..<b.upperBound]).data(using: .isoLatin1),
              let obj = try? PropertyListSerialization.propertyList(from: d, options: [], format: nil) as? [String: Any]
        else {
            throw AppError(message: tr(lang, "Не удалось прочитать .mobileprovision", "Could not read the .mobileprovision"))
        }

        let name = obj["Name"] as? String ?? "Profile"
        let exp = obj["ExpirationDate"] as? Date ?? Date.distantPast
        let ents = obj["Entitlements"] as? [String: Any] ?? [:]
        let certs = obj["DeveloperCertificates"] as? [Data] ?? []
        return ProfileData(name: name, expires: exp, entitlements: ents, certs: certs)
    }

    // MARK: Ключ и сертификат из .p12

    static func extractIdentity(p12 data: Data, password: String, lang: AppLanguage) throws -> (certDER: Data, keyPEM: Data) {
        #if canImport(OpenSSL)
        var failure: String?
        var certOut = Data()
        var keyOut = Data()

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                failure = tr(lang, "Файл .p12 пустой", "The .p12 file is empty")
                return
            }
            var ptr: UnsafePointer<UInt8>? = base
            guard let p12 = d2i_PKCS12(nil, &ptr, data.count) else {
                failure = tr(lang, "Файл не похож на .p12", "This does not look like a .p12 file")
                return
            }
            defer { PKCS12_free(p12) }

            var pkey: OpaquePointer?
            var cert: OpaquePointer?
            if PKCS12_parse(p12, password, &pkey, &cert, nil) != 1 || pkey == nil || cert == nil {
                failure = tr(lang,
                             "Не удалось открыть .p12: неверный пароль или неподдерживаемый формат",
                             "Could not open the .p12: wrong password or unsupported format")
                return
            }
            defer {
                if let c = cert { X509_free(c) }
                if let k = pkey { EVP_PKEY_free(k) }
            }

            // Сертификат в формате DER
            let len = i2d_X509(cert, nil)
            if len <= 0 {
                failure = tr(lang, "Не удалось прочитать сертификат", "Could not read the certificate")
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
                failure = "OpenSSL error (BIO)"
                return
            }
            defer { BIO_free(bio) }
            if PEM_write_bio_PrivateKey(bio, pkey, nil, nil, 0, nil, nil) != 1 {
                failure = tr(lang, "Не удалось прочитать закрытый ключ", "Could not read the private key")
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
        throw AppError(message: "OpenSSL is not included in this build")
        #endif
    }

    // MARK: Подпись

    static func sign(ipa: URL,
                     p12: URL,
                     password: String,
                     profile: URL,
                     outURL: URL,
                     lang: AppLanguage,
                     report: @escaping (String, Double) -> Void) throws -> SignedInfo {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("opsign_" + UUID().uuidString)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)

        let originalDir = fm.currentDirectoryPath
        defer {
            fm.changeCurrentDirectoryPath(originalDir)
            try? fm.removeItem(at: work)
        }

        report(tr(lang, "Чтение сертификата…", "Reading certificate…"), 0.05)
        let p12Data = try Data(contentsOf: p12)
        let identity = try extractIdentity(p12: p12Data, password: password, lang: lang)

        report(tr(lang, "Проверка профиля…", "Checking profile…"), 0.12)
        let prof = try readProfile(profile, lang: lang)
        if prof.expires < Date() {
            throw AppError(message: tr(lang,
                                       "Профиль «\(prof.name)» истёк. Нужен новый .mobileprovision.",
                                       "Profile “\(prof.name)” has expired. A new .mobileprovision is needed."))
        }
        if !prof.certs.isEmpty && !prof.certs.contains(identity.certDER) {
            throw AppError(message: tr(lang,
                                       "Этот .p12 не входит в выбранный профиль. Нужна пара из одного аккаунта.",
                                       "This .p12 is not part of the selected profile. Use a pair from the same account."))
        }

        report(tr(lang, "Распаковка IPA…", "Unpacking IPA…"), 0.2)
        try fm.unzipItem(at: ipa, to: work)
        let payload = work.appendingPathComponent("Payload")
        guard let appName = (try? fm.contentsOfDirectory(atPath: payload.path))?.first(where: { $0.hasSuffix(".app") }) else {
            throw AppError(message: tr(lang, "В IPA не найдена папка Payload/*.app", "Payload/*.app was not found in the IPA"))
        }
        let appURL = payload.appendingPathComponent(appName)
        let infoURL = appURL.appendingPathComponent("Info.plist")

        guard let info = NSMutableDictionary(contentsOf: infoURL),
              let bundleID = info["CFBundleIdentifier"] as? String else {
            throw AppError(message: tr(lang, "Не удалось прочитать Info.plist приложения", "Could not read the app's Info.plist"))
        }

        report(tr(lang, "Подготовка прав…", "Preparing entitlements…"), 0.3)
        var ents = prof.entitlements
        var finalBundleID = bundleID

        if let appid = ents["application-identifier"] as? String,
           let dot = appid.firstIndex(of: ".") {
            let team = String(appid[..<dot])
            let pattern = String(appid[appid.index(after: dot)...])

            if pattern == "*" {
                finalBundleID = bundleID
            } else if pattern.hasSuffix("*") {
                let prefix = String(pattern.dropLast())
                if !bundleID.hasPrefix(prefix) { finalBundleID = prefix + bundleID }
            } else {
                finalBundleID = pattern
            }

            ents["application-identifier"] = "\(team).\(finalBundleID)"
            if let groups = ents["keychain-access-groups"] as? [String] {
                ents["keychain-access-groups"] = groups.map { $0.hasSuffix("*") ? "\(team).\(finalBundleID)" : $0 }
            }
        }

        // Меняем Bundle ID приложения под профиль
        if finalBundleID != bundleID {
            report(tr(lang, "Меняю Bundle ID…", "Changing Bundle ID…"), 0.38)
            info["CFBundleIdentifier"] = finalBundleID
            try info.write(to: infoURL)
        }

        // Данные приложения для установки
        let displayName = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? appName.replacingOccurrences(of: ".app", with: "")
        let appVersion = (info["CFBundleShortVersionString"] as? String)
            ?? (info["CFBundleVersion"] as? String)
            ?? "1.0"

        // Расширения и часы подписать одним профилем нельзя, убираем их
        for folder in ["PlugIns", "Watch"] {
            let path = appURL.appendingPathComponent(folder)
            if fm.fileExists(atPath: path.path) { try? fm.removeItem(at: path) }
        }

        let entData = try PropertyListSerialization.data(fromPropertyList: ents, format: .xml, options: 0)

        // Профиль внутрь приложения
        let embedded = appURL.appendingPathComponent("embedded.mobileprovision")
        if fm.fileExists(atPath: embedded.path) { try fm.removeItem(at: embedded) }
        try fm.copyItem(at: profile, to: embedded)

        report(tr(lang, "Подписываю приложение…", "Signing the app…"), 0.5)
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
                            certBuf.baseAddress!, certBuf.count,
                            keyBuf.baseAddress!, keyBuf.count,
                            entPtr, 1,
                            { _, _ in },
                            UnsafeRawPointer(entPtr),
                            &exception
                        )
                    }
                }
            }
        }

        if rc != 0 {
            var msg = tr(lang, "Ошибка подписи (код \(rc))", "Signing error (code \(rc))")
            if let e = exception {
                msg = String(cString: e)
                free(e)
            }
            throw AppError(message: msg)
        }

        report(tr(lang, "Упаковка IPA…", "Packing IPA…"), 0.9)
        if fm.fileExists(atPath: outURL.path) { try fm.removeItem(at: outURL) }
        try fm.zipItem(at: payload, to: outURL, shouldKeepParent: true)
        report(tr(lang, "Готово", "Done"), 1.0)

        return SignedInfo(bundleID: finalBundleID, name: displayName, version: appVersion)
    }
}
