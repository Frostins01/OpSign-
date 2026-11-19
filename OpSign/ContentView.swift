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

// MARK: - Темы

enum AppTheme: String, CaseIterable, Identifiable {
    case dark, light, purple, ocean, sunset
    var id: String { rawValue }

    func title(_ lang: AppLanguage) -> String {
        switch self {
        case .dark: return lang == .ru ? "Чёрная" : "Black"
        case .light: return lang == .ru ? "Белая" : "White"
        case .purple: return lang == .ru ? "Фиолетовая" : "Purple"
        case .ocean: return lang == .ru ? "Океан" : "Ocean"
        case .sunset: return lang == .ru ? "Закат" : "Sunset"
        }
    }

    var colors: [Color] {
        switch self {
        case .dark: return [Color(red: 0.03, green: 0.03, blue: 0.04), Color(red: 0.10, green: 0.10, blue: 0.12)]
        case .light: return [Color(red: 0.97, green: 0.97, blue: 1.0), Color(red: 0.86, green: 0.89, blue: 1.0)]
        case .purple: return [Color(red: 0.05, green: 0.05, blue: 0.15), Color(red: 0.18, green: 0.06, blue: 0.35)]
        case .ocean: return [Color(red: 0.02, green: 0.08, blue: 0.18), Color(red: 0.0, green: 0.30, blue: 0.40)]
        case .sunset: return [Color(red: 0.18, green: 0.04, blue: 0.16), Color(red: 0.55, green: 0.17, blue: 0.20)]
        }
    }

    var accent: Color {
        switch self {
        case .dark: return Color(red: 0.40, green: 0.60, blue: 1.0)
        case .light: return Color(red: 0.35, green: 0.30, blue: 0.90)
        case .purple: return Color(red: 0.70, green: 0.35, blue: 1.0)
        case .ocean: return Color(red: 0.20, green: 0.85, blue: 0.90)
        case .sunset: return Color(red: 1.0, green: 0.60, blue: 0.25)
        }
    }

    var isLight: Bool { self == .light }
    var scheme: ColorScheme { isLight ? .light : .dark }
    var text: Color { isLight ? Color(white: 0.1) : .white }
    var subtext: Color { text.opacity(0.55) }
    var card: Color { isLight ? .white : Color.white.opacity(0.09) }
}

struct ThemedBackground: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        LinearGradient(colors: store.theme.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea()
    }
}

extension View {
    func cardStyle(_ t: AppTheme) -> some View {
        self.padding()
            .background(t.card)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .shadow(color: .black.opacity(t.isLight ? 0.08 : 0), radius: 8, x: 0, y: 2)
    }
}

struct FileCard: View {
    let theme: AppTheme
    let title: String
    let icon: String
    let subtitle: String
    let done: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundColor(theme.accent)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundColor(theme.text)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(done ? .green : theme.subtext)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: done ? "checkmark.circle.fill" : "plus.circle")
                    .foregroundColor(done ? .green : theme.subtext)
            }
            .cardStyle(theme)
        }
        .buttonStyle(.plain)
    }
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
}

struct AppError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class AppStore: ObservableObject {
    @Published var theme: AppTheme {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: "theme") }
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

    init() {
        let d = UserDefaults.standard
        theme = AppTheme(rawValue: d.string(forKey: "theme") ?? "") ?? .purple
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
    }

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

    func registerSigned(url: URL, name: String) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let item = SignedItem(name: name, fileName: url.lastPathComponent,
                              date: Date(), size: size, isSigned: true)
        signed.insert(item, at: 0)
    }

    func delete(_ item: SignedItem) {
        try? FileManager.default.removeItem(at: url(for: item))
        signed.removeAll { $0.id == item.id }
    }

    private func persistSigned() {
        if let data = try? JSONEncoder().encode(signed) {
            UserDefaults.standard.set(data, forKey: "signed")
        }
    }
}

// MARK: - Главный экран с вкладками

struct ContentView: View {
    @EnvironmentObject var store: AppStore
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            SignView(tab: $tab)
                .tabItem { Label(store.tr("Подпись", "Sign"), systemImage: "checkmark.seal.fill") }
                .tag(0)
            SignedView()
                .tabItem { Label(store.tr("Подписанные", "Signed"), systemImage: "tray.full.fill") }
                .tag(1)
            SettingsView()
                .tabItem { Label(store.tr("Настройки", "Settings"), systemImage: "gearshape.fill") }
                .tag(2)
        }
        .tint(store.theme.accent)
    }
}

