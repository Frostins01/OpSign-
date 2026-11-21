import SwiftUI
import UniformTypeIdentifiers
import Security
#if canImport(OpenSSL)
import OpenSSL
#endif

// MARK: - Язык

enum AppLanguage: String, CaseIterable, Identifiable {
    case ru, en
    var id: String { rawValue }
    var title: String { self == .ru ? "Русский" : "English" }
}

// MARK: - Выбор файлов

enum PickKind: Int, Identifiable {
    case ipa, p12, profile
    var id: Int { rawValue }

    var ext: String {
        switch self {
        case .ipa: return "ipa"
        case .p12: return "p12"
        case .profile: return "mobileprovision"
        }
    }

    var types: [UTType] {
        if let t = UTType(filenameExtension: ext) { return [t] }
        return [.item]
    }

    func accepts(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == ext
    }
}

struct DocumentPicker: UIViewControllerRepresentable {
    let kind: PickKind
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: kind.types, asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first {
                DispatchQueue.main.async { self.onPick(url) }
            }
        }
    }
}

// MARK: - Проверка .p12 через OpenSSL

func opensslCheck(_ data: Data, _ pass: String, _ lang: AppLanguage) -> (ok: Bool, message: String) {
    #if canImport(OpenSSL)
    var out: (ok: Bool, message: String) = (false, "Unknown error")
    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
            out = (false, Signer.tr(lang, "Файл пустой", "The file is empty"))
            return
        }
        var ptr: UnsafePointer<UInt8>? = base
        guard let p12 = d2i_PKCS12(nil, &ptr, data.count) else {
            out = (false, Signer.tr(lang,
                                    "Структура файла не похожа на .p12. Скорее всего, выбран не тот файл или он повреждён.",
                                    "The file structure does not look like a .p12. Most likely the wrong file or it is damaged."))
            return
        }
        defer { PKCS12_free(p12) }

        if PKCS12_verify_mac(p12, pass, -1) != 1 {
            out = (false, Signer.tr(lang,
                                    "Неверный пароль от .p12. Проверь пароль (нажми на глазок рядом с полем).",
                                    "Wrong .p12 password. Check it (tap the eye icon next to the field)."))
            return
        }

        var pkey: OpaquePointer?
        var cert: OpaquePointer?
        if PKCS12_parse(p12, pass, &pkey, &cert, nil) != 1 {
            out = (false, Signer.tr(lang,
                                    "Пароль верный, но файл использует устаревший алгоритм шифрования. Выпусти или пересохрани .p12 заново.",
                                    "The password is correct, but the file uses an outdated encryption algorithm. Re-export the .p12."))
            return
        }

        var name = Signer.tr(lang, "сертификат", "certificate")
        if let c = cert, let subj = X509_get_subject_name(c) {
            var buf = [CChar](repeating: 0, count: 256)
            if X509_NAME_get_text_by_NID(subj, NID_commonName, &buf, 256) > 0 {
                name = String(cString: buf)
            }
        }
        if let c = cert { X509_free(c) }
        if let k = pkey { EVP_PKEY_free(k) }
        out = (true, Signer.tr(lang, "Пароль верный: \(name)", "Password is correct: \(name)"))
    }
    return out
    #else
    return (false, "OpenSSL is not included in this build.")
    #endif
}

// MARK: - Хранилище

struct SignedItem: Codable, Identifiable {
    var id = UUID()
    var name: String
    var fileName: String
    var date: Date
    var size: Int64
    var isSigned: Bool
    var bundleID: String? = nil
    var appName: String? = nil
    var version: String? = nil
}

struct AppError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class AppStore: ObservableObject {
    // Цвет интерфейса
    @Published var bgChoice: String {
        didSet { UserDefaults.standard.set(bgChoice, forKey: "bgChoice") }
    }
    @Published var bgHex1: String {
        didSet { UserDefaults.standard.set(bgHex1, forKey: "bgHex1") }
    }
    @Published var bgHex2: String {
        didSet { UserDefaults.standard.set(bgHex2, forKey: "bgHex2") }
    }
    // Цвет кнопок
    @Published var accentHex: String {
        didSet { UserDefaults.standard.set(accentHex, forKey: "accentHex") }
    }

