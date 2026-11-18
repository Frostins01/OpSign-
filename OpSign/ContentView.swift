import SwiftUI
import UniformTypeIdentifiers
import Security
#if canImport(OpenSSL)
import OpenSSL
#endif

// MARK: - Темы

enum AppTheme: String, CaseIterable, Identifiable {
    case dark, light, purple, ocean, sunset
    var id: String { rawValue }

    var title: String {
        switch self {
        case .dark: return "Чёрная"
        case .light: return "Белая"
        case .purple: return "Фиолетовая"
        case .ocean: return "Океан"
        case .sunset: return "Закат"
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

func opensslCheck(_ data: Data, _ pass: String) -> (ok: Bool, message: String) {
    #if canImport(OpenSSL)
    var out: (ok: Bool, message: String) = (false, "Неизвестная ошибка")
    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
            out = (false, "Файл пустой")
            return
        }
        var ptr: UnsafePointer<UInt8>? = base
        guard let p12 = d2i_PKCS12(nil, &ptr, data.count) else {
            out = (false, "Структура файла не похожа на .p12. Скорее всего, выбран не тот файл или он повреждён.")
            return
        }
        defer { PKCS12_free(p12) }

        if PKCS12_verify_mac(p12, pass, -1) != 1 {
            out = (false, "Неверный пароль от .p12. Проверь пароль (нажми на глазок рядом с полем).")
            return
        }

        var pkey: OpaquePointer?
        var cert: OpaquePointer?
        if PKCS12_parse(p12, pass, &pkey, &cert, nil) != 1 {
            out = (false, "Пароль верный, но файл использует устаревший алгоритм шифрования. Выпусти или пересохрани .p12 заново.")
            return
        }

        var name = "сертификат"
        if let c = cert, let subj = X509_get_subject_name(c) {
            var buf = [CChar](repeating: 0, count: 256)
            if X509_NAME_get_text_by_NID(subj, NID_commonName, &buf, 256) > 0 {
                name = String(cString: buf)
            }
        }
        if let c = cert { X509_free(c) }
        if let k = pkey { EVP_PKEY_free(k) }
        out = (true, "Пароль верный: \(name)")
    }
    return out
    #else
    return (false, "OpenSSL не подключён в сборке.")
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
        p12Name = d.string(forKey: "p12Name")
        profileName = d.string(forKey: "profileName")
        password = d.string(forKey: "p12Password") ?? ""
        if let data = d.data(forKey: "signed"),
           let items = try? JSONDecoder().decode([SignedItem].self, from: data) {
            signed = items
        }
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
            return (false, "Файл .p12 не найден. Добавь его в Настройках.")
        }
        if data.count < 200 {
            return (false, "Файл .p12 слишком маленький (\(data.count) байт). Скорее всего, выбран не тот файл.")
        }
        let pass = password.trimmingCharacters(in: .whitespacesAndNewlines)
        if pass.isEmpty {
            return (false, "Введи пароль от .p12 в поле выше.")
        }

