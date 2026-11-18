import SwiftUI
import UniformTypeIdentifiers

enum PickTarget {
    case ipa, p12, profile
}

struct ContentView: View {
    @State private var ipaURL: URL?
    @State private var p12URL: URL?
    @State private var profileURL: URL?
    @State private var password = ""
    @State private var target: PickTarget = .ipa
    @State private var showPicker = false
    @State private var showAlert = false

    var isReady: Bool {
        ipaURL != nil && p12URL != nil && profileURL != nil && !password.isEmpty
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.05, green: 0.05, blue: 0.15),
                         Color(red: 0.18, green: 0.06, blue: 0.35)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 16) {
                    Text("OpSign")
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .padding(.top, 24)

                    Text("Подпись приложений")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.6))
                        .padding(.bottom, 8)

                    fileCard(title: "IPA файл", icon: "shippingbox.fill", url: ipaURL) {
                        target = .ipa
                        showPicker = true
                    }
                    fileCard(title: "Сертификат .p12", icon: "key.fill", url: p12URL) {
                        target = .p12
                        showPicker = true
                    }
                    fileCard(title: "Профиль .mobileprovision", icon: "doc.badge.gearshape.fill", url: profileURL) {
                        target = .profile
                        showPicker = true
                    }

                    HStack(spacing: 14) {
                        Image(systemName: "lock.fill")
                            .font(.title2)
                            .foregroundColor(.purple)
                            .frame(width: 32)
                        SecureField("Пароль от .p12", text: $password)
                            .foregroundColor(.white)
                    }
                    .padding()
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 18))

                    Button {
                        showAlert = true
                    } label: {
                        Text("Подписать")
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(
                                LinearGradient(colors: [.purple, .blue],
                                               startPoint: .leading,
                                               endPoint: .trailing)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                            .opacity(isReady ? 1 : 0.4)
                    }
                    .disabled(!isReady)
                    .padding(.top, 8)
                }
                .padding()
            }
        }
        .fileImporter(
            isPresented: $showPicker,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                switch target {
                case .ipa: ipaURL = url
                case .p12: p12URL = url
                case .profile: profileURL = url
                }
            }
        }
        .alert("Скоро", isPresented: $showAlert) {
            Button("Ок", role: .cancel) {}
        } message: {
            Text("Подпись добавим на следующем этапе.")
        }
    }

    func fileCard(title: String, icon: String, url: URL?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundColor(.purple)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundColor(.white)
                    Text(url?.lastPathComponent ?? "Не выбран")
                        .font(.caption)
                        .foregroundColor(url == nil ? .white.opacity(0.5) : .green)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: url == nil ? "plus.circle" : "checkmark.circle.fill")
                    .foregroundColor(url == nil ? .white.opacity(0.5) : .green)
            }
            .padding()
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 18))
        }
    }
}