    @Published var lang: AppLanguage {
        didSet { UserDefaults.standard.set(lang.rawValue, forKey: "lang") }
    }
    @Published var p12Name: String? {
        didSet { UserDefaults.standard.set(p12Name, forKey: "p12Name") }
    }
    @Published var profileName: String? {
        didSet { UserDefaults.standard.set(profileName, forKey: "profileName") }
    }
    @Published var password: String {
        didSet { UserDefaults.standard.set(password, forKey: "p12Password") }
    }
    @Published var signed: [SignedItem] = [] {
        didSet { persistSigned() }
    }

    var installServer: InstallServer?

    init() {
        let d = UserDefaults.standard

        let savedChoice = d.string(forKey: "bgChoice") ?? d.string(forKey: "theme") ?? "purple"
        bgChoice = (savedChoice == "custom" || AppTheme(rawValue: savedChoice) != nil) ? savedChoice : "purple"
        bgHex1 = d.string(forKey: "bgHex1") ?? "0D0D26"
        bgHex2 = d.string(forKey: "bgHex2") ?? "2E0F59"
        accentHex = d.string(forKey: "accentHex") ?? "B359FF"

        if let saved = AppLanguage(rawValue: d.string(forKey: "lang") ?? "") {
            lang = saved
        } else {
            let sys = Locale.preferredLanguages.first ?? "en"
            lang = sys.hasPrefix("ru") ? .ru : .en
        }
        p12Name = d.string(forKey: "p12Name")
        profileName = d.string(forKey: "profileName")
        password = d.string(forKey: "p12Password") ?? ""
        if let data = d.data(forKey: "signed"),
           let items = try? JSONDecoder().decode([SignedItem].self, from: data) {
            signed = items
        }
        pruneMissing()
    }

    // Палитра приложения
    var palette: Palette {
        var colors: [Color]
        var light = false
        if bgChoice == "custom" {
            let c1 = Color(hex: bgHex1)
            let c2 = Color(hex: bgHex2)
            colors = [c1, c2]
            light = (c1.luminance + c2.luminance) / 2 > 0.6
        } else if let preset = AppTheme(rawValue: bgChoice) {
            colors = preset.colors
            light = preset.isLight
        } else {
            colors = AppTheme.purple.colors
        }
        return Palette(colors: colors, accent: Color(hex: accentHex), isLight: light)
    }

    /// Совместимость со старым кодом (OpSignApp.swift использует theme.scheme)
    var theme: Palette { palette }

    func tr(_ ru: String, _ en: String) -> String {
        lang == .ru ? ru : en
    }