        // 1. Системная проверка iOS (старые форматы)
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
            let name = cert.flatMap { SecCertificateCopySubjectSummary($0) as String? } ?? "сертификат"
            return (true, "Пароль верный: \(name)")
        }

        // 2. Если iOS не справилась, проверяем через OpenSSL (новые форматы)
        return opensslCheck(data, pass)
    }

    func profileInfo() -> (name: String, expires: Date)? {
        guard let data = try? Data(contentsOf: profileURL),
              let s = String(data: data, encoding: .isoLatin1),
              let a = s.range(of: "<?xml"),
              let b = s.range(of: "</plist>") else { return nil }
        let xml = String(s[a.lowerBound..<b.upperBound])
        guard let d = xml.data(using: .isoLatin1),
              let obj = try? PropertyListSerialization.propertyList(from: d, options: [], format: nil) as? [String: Any]
        else { return nil }
        let name = obj["Name"] as? String ?? "Профиль"
        let exp = obj["ExpirationDate"] as? Date ?? Date.distantPast
        return (name, exp)
    }

    func createSigned(from ipa: URL) throws -> SignedItem {
        let fm = FileManager.default
        try fm.createDirectory(at: signedDir, withIntermediateDirectories: true)
        let base = ipa.deletingPathExtension().lastPathComponent
        let name = "\(base)_OpSign.ipa"
        let fileName = "\(UUID().uuidString.prefix(6))_\(name)"
        let dest = signedDir.appendingPathComponent(fileName)
        try fm.copyItem(at: ipa, to: dest)
        let attrs = try? fm.attributesOfItem(atPath: dest.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let item = SignedItem(name: name, fileName: fileName, date: Date(), size: size, isSigned: false)
        signed.insert(item, at: 0)
        return item
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
                .tabItem { Label("Подпись", systemImage: "checkmark.seal.fill") }
                .tag(0)
            SignedView()
                .tabItem { Label("Подписанные", systemImage: "tray.full.fill") }
                .tag(1)
            SettingsView()
                .tabItem { Label("Настройки", systemImage: "gearshape.fill") }
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
                    Text("Подпись приложений")
                        .font(.subheadline)
                        .foregroundColor(t.subtext)
                        .padding(.bottom, 8)

                    FileCard(theme: t, title: "IPA файл", icon: "shippingbox.fill",
                             subtitle: ipaURL?.lastPathComponent ?? "Не выбран",
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
                        Text(working ? "Подождите…" : "Подписать")
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(
                                LinearGradient(colors: [t.accent, t.accent.opacity(0.65)],
                                               startPoint: .leading, endPoint: .trailing)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 18))
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
                    errorText = "Нужен файл с расширением .ipa"
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
                    Text("Сертификат")
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
                        Text("Нет сертификата")
                            .font(.headline)
                            .foregroundColor(t.text)
                        Text("Нажми, чтобы добавить в Настройках")
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
        progress = 0.1
        stepText = "Проверка сертификата…"
        Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 300_000_000)
                let check = store.checkCertificate()
                guard check.ok else { throw AppError(message: check.message) }
                progress = 0.45
                stepText = "Подготовка файла…"
                try await Task.sleep(nanoseconds: 300_000_000)
                _ = try store.createSigned(from: ipa)
                progress = 1
                stepText = "Готово"
                try await Task.sleep(nanoseconds: 400_000_000)
                ipaURL = nil
                working = false
                tab = 1
            } catch {
                errorText = error.localizedDescription
                working = false
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
                    Text("Подписанные")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundColor(t.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 24)

                    if store.signed.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "tray")
                                .font(.system(size: 44))
                                .foregroundColor(t.subtext)
                            Text("Пока пусто")
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
                    Text(item.isSigned ? "Подписан" : "Не подписан (подпись на следующем этапе)")
                        .font(.caption)
                        .foregroundColor(item.isSigned ? .green : .orange)
                }
                Spacer()
            }
            HStack(spacing: 12) {
                ShareLink(item: store.url(for: item)) {
                    Label("Сохранить / Поделиться", systemImage: "square.and.arrow.up")
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
                    Text("Настройки")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundColor(t.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 24)

                    sectionTitle("Сертификат")

                    FileCard(theme: t, title: "Сертификат .p12", icon: "key.fill",
                             subtitle: store.p12Name ?? "Не выбран (только .p12)",
                             done: store.p12Name != nil) {
                        picking = .p12
                    }
                    FileCard(theme: t, title: "Профиль .mobileprovision", icon: "doc.badge.gearshape.fill",
                             subtitle: store.profileName ?? "Не выбран (только .mobileprovision)",
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
                                          prompt: Text("Пароль от .p12").foregroundColor(t.subtext)) { EmptyView() }
                            } else {
                                SecureField(text: $store.password,
                                            prompt: Text("Пароль от .p12").foregroundColor(t.subtext)) { EmptyView() }
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
                            Text("\(info.name): \(expired ? "истёк" : "до") \(info.expires.formatted(date: .abbreviated, time: .omitted))")
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
                            Text("Проверить")
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
                            Text("Удалить")
                                .font(.headline)
                                .foregroundColor(.red)
                                .padding()
                                .background(Color.red.opacity(0.15))
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                        }
                    }

                    sectionTitle("Тема")

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
                    errorText = "Нужен файл с расширением .\(kind.ext)"
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
                    Text(theme.title)
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
