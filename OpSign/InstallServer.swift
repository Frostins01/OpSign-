import Foundation
import Network
import UIKit

/// Маленький локальный сервер: отдаёт подписанный IPA и запускает системную установку iOS.
final class InstallServer {
    private let queue = DispatchQueue(label: "opsign.install.server")
    private var listener: NWListener?
    private var ipaFile: URL?
    private var ipaPath = "/app.ipa"
    private var pageHTML = ""
    private var bgTask: UIBackgroundTaskIdentifier = .invalid

    /// Ссылка itms-services, которую открывает presentSafari (системное окно установки)
    private static var pendingInstallLink: URL?

    // MARK: Запуск

    func start(ipa: URL, bundleID: String, name: String, version: String) async throws -> URL {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)

        let l = try NWListener(using: params)
        l.newConnectionHandler = { [weak self] conn in
            self?.handle(conn)
        }

        let port: UInt16 = try await withCheckedThrowingContinuation { cont in
            var finished = false
            l.stateUpdateHandler = { state in
                if finished { return }
                switch state {
                case .ready:
                    finished = true
                    cont.resume(returning: l.port?.rawValue ?? 0)
                case .failed(let error):
                    finished = true
                    cont.resume(throwing: error)
                default:
                    break
                }
            }
            l.start(queue: self.queue)
        }

        if port == 0 {
            l.cancel()
            throw AppError(message: "Local server did not start (no port)")
        }

        listener = l
        ipaFile = ipa
        ipaPath = "/\(UUID().uuidString).ipa"

        let ipaURL = "http://127.0.0.1:\(port)\(ipaPath)"

        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        func enc(_ s: String) -> String {
            s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
        }

        let plistURL = "https://api.palera.in/genPlist?bundleid=\(enc(bundleID))&name=\(enc(name))&version=\(enc(version))&fetchurl=\(ipaURL)"
        let itms = "itms-services://?action=download-manifest&url=\(enc(plistURL))"

        // Запоминаем ссылку: presentSafari откроет её напрямую
        InstallServer.pendingInstallLink = URL(string: itms)

        pageHTML = makeHTML(itms: itms)
        return URL(string: "http://127.0.0.1:\(port)/install")!
    }

    func stop() {
        listener?.cancel()
        listener = nil
        DispatchQueue.main.async { self.endKeepAlive() }
    }

    // MARK: Работа в фоне

    func keepAlive() {
        if bgTask == .invalid {
            bgTask = UIApplication.shared.beginBackgroundTask { [weak self] in
                self?.endKeepAlive()
            }
        }
    }

    private func endKeepAlive() {
        if bgTask != .invalid {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
    }

    // MARK: Запасная страница (на случай ручного открытия /install)

    private func makeHTML(itms: String) -> String {
        let attr = itms.replacingOccurrences(of: "&", with: "&amp;")
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>OpSign</title>
        </head>
        <body>
        <a id="go" href="\(attr)">Install</a>
        <script>
        window.location.href = "\(itms)";
        </script>
        </body>
        </html>
        """
    }

    // MARK: Обработка запросов

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                conn.cancel()
                return
            }
            let firstLine = request.components(separatedBy: "\r\n").first ?? ""
            let parts = firstLine.split(separator: " ")
            guard parts.count >= 2 else {
                conn.cancel()
                return
            }
            let method = String(parts[0])
            var path = String(parts[1])
            if let q = path.firstIndex(of: "?") { path = String(path[..<q]) }
            self.route(method: method, path: path, request: request, conn: conn)
        }
    }

    private func route(method: String, path: String, request: String, conn: NWConnection) {
        if path == "/" || path == "/install" {
            let body = Data(pageHTML.utf8)
            let head = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            var out = Data(head.utf8)
            if method != "HEAD" { out.append(body) }
            conn.send(content: out, contentContext: .finalMessage, isComplete: true,
                      completion: .contentProcessed { _ in conn.cancel() })
            return
        }

        if path == ipaPath,
           let file = ipaFile,
           let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
           let size = (attrs[.size] as? NSNumber)?.uint64Value,
           size > 0 {

            var start: UInt64 = 0
            var end: UInt64 = size - 1
            var partial = false

            for line in request.components(separatedBy: "\r\n") where line.lowercased().hasPrefix("range:") {
                let value = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                if value.lowercased().hasPrefix("bytes=") {
                    let spec = value.dropFirst(6)
                    let comps = spec.split(separator: "-", omittingEmptySubsequences: false)
                    if comps.count == 2 {
                        if let s = UInt64(comps[0]) {
                            start = s
                            partial = true
                            if let e = UInt64(comps[1]) { end = min(e, size - 1) }
                        } else if let suffix = UInt64(comps[1]) {
                            start = size > suffix ? size - suffix : 0
                            partial = true
                        }
                    }
                }
            }

            if start >= size || start > end {
                let head = "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */\(size)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                conn.send(content: Data(head.utf8), contentContext: .finalMessage, isComplete: true,
                          completion: .contentProcessed { _ in conn.cancel() })
                return
            }

            let length = end - start + 1
            var head = partial ? "HTTP/1.1 206 Partial Content\r\n" : "HTTP/1.1 200 OK\r\n"
            head += "Content-Type: application/octet-stream\r\n"
            head += "Accept-Ranges: bytes\r\n"
            head += "Content-Length: \(length)\r\n"
            if partial { head += "Content-Range: bytes \(start)-\(end)/\(size)\r\n" }
            head += "Connection: close\r\n\r\n"

            if method == "HEAD" {
                conn.send(content: Data(head.utf8), contentContext: .finalMessage, isComplete: true,
                          completion: .contentProcessed { _ in conn.cancel() })
                return
            }

            conn.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] error in
                guard error == nil, let self,
                      let fh = try? FileHandle(forReadingFrom: file) else {
                    conn.cancel()
                    return
                }
                try? fh.seek(toOffset: start)
                self.pump(fh, remaining: length, conn)
            })
            return
        }

        let head = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8), contentContext: .finalMessage, isComplete: true,
                  completion: .contentProcessed { _ in conn.cancel() })
    }

    private func pump(_ fh: FileHandle, remaining: UInt64, _ conn: NWConnection) {
        if remaining == 0 {
            try? fh.close()
            conn.send(content: nil, contentContext: .finalMessage, isComplete: true,
                      completion: .contentProcessed { _ in conn.cancel() })
            return
        }
        let n = Int(min(remaining, 262_144))
        let chunk = fh.readData(ofLength: n)
        if chunk.isEmpty {
            try? fh.close()
            conn.cancel()
            return
        }
        conn.send(content: chunk, completion: .contentProcessed { [weak self] error in
            if error != nil {
                try? fh.close()
                conn.cancel()
                return
            }
            self?.pump(fh, remaining: remaining - UInt64(chunk.count), conn)
        })
    }

    // MARK: Системное окно установки iOS
    // Название оставлено прежним, чтобы не менять другие файлы.
    // Параметр url игнорируется, если есть готовая itms-services ссылка.

    static func presentSafari(_ url: URL) {
        let target: URL
        if let itms = pendingInstallLink {
            target = itms
        } else if url.scheme == "itms-services" {
            target = url
        } else {
            return
        }

        DispatchQueue.main.async {
            UIApplication.shared.open(target, options: [:], completionHandler: nil)
        }
    }
}