    private var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }
    private var docsDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    var certsDir: URL { supportDir.appendingPathComponent("Certs") }
    var p12URL: URL { certsDir.appendingPathComponent("cert.p12") }
    var profileURL: URL { certsDir.appendingPathComponent("profile.mobileprovision") }
    var signedDir: URL { docsDir.appendingPathComponent("Signed") }

    func url(for item: SignedItem) -> URL {
        signedDir.appendingPathComponent(item.fileName)
    }

    var hasCert: Bool {
        let fm = FileManager.default
        return p12Name != nil && profileName != nil && !password.isEmpty
            && fm.fileExists(atPath: p12URL.path) && fm.fileExists(atPath: profileURL.path)
    }

    func importFile(_ url: URL, kind: PickKind) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: certsDir, withIntermediateDirectories: true)
        let dest = kind == .p12 ? p12URL : profileURL
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.copyItem(at: url, to: dest)
        if kind == .p12 { p12Name = url.lastPathComponent }
        if kind == .profile { profileName = url.lastPathComponent }
    }

    func resetCert() {
        try? FileManager.default.removeItem(at: p12URL)
        try? FileManager.default.removeItem(at: profileURL)
        p12Name = nil
        profileName = nil
        password = ""
    }

    func checkCertificate() -> (ok: Bool, message: String) {
        guard let data = try? Data(contentsOf: p12URL) else {
            return (false, tr("Файл .p12 не найден. Добавь его в Настройках.",
                              "The .p12 file was not found. Add it in Settings."))
        }
        if data.count < 200 {
            return (false, tr("Файл .p12 слишком маленький (\(data.count) байт). Скорее всего, выбран не тот файл.",
                              "The .p12 file is too small (\(data.count) bytes). Most likely the wrong file."))
        }
        let pass = password.trimmingCharacters(in: .whitespacesAndNewlines)
        if pass.isEmpty {
            return (false, tr("Введи пароль от .p12 в поле выше.", "Enter the .p12 password in the field above."))
        }

        var items: CFArray?
        let options = [kSecImportExportPassphrase as String: pass] as CFDictionary
        let status = SecPKCS12Import(data as CFData, options, &items)
        if status == errSecSuccess,
           let arr = items as? [[String: Any]],
           let first = arr.first,
           let identityAny = first[kSecImportItemIdentity as String] {
            let identity = identityAny as! SecIdentity
            var cert: SecCertificate?
            SecIdentityCopyCertificate(identity, &cert)
            let name = cert.flatMap { SecCertificateCopySubjectSummary($0) as String? } ?? tr("сертификат", "certificate")
            return (true, tr("Пароль верный: \(name)", "Password is correct: \(name)"))
        }

        return opensslCheck(data, pass, lang)
    }

    func profileInfo() -> (name: String, expires: Date)? {
        guard let p = try? Signer.readProfile(profileURL, lang: lang) else { return nil }
        return (p.name, p.expires)
    }

    func newOutput(for ipa: URL) throws -> (url: URL, name: String) {
        let fm = FileManager.default
        try fm.createDirectory(at: signedDir, withIntermediateDirectories: true)
        let base = ipa.deletingPathExtension().lastPathComponent
        let name = "\(base)_OpSign.ipa"
        let fileName = "\(UUID().uuidString.prefix(6))_\(name)"
        return (signedDir.appendingPathComponent(fileName), name)
    }

    func registerSigned(url: URL, name: String, info: SignedInfo) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let item = SignedItem(name: name, fileName: url.lastPathComponent,
                              date: Date(), size: size, isSigned: true,
                              bundleID: info.bundleID, appName: info.name, version: info.version)
        signed.insert(item, at: 0)
    }

    func delete(_ item: SignedItem) {
        try? FileManager.default.removeItem(at: url(for: item))
        signed.removeAll { $0.id == item.id }
    }

    /// Удаляет все подписанные файлы (только внутри приложения, по нажатию пользователя)
    func deleteAllSigned() {
        for item in signed {
            try? FileManager.default.removeItem(at: url(for: item))
        }
        signed.removeAll()
    }

    /// Убирает из списка записи, чьих файлов уже нет на диске
    func pruneMissing() {
        let fm = FileManager.default
        let alive = signed.filter { fm.fileExists(atPath: url(for: $0).path) }
        if alive.count != signed.count {
            signed = alive
        }
    }

    /// Удаляет временную копию IPA, которую создал выбор файла (оригинал не трогается)
    func removeTemporaryCopy(_ url: URL) {
        let fm = FileManager.default
        let p = url.path
        let inTemp = p.hasPrefix(fm.temporaryDirectory.path) || p.hasPrefix(NSTemporaryDirectory())
        if inTemp || p.contains("/Inbox/") {
            try? fm.removeItem(at: url)
        }
    }

    private func persistSigned() {
        if let data = try? JSONEncoder().encode(signed) {
            UserDefaults.standard.set(data, forKey: "signed")
        }
    }

    // MARK: Очистка кэша

    private func folderSize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        }
        var total: Int64 = 0
        if let en = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey], options: []) {
            for case let f as URL in en {
                total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            }
        }
        return total
    }

    /// Чистит ТОЛЬКО кэш приложения: временные файлы, системный кэш, копии из выбора файлов.
    /// Подписанные файлы, список, сертификат и установленные приложения не затрагиваются.
    /// Возвращает, сколько байт освобождено.
    func clearCache() -> Int64 {
        let fm = FileManager.default
        var freed: Int64 = 0

        func wipe(_ dir: URL) {
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
            for item in items {
                freed += folderSize(item)
                try? fm.removeItem(at: item)
            }
        }

        wipe(fm.temporaryDirectory)
        if let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
            wipe(caches)
        }

        let inbox = docsDir.appendingPathComponent("Inbox")
        freed += folderSize(inbox)
        try? fm.removeItem(at: inbox)

        URLCache.shared.removeAllCachedResponses()
        return freed
    }

    // MARK: Установка

    @MainActor
    func beginInstall(item: SignedItem) async throws {
        guard let bundleID = item.bundleID else {
            throw AppError(message: tr("У этого файла нет данных для установки. Подпиши приложение заново.",
                                       "This file has no install data. Sign the app again."))
        }
        let file = url(for: item)
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw AppError(message: tr("Файл не найден. Подпиши приложение заново.",
                                       "The file was not found. Sign the app again."))
        }

        installServer?.stop()
        let server = InstallServer()
        installServer = server

        let page = try await server.start(ipa: file,
                                          bundleID: bundleID,
                                          name: item.appName ?? item.name,
                                          version: item.version ?? "1.0")
        server.keepAlive()
        InstallServer.presentSafari(page)
    }
}