// MARK: - Вкладка «Подпись»

struct SignView: View {
    @EnvironmentObject var store: AppStore
    @Binding var tab: Int

    @State private var ipaURL: URL?
    @State private var showPicker = false
    @State private var working = false
    @State private var progress = 0.0
    @State private var stepText = ""
    @State private var errorText: String?

    var t: AppTheme { store.theme }

    var body: some View {
        ZStack {
            ThemedBackground()
            ScrollView {
                VStack(spacing: 16) {
                    Text("OpSign")
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                        .foregroundColor(t.text)
                        .padding(.top, 24)
                    Text(store.tr("Подпись приложений", "App signing"))
                        .font(.subheadline)
                        .foregroundColor(t.subtext)
                        .padding(.bottom, 8)

                    FileCard(theme: t,
                             title: store.tr("IPA файл", "IPA file"),
                             icon: "shippingbox.fill",
                             subtitle: ipaURL?.lastPathComponent ?? store.tr("Не выбран", "Not selected"),
                             done: ipaURL != nil) {
                        showPicker = true
                    }

                    certCard

                    if working {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(stepText)
                                .font(.subheadline)
                                .foregroundColor(t.text)
                            ProgressView(value: progress)
                                .tint(t.accent)
                        }
                        .cardStyle(t)
                    }

                    if let errorText {
                        Text(errorText)
                            .font(.subheadline)
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .cardStyle(t)
                    }

                    Button(action: startSign) {
                        Text(working ? store.tr("Подождите…", "Please wait…") : store.tr("Подписать", "Sign"))
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(
                                LinearGradient(colors: [t.accent, t.accent.opacity(0.65)],
                                               startPoint: .leading, endPoint: .trailing)
                            )
                            .clipShape(RoundRectangle(cornerRadius: 18))
                            .opacity(isReady ? 1 : 0.4)
                    }
                    .disabled(!isReady || working)
                    .padding(.top, 8)
                }
                .padding()
            }
        }
        .sheet(isPresented: $showPicker) {
            DocumentPicker(kind: .ipa) { url in
                showPicker = false
                if PickKind.ipa.accepts(url) {
                    ipaURL = url
                    errorText = nil
                } else {
                    errorText = store.tr("Нужен файл с расширением .ipa", "A file with the .ipa extension is required")
                }
            }
        }
    }

    var isReady: Bool { ipaURL != nil && store.hasCert }

    @ViewBuilder
    var certCard: some View {
        if store.hasCert {
            HStack(spacing: 14) {
                Image(systemName: "key.fill")
                    .font(.title2)
                    .foregroundColor(t.accent)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.tr("Сертификат", "Certificate"))
                        .font(.headline)
                        .foregroundColor(t.text)
                    Text(store.p12Name ?? "")
                        .font(.caption)
                        .foregroundColor(.green)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
            }
            .cardStyle(t)
        } else {
            Button {
                tab = 2
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title2)
                        .foregroundColor(.orange)
                        .frame(width: 32)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(store.tr("Нет сертификата", "No certificate"))
                            .font(.headline)
                            .foregroundColor(t.text)
                        Text(store.tr("Нажми, чтобы добавить в Настройках", "Tap to add it in Settings"))
                            .font(.caption)
                            .foregroundColor(t.subtext)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundColor(t.subtext)
                }
                .cardStyle(t)
            }
            .buttonStyle(.plain)
        }
    }

    func startSign() {
        guard let ipa = ipaURL else { return }
        errorText = nil
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
                try Signer.sign(ipa: ipa, p12: p12, password: pass, profile: profile,
                                outURL: output.url, lang: lang) { text, p in
                    DispatchQueue.main.async {
                        stepText = text
                        progress = p
                    }
                }
                DispatchQueue.main.async {
                    store.registerSigned(url: output.url, name: output.name)
                    ipaURL = nil
                    working = false
                    tab = 1
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
    var t: AppTheme { store.theme }

    var body: some View {
        ZStack {
            ThemedBackground()
            ScrollView {
                VStack(spacing: 14) {
                    Text(store.tr("Подписанные", "Signed"))
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundColor(t.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 24)

                    if store.signed.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "tray")
                                .font(.system(size: 44))
                                .foregroundColor(t.subtext)
                            Text(store.tr("Пока пусто", "Nothing here yet"))
                                .foregroundColor(t.subtext)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 80)
                    }

                    ForEach(store.signed) { item in
                        row(item)
                    }
                }
                .padding()
            }
        }
    }

    func row(_ item: SignedItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Image(systemName: "shippingbox.fill")
                    .font(.title2)
                    .foregroundColor(t.accent)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name)
                        .font(.headline)
                        .foregroundColor(t.text)
                        .lineLimit(1)
                    Text("\(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)) · \(item.date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundColor(t.subtext)
                    Text(item.isSigned ? store.tr("Подписан", "Signed") : store.tr("Не подписан (старая версия)", "Not signed (old version)"))
                        .font(.caption)
                        .foregroundColor(item.isSigned ? .green : .orange)
                }
                Spacer()
            }
            HStack(spacing: 12) {
                ShareLink(item: store.url(for: item)) {
                    Label(store.tr("Сохранить / Поделиться", "Save / Share"), systemImage: "square.and.arrow.up")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(t.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                Button {
                    store.delete(item)
                } label: {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                        .padding(10)
                        .background(Color.red.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .cardStyle(t)
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

    var t: AppTheme { store.theme }

    var body: some View {
        ZStack {
            ThemedBackground()
            ScrollView {
                VStack(spacing: 16) {
                    Text(store.tr("Настройки", "Settings"))
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundColor(t.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 24)

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
                            .font(.title2)
                            .foregroundColor(t.accent)
                            .frame(width: 32)
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
                        }
                    }
                    .cardStyle(t)

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
                        .cardStyle(t)
                    }

                    if let checkMessage {
                        Text(checkMessage)
                            .font(.subheadline)
                            .foregroundColor(checkOK ? .green : .red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .cardStyle(t)
                    }
                    if let errorText {
                        Text(errorText)
                            .font(.subheadline)
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .cardStyle(t)
                    }

                    HStack(spacing: 12) {
                        Button {
                            let r = store.checkCertificate()
                            checkOK = r.ok
                            checkMessage = r.message
                        } label: {
                            Text(store.tr("Проверить", "Check"))
                                .font(.headline)
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(t.accent)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                        }
                        Button {
                            store.resetCert()
                            checkMessage = nil
                        } label: {
                            Text(store.tr("Удалить", "Delete"))
                                .font(.headline)
                                .foregroundColor(.red)
                                .padding()
                                .background(Color.red.opacity(0.15))
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                        }
                    }

                    sectionTitle(store.tr("Язык", "Language"))

                    HStack(spacing: 12) {
                        ForEach(AppLanguage.allCases) { l in
                            languageTile(l)
                        }
                    }

                    sectionTitle(store.tr("Тема", "Theme"))

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 12) {
                        ForEach(AppTheme.allCases) { theme in
                            themeTile(theme)
                        }
                    }

                    Text("OpSign 1.0")
                        .font(.caption)
                        .foregroundColor(t.subtext)
                        .padding(.top, 16)
                }
                .padding()
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
                    errorText = nil
                    checkMessage = nil
                } catch {
                    errorText = error.localizedDescription
                }
            }
        }
    }

    func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundColor(t.subtext)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
    }

    func languageTile(_ l: AppLanguage) -> some View {
        Button {
            store.lang = l
        } label: {
            HStack(spacing: 8) {
                Text(l.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(t.text)
                if store.lang == l {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(t.accent)
                }
            }
            .frame(maxWidth: .infinity)
            .cardStyle(t)
        }
        .buttonStyle(.plain)
    }

    func themeTile(_ theme: AppTheme) -> some View {
        Button {
            store.theme = theme
        } label: {
            VStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(LinearGradient(colors: theme.colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(height: 64)
                    .overlay(
                        Circle().fill(theme.accent).frame(width: 22, height: 22)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.gray.opacity(0.4), lineWidth: 1)
                    )
                HStack(spacing: 6) {
                    Text(theme.title(store.lang))
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(t.text)
                    if store.theme == theme {
                        Image(systemName: "checkmark.circle.fill").foregroundColor(t.accent)
                    }
                }
            }
            .cardStyle(t)
        }
        .buttonStyle(.plain)
    }
}