// MARK: - Главный экран с вкладками

struct ContentView: View {
    @EnvironmentObject var store: AppStore
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            SignView(tab: $tab)
                .tabItem { Label(store.tr("Установка", "Install"), systemImage: "arrow.down.app.fill") }
                .tag(0)
            SignedView()
                .tabItem { Label(store.tr("Подписанные", "Signed"), systemImage: "tray.full.fill") }
                .tag(1)
            GamesView()
                .tabItem { Label(store.tr("Игры", "Games"), systemImage: "gamecontroller.fill") }
                .tag(2)
            SettingsView()
                .tabItem { Label(store.tr("Настройки", "Settings"), systemImage: "gearshape.fill") }
                .tag(3)
        }
        .tint(store.palette.accent)
    }
}

// MARK: - Вкладка «Установка»

struct SignView: View {
    @EnvironmentObject var store: AppStore
    @Binding var tab: Int

    @State private var ipaURL: URL?
    @State private var showPicker = false
    @State private var working = false
    @State private var progress = 0.0
    @State private var stepText = ""
    @State private var errorText: String?
    @State private var infoText: String?
    @State private var showClearConfirm = false

    var t: Palette { store.palette }

    var body: some View {
        ZStack {
            ThemedBackground()
            ScrollView {
                VStack(spacing: 14) {
                    clearBar
                    header

                    FileCard(theme: t,
                             title: store.tr("IPA файл", "IPA file"),
                             icon: "shippingbox.fill",
                             subtitle: ipaURL?.lastPathComponent ?? store.tr("Не выбран", "Not selected"),
                             done: ipaURL != nil) {
                        showPicker = true
                    }

                    certCard

                    if working {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(stepText)
                                .font(.subheadline.weight(.medium))
                                .foregroundColor(t.text)
                            ProgressView(value: progress)
                                .tint(t.accent)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .glassCard(t)
                    }

                    if let infoText {
                        Text(infoText)
                            .font(.subheadline)
                            .foregroundColor(.green)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .glassCard(t)
                    }

                    if let errorText {
                        Text(errorText)
                            .font(.subheadline)
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .glassCard(t)
                    }

                    Button {
                        startSign(install: true)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "arrow.down.app.fill")
                            Text(working ? store.tr("Подождите…", "Please wait…") : store.tr("Установить", "Install"))
                        }
                        .font(.headline)
                        .foregroundColor(t.onAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                        .glassButton(t.accent)
                        .opacity(isReady ? 1 : 0.45)
                    }
                    .buttonStyle(PressStyle())
                    .disabled(!isReady || working)
                    .padding(.top, 6)

                    Button {
                        startSign(install: false)
                    } label: {
                        Text(store.tr("Только подписать", "Sign only"))
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(t.text)
                            .padding(.horizontal, 28)
                            .padding(.vertical, 14)
                            .glassButton(nil)
                            .opacity(isReady ? 1 : 0.45)
                    }
                    .buttonStyle(PressStyle())
                    .disabled(!isReady || working)
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 110)
            }
        }
        .sheet(isPresented: $showPicker) {
            DocumentPicker(kind: .ipa) { url in
                showPicker = false
                if PickKind.ipa.accepts(url) {
                    ipaURL = url
                    errorText = nil
                    infoText = nil
                } else {
                    errorText = store.tr("Нужен файл с расширением .ipa", "A file with the .ipa extension is required")
                }
            }
        }
        .confirmationDialog(store.tr("Очистить кэш?", "Clear cache?"),
                            isPresented: $showClearConfirm,
                            titleVisibility: .visible) {
            Button(store.tr("Очистить", "Clear"), role: .destructive) {
                clearCache()
            }
            Button(store.tr("Отмена", "Cancel"), role: .cancel) {}
        } message: {
            Text(store.tr("Будут удалены только временные файлы и кэш приложения. Подписанные файлы, сертификат и установленные приложения останутся. Подписанные файлы можно удалить во вкладке «Подписанные».",
                          "Only temporary files and the app cache will be deleted. Signed files, your certificate and installed apps stay. Signed files can be removed in the “Signed” tab."))
        }
    }

    // Кнопка «Очистить кэш» в правом верхнем углу
    var clearBar: some View {
        HStack {
            Spacer()
            Button {
                showClearConfirm = true
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "trash")
                    Text(store.tr("Очистить кэш", "Clear cache"))
                }
                .font(.subheadline.weight(.semibold))
                .foregroundColor(t.text)
                .padding(.horizontal, 18)
                .padding(.vertical, 13)
                .glassButton(nil)
                .opacity(working ? 0.45 : 1)
            }
            .buttonStyle(PressStyle())
            .disabled(working)
        }
        .padding(.top, 6)
    }

    func clearCache() {
        let freed = store.clearCache()
        if let u = ipaURL, !FileManager.default.fileExists(atPath: u.path) {
            ipaURL = nil
        }
        errorText = nil
        if freed > 0 {
            let size = ByteCountFormatter.string(fromByteCount: freed, countStyle: .file)
            infoText = store.tr("Кэш очищен. Освобождено: \(size).", "Cache cleared. Freed: \(size).")
        } else {
            infoText = store.tr("Кэш уже пуст.", "The cache is already empty.")
        }
    }

    var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundColor(t.onAccent)
                .frame(width: 76, height: 76)
                .glassButton(t.accent, interactive: false)
            Text("OpSign")
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .foregroundColor(t.text)
            Text(store.tr("Подпись и установка приложений", "App signing & installing"))
                .font(.subheadline)
                .foregroundColor(t.subtext)
        }
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    var isReady: Bool { ipaURL != nil && store.hasCert }

    @ViewBuilder
    var certCard: some View {
        if store.hasCert {
            HStack(spacing: 14) {
                Image(systemName: "key.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(t.accent)
                    .frame(width: 46, height: 46)
                    .background(t.accent.opacity(0.16),
                                in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.tr("Сертификат", "Certificate"))
                        .font(.headline)
                        .foregroundColor(t.text)
                    Text(store.p12Name ?? "")
                        .font(.caption)
                        .foregroundColor(.green)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundColor(.green)
            }
            .frame(maxWidth: .infinity)
            .glassCard(t)
        } else {
            Button {
                tab = 3
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.orange)
                        .frame(width: 46, height: 46)
                        .background(Color.orange.opacity(0.16),
                                    in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(store.tr("Нет сертификата", "No certificate"))
                            .font(.headline)
                            .foregroundColor(t.text)
                        Text(store.tr("Нажми, чтобы добавить в Настройках", "Tap to add it in Settings"))
                            .font(.caption)
                            .foregroundColor(t.subtext)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundColor(t.subtext)
                }
                .frame(maxWidth: .infinity)
                .glassCard(t)
            }
            .buttonStyle(PressStyle())
        }
    }

    func startSign(install: Bool) {
        guard let ipa = ipaURL else { return }
        errorText = nil
        infoText = nil
        working = true
        progress = 0.02
        stepText = store.tr("Старт…", "Starting…")

        let p12 = store.p12URL
        let profile = store.profileURL
        let pass = store.password.trimmingCharacters(in: .whitespacesAndNewlines)
        let lang = store.lang

        let output: (url: URL, name: String)
        do {
            output = try store.newOutput(for: ipa)
        } catch {
            errorText = error.localizedDescription
            working = false
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try Signer.sign(ipa: ipa, p12: p12, password: pass, profile: profile,
                                             outURL: output.url, lang: lang) { text, p in
                    DispatchQueue.main.async {
                        stepText = text
                        progress = p
                    }
                }
                DispatchQueue.main.async {
                    store.registerSigned(url: output.url, name: output.name, info: result)
                    store.removeTemporaryCopy(ipa)
                    ipaURL = nil
                    working = false
                    if install, let item = store.signed.first {
                        infoText = store.tr("Готово! Файл сохранён во вкладке «Подписанные». Запускаю установку…",
                                            "Done! The file is saved in “Signed”. Starting installation…")
                        Task { @MainActor in
                            do {
                                try await store.beginInstall(item: item)
                            } catch {
                                errorText = error.localizedDescription
                            }
                        }
                    } else {
                        tab = 1
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    errorText = error.localizedDescription
                    working = false
                }
            }
        }
    }
}

// MARK: - Вкладка «Подписанные»

struct SignedView: View {
    @EnvironmentObject var store: AppStore
    @State private var errorText: String?
    @State private var showDeleteAll = false
    var t: Palette { store.palette }

    var body: some View {
        ZStack {
            ThemedBackground()
            ScrollView {
                VStack(spacing: 14) {
                    HStack {
                        Text(store.tr("Подписанные", "Signed"))
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .foregroundColor(t.text)
                        Spacer()
                        if !store.signed.isEmpty {
                            Button {
                                showDeleteAll = true
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "trash")
                                    Text(store.tr("Удалить все", "Delete all"))
                                }
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(.red)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                                .glassButton(nil)
                            }
                            .buttonStyle(PressStyle())
                        }
                    }
                    .padding(.top, 20)

                    if let errorText {
                        Text(errorText)
                            .font(.subheadline)
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .glassCard(t)
                    }

                    if store.signed.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "tray")
                                .font(.system(size: 48))
                                .foregroundColor(t.subtext)
                            Text(store.tr("Пока пусто", "Nothing here yet"))
                                .foregroundColor(t.subtext)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 90)
                    }

                    ForEach(store.signed) { item in
                        row(item)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 110)
            }
        }
        .onAppear { store.pruneMissing() }
        .confirmationDialog(store.tr("Удалить все подписанные файлы?", "Delete all signed files?"),
                            isPresented: $showDeleteAll,
                            titleVisibility: .visible) {
            Button(store.tr("Удалить все", "Delete all"), role: .destructive) {
                store.deleteAllSigned()
            }
            Button(store.tr("Отмена", "Cancel"), role: .cancel) {}
        } message: {
            Text(store.tr("Файлы будут удалены из приложения. Уже установленные приложения не пострадают.",
                          "The files will be removed from the app. Already installed apps are not affected."))
        }
    }

    func install(_ item: SignedItem) {
        errorText = nil
        Task { @MainActor in
            do {
                try await store.beginInstall(item: item)
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    func row(_ item: SignedItem) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(t.accent)
                    .frame(width: 46, height: 46)
                    .background(t.accent.opacity(0.16),
                                in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name)
                        .font(.headline)
                        .foregroundColor(t.text)
                        .lineLimit(1)
                    Text("\(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)) · \(item.date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundColor(t.subtext)
                    Text(item.isSigned ? store.tr("Подписан", "Signed") : store.tr("Не подписан (старая версия)", "Not signed (old version)"))
                        .font(.caption.weight(.medium))
                        .foregroundColor(item.isSigned ? .green : .orange)
                }
                Spacer()
            }

            HStack(spacing: 10) {
                Button {
                    install(item)
                } label: {
                    Label(store.tr("Установить", "Install"), systemImage: "arrow.down.app.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(t.onAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .glassButton(t.accent)
                        .opacity(item.bundleID == nil ? 0.4 : 1)
                }
                .buttonStyle(PressStyle())
                .disabled(item.bundleID == nil)

                ShareLink(item: store.url(for: item)) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(t.text)
                        .frame(width: 52, height: 52)
                        .glassButton(nil)
                }
                .buttonStyle(PressStyle())

                Button {
                    store.delete(item)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.red)
                        .frame(width: 52, height: 52)
                        .glassButton(nil)
                }
                .buttonStyle(PressStyle())
            }
        }
        .glassCard(t)
    }
}

// MARK: - Вкладка «Настройки»

struct SettingsView: View {
    @EnvironmentObject var store: AppStore
    @State private var picking: PickKind?
    @State private var errorText: String?
    @State private var checkMessage: String?
    @State private var checkOK = false
    @State private var showPassword = false
    @State private var themeTab = 0

    var t: Palette { store.palette }

    static let accentPresets: [String] = [
        "B359FF", "4D9AFF", "34D1BF", "30D158",
        "FFD60A", "FF9F0A", "FF453A", "FF5FA2"
    ]

    var body: some View {
        ZStack {
            ThemedBackground()
            ScrollView {
                VStack(spacing: 14) {
                    Text(store.tr("Настройки", "Settings"))
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundColor(t.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 20)

                    sectionTitle(store.tr("Сертификат", "Certificate"))

                    FileCard(theme: t,
                             title: store.tr("Сертификат .p12", "Certificate .p12"),
                             icon: "key.fill",
                             subtitle: store.p12Name ?? store.tr("Не выбран (только .p12)", "Not selected (.p12 only)"),
                             done: store.p12Name != nil) {
                        picking = .p12
                    }
                    FileCard(theme: t,
                             title: store.tr("Профиль .mobileprovision", "Profile .mobileprovision"),
                             icon: "doc.badge.gearshape.fill",
                             subtitle: store.profileName ?? store.tr("Не выбран (только .mobileprovision)", "Not selected (.mobileprovision only)"),
                             done: store.profileName != nil) {
                        picking = .profile
                    }

                    HStack(spacing: 14) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(t.accent)
                            .frame(width: 46, height: 46)
                            .background(t.accent.opacity(0.16),
                                        in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                        Group {
                            if showPassword {
                                TextField(text: $store.password,
                                          prompt: Text(store.tr("Пароль от .p12", ".p12 password")).foregroundColor(t.subtext)) { EmptyView() }
                            } else {
                                SecureField(text: $store.password,
                                            prompt: Text(store.tr("Пароль от .p12", ".p12 password")).foregroundColor(t.subtext)) { EmptyView() }
                            }
                        }
                        .foregroundColor(t.text)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)

                        Button {
                            showPassword.toggle()
                        } label: {
                            Image(systemName: showPassword ? "eye.slash.fill" : "eye.fill")
                                .foregroundColor(t.subtext)
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(PressStyle())
                    }
                    .frame(maxWidth: .infinity)
                    .glassCard(t)

                    if let info = store.profileInfo() {
                        let expired = info.expires < Date()
                        HStack {
                            Image(systemName: expired ? "xmark.octagon.fill" : "calendar")
                                .foregroundColor(expired ? .red : t.accent)
                            Text("\(info.name): \(expired ? store.tr("истёк", "expired") : store.tr("до", "until")) \(info.expires.formatted(date: .abbreviated, time: .omitted))")
                                .font(.subheadline)
                                .foregroundColor(expired ? .red : t.text)
                            Spacer()
                        }
                        .frame(maxWidth: .infinity)
                        .glassCard(t)
                    }

                    if let checkMessage {
                        Text(checkMessage)
                            .font(.subheadline)
                            .foregroundColor(checkOK ? .green : .red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .glassCard(t)
                    }
                    if let errorText {
                        Text(errorText)
                            .font(.subheadline)
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .glassCard(t)
                    }

                    HStack(spacing: 12) {
                        Button {
                            let r = store.checkCertificate()
                            checkOK = r.ok
                            checkMessage = r.message
                        } label: {
                            Text(store.tr("Проверить", "Check"))
                                .font(.headline)
                                .foregroundColor(t.onAccent)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 17)
                                .glassButton(t.accent)
                        }
                        .buttonStyle(PressStyle())

                        Button {
                            store.resetCert()
                            checkMessage = nil
                        } label: {
                            Text(store.tr("Удалить", "Delete"))
                                .font(.headline)
                                .foregroundColor(.red)
                                .padding(.horizontal, 28)
                                .padding(.vertical, 17)
                                .glassButton(nil)
                        }
                        .buttonStyle(PressStyle())
                    }

                    sectionTitle(store.tr("Язык", "Language"))

                    HStack(spacing: 12) {
                        ForEach(AppLanguage.allCases) { l in
                            languageTile(l)
                        }
                    }

                    sectionTitle(store.tr("Тема", "Theme"))

                    VStack(spacing: 16) {
                        Picker("", selection: $themeTab) {
                            Text(store.tr("Цвет интерфейса", "Interface")).tag(0)
                            Text(store.tr("Цвет кнопок", "Buttons")).tag(1)
                        }
                        .pickerStyle(.segmented)

                        if themeTab == 0 {
                            interfaceColors
                        } else {
                            buttonColors
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .glassCard(t)

                    Text("OpSign 1.0")
                        .font(.caption)
                        .foregroundColor(t.subtext)
                        .padding(.top, 10)
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 110)
            }
        }
        .sheet(item: $picking) { kind in
            DocumentPicker(kind: kind) { url in
                picking = nil
                guard kind.accepts(url) else {
                    errorText = store.tr("Нужен файл с расширением .\(kind.ext)", "A file with the .\(kind.ext) extension is required")
                    return
                }
                do {
                    try store.importFile(url, kind: kind)
                    store.removeTemporaryCopy(url)
                    errorText = nil
                    checkMessage = nil
                } catch {
                    errorText = error.localizedDescription
                }
            }
        }
    }

    // MARK: Помощники

    func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundColor(t.subtext)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 10)
            .padding(.leading, 6)
    }

    func hexBinding(_ keyPath: ReferenceWritableKeyPath<AppStore, String>) -> Binding<Color> {
        Binding(
            get: { Color(hex: store[keyPath: keyPath]) },
            set: { store[keyPath: keyPath] = $0.hexString }
        )
    }

    func languageTile(_ l: AppLanguage) -> some View {
        let selected = store.lang == l
        return Button {
            store.lang = l
        } label: {
            HStack(spacing: 8) {
                Text(l.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(selected ? t.onAccent : t.text)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(t.onAccent)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 17)
            .glassButton(selected ? t.accent : nil)
        }
        .buttonStyle(PressStyle())
    }

    // MARK: Цвет интерфейса

    @ViewBuilder
    var interfaceColors: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 12)], spacing: 14) {
            ForEach(AppTheme.allCases) { preset in
                presetTile(preset)
            }
            customTile
        }

        if store.bgChoice == "custom" {
            VStack(spacing: 6) {
                ColorPicker(store.tr("Верхний цвет", "Top color"),
                            selection: hexBinding(\.bgHex1), supportsOpacity: false)
                ColorPicker(store.tr("Нижний цвет", "Bottom color"),
                            selection: hexBinding(\.bgHex2), supportsOpacity: false)
            }
            .font(.subheadline)
            .foregroundColor(t.text)
        }
    }

    func presetTile(_ preset: AppTheme) -> some View {
        let selected = store.bgChoice == preset.rawValue
        return Button {
            store.bgChoice = preset.rawValue
        } label: {
            VStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(LinearGradient(colors: preset.colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(height: 62)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(selected ? t.accent : Color.gray.opacity(0.35),
                                    lineWidth: selected ? 3 : 1)
                    )
                Text(preset.title(store.lang))
                    .font(.caption.weight(.semibold))
                    .foregroundColor(t.text)
            }
        }
        .buttonStyle(PressStyle())
    }

    var customTile: some View {
        let selected = store.bgChoice == "custom"
        return Button {
            store.bgChoice = "custom"
        } label: {
            VStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(LinearGradient(colors: [Color(hex: store.bgHex1), Color(hex: store.bgHex2)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(height: 62)
                    .overlay(
                        Image(systemName: "paintpalette.fill")
                            .font(.title3)
                            .foregroundColor(.white.opacity(0.9))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(selected ? t.accent : Color.gray.opacity(0.35),
                                    lineWidth: selected ? 3 : 1)
                    )
                Text(store.tr("Свой", "Custom"))
                    .font(.caption.weight(.semibold))
                    .foregroundColor(t.text)
            }
        }
        .buttonStyle(PressStyle())
    }

    // MARK: Цвет кнопок

    @ViewBuilder
    var buttonColors: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 52), spacing: 14)], spacing: 14) {
            ForEach(SettingsView.accentPresets, id: \.self) { hex in
                swatch(hex)
            }
        }

        ColorPicker(store.tr("Свой цвет кнопок", "Custom button color"),
                    selection: hexBinding(\.accentHex), supportsOpacity: false)
            .font(.subheadline)
            .foregroundColor(t.text)

        HStack(spacing: 8) {
            Image(systemName: "sparkles")
            Text(store.tr("Так выглядят кнопки", "This is how buttons look"))
        }
        .font(.subheadline.weight(.semibold))
        .foregroundColor(t.onAccent)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .glassButton(t.accent, interactive: false)
    }

    func swatch(_ hex: String) -> some View {
        let selected = store.accentHex.uppercased() == hex
        return Button {
            store.accentHex = hex
        } label: {
            Circle()
                .fill(Color(hex: hex))
                .frame(width: 46, height: 46)
                .overlay(
                    Circle().stroke(Color.white.opacity(0.9), lineWidth: selected ? 3 : 0)
                )
                .overlay(
                    Image(systemName: "checkmark")
                        .font(.caption.bold())
                        .foregroundColor(.white)
                        .opacity(selected ? 1 : 0)
                )
                .shadow(color: Color(hex: hex).opacity(0.5), radius: 6)
                .frame(width: 52, height: 52)
        }
        .buttonStyle(PressStyle())
    }
}
