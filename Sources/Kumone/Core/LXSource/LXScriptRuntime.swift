import CommonCrypto
import CryptoKit
import Foundation
import JavaScriptCore
import Security

/// Metadata from a custom-source script's leading `/*! @name … */` comment,
/// parsed the way LX Music reads it.
struct LXScriptInfo: Codable, Hashable, Sendable {
    var name: String
    var description: String
    var version: String
    var author: String
    var homepage: String

    static func parse(_ script: String) -> LXScriptInfo {
        var info = LXScriptInfo(name: "", description: "", version: "", author: "", homepage: "")
        let trimmed = script.drop(while: { $0.isWhitespace || $0 == "\u{FEFF}" })
        guard trimmed.hasPrefix("/*"), let end = trimmed.range(of: "*/") else { return info }
        let comment = trimmed[trimmed.startIndex..<end.lowerBound]
        for rawLine in comment.split(whereSeparator: \.isNewline) {
            let line = rawLine.drop(while: { $0 == " " || $0 == "\t" || $0 == "*" || $0 == "/" || $0 == "!" })
            guard line.hasPrefix("@") else { continue }
            let parts = line.dropFirst().split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
            guard let key = parts.first else { continue }
            let value = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
            switch key {
            case "name": info.name = String(value.prefix(48))
            case "description": info.description = String(value.prefix(120))
            case "version": info.version = String(value.prefix(36))
            case "author": info.author = String(value.prefix(56))
            case "homepage": info.homepage = String(value.prefix(1024))
            default: break
            }
        }
        return info
    }
}

/// One platform a script registered in its `inited` event, e.g.
/// `kw: { name: '酷我音乐', actions: ['musicUrl', 'search'], qualitys: [...] }`.
struct LXRegisteredSource: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let name: String
    let actions: [String]
    let qualities: [String]

    var supportsMusicURL: Bool { actions.contains("musicUrl") }
    var supportsLyric: Bool { actions.contains("lyric") }
    /// LX itself has no search action; scripts that add one call it
    /// `search` or `musicSearch`.
    var searchAction: String? {
        if actions.contains("musicSearch") { return "musicSearch" }
        if actions.contains("search") { return "search" }
        return nil
    }
}

struct LXUpdateAlert: Codable, Hashable, Sendable {
    let log: String
    let updateURL: String?
}

/// A JSON value handed back by a script, already decoded with
/// `JSONSerialization`. Only ever read, so sharing it across actors is safe.
struct LXValue: @unchecked Sendable {
    let raw: Any?

    var string: String? { raw as? String }
    var dictionary: [String: Any]? { raw as? [String: Any] }
    var array: [Any]? { raw as? [Any] }
}

enum LXScriptError: LocalizedError, Equatable {
    case evaluation(String)
    case initTimeout
    case notReady
    case stopped
    case timeout
    case script(String)
    case invalidResult

    var errorDescription: String? {
        switch self {
        case .evaluation(let message): return String(localized: "脚本运行出错：\(message)")
        case .initTimeout: return String(localized: "脚本初始化超时")
        case .notReady: return String(localized: "脚本尚未初始化")
        case .stopped: return String(localized: "脚本已停止")
        case .timeout: return String(localized: "脚本响应超时")
        case .script(let message): return message
        case .invalidResult: return String(localized: "脚本返回了无法识别的结果")
        }
    }
}

/// Runs one LX Music custom-source script in its own JavaScriptCore VM.
///
/// Every touch of the context happens on `queue`, a private serial queue: the
/// script itself, the native functions it calls, HTTP responses, timers and
/// dispatched requests. Swift callers only see async methods.
final class LXScriptRuntime: @unchecked Sendable {
    let info: LXScriptInfo
    private let script: String
    private let queue: DispatchQueue
    private let session: URLSession

    // Queue-confined state.
    private var context: JSContext?
    private var initContinuation: CheckedContinuation<[LXRegisteredSource], Error>?
    private var sources: [LXRegisteredSource]?
    private var calls: [Int: CheckedContinuation<LXValue, Error>] = [:]
    private var callSeq = 0
    private var tasks: [Int: URLSessionDataTask] = [:]
    private var isStopped = false

    /// Called on the runtime's queue.
    var onUpdateAlert: (@Sendable (LXUpdateAlert) -> Void)?
    /// Called on the runtime's queue with `console` output and script errors.
    var onLog: (@Sendable (String, String) -> Void)?

    init(script: String, info: LXScriptInfo, session: URLSession? = nil) {
        self.script = script
        self.info = info
        self.queue = DispatchQueue(label: "im.missuo.kumone.lx-script", qos: .userInitiated)
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 60
            configuration.httpCookieStorage = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: configuration)
        }
    }

    deinit {
        let tasks = self.tasks
        tasks.values.forEach { $0.cancel() }
    }

    // MARK: - Lifecycle

    /// Evaluates the script and waits for its `inited` event.
    func start(timeout: TimeInterval = 15) async throws -> [LXRegisteredSource] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard !isStopped else {
                    continuation.resume(throwing: LXScriptError.stopped)
                    return
                }
                if let sources {
                    continuation.resume(returning: sources)
                    return
                }
                initContinuation = continuation
                queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.finishInit(.failure(LXScriptError.initTimeout))
                }
                evaluate()
            }
        }
    }

    func stop() {
        queue.async { [self] in
            isStopped = true
            tasks.values.forEach { $0.cancel() }
            tasks.removeAll()
            finishInit(.failure(LXScriptError.stopped))
            let pending = calls
            calls.removeAll()
            pending.values.forEach { $0.resume(throwing: LXScriptError.stopped) }
            context?.exceptionHandler = nil
            context = nil
        }
    }

    /// Dispatches `{ source, action, info }` to the script's request handler
    /// and returns what its promise resolves to.
    func call(source: String, action: String, info: [String: Any], timeout: TimeInterval = 20) async throws -> LXValue {
        let infoJSON = String(decoding: (try? JSONSerialization.data(withJSONObject: info)) ?? Data("{}".utf8), as: UTF8.self)
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard !isStopped, let context, sources != nil else {
                    continuation.resume(throwing: isStopped ? LXScriptError.stopped : LXScriptError.notReady)
                    return
                }
                callSeq += 1
                let callID = callSeq
                calls[callID] = continuation
                queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.calls.removeValue(forKey: callID)?.resume(throwing: LXScriptError.timeout)
                }
                context.objectForKeyedSubscript("__lx_internal")?
                    .invokeMethod("dispatch", withArguments: [callID, source, action, infoJSON])
            }
        }
    }

    // MARK: - Evaluation (queue)

    private func evaluate() {
        guard let context = JSContext() else {
            finishInit(.failure(LXScriptError.evaluation("JavaScriptCore unavailable")))
            return
        }
        context.name = info.name.isEmpty ? "LX custom source" : info.name
        context.exceptionHandler = { [weak self] _, exception in
            let message = exception?.toString() ?? "Unknown error"
            self?.onLog?("error", message)
            // An exception while the script first runs means it never inited.
            if self?.sources == nil {
                self?.finishInit(.failure(LXScriptError.evaluation(message)))
            }
        }
        self.context = context
        context.setObject(makeNativeBridge(in: context), forKeyedSubscript: "__lx_native" as NSString)
        context.evaluateScript(LXScriptPreload.source)
        guard sources == nil, initContinuation != nil else { return }
        context.evaluateScript(script)
    }

    private func finishInit(_ result: Result<[LXRegisteredSource], Error>) {
        guard let continuation = initContinuation else { return }
        initContinuation = nil
        if case .success(let registered) = result { sources = registered }
        continuation.resume(with: result)
    }

    // MARK: - Native bridge (queue)

    private func makeNativeBridge(in context: JSContext) -> JSValue {
        let bridge = JSValue(newObjectIn: context)!
        // Blocks must reach JavaScriptCore as ObjC block objects; going
        // through `Any` would box them into something JS cannot call.
        func expose(_ name: String, _ block: AnyObject) {
            bridge.setObject(block, forKeyedSubscript: name as NSString)
        }

        let scriptInfoJSON: String = {
            let object: [String: String] = [
                "name": info.name, "description": info.description, "version": info.version,
                "author": info.author, "homepage": info.homepage, "rawScript": script,
            ]
            return String(decoding: (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8), as: UTF8.self)
        }()
        let scriptInfo: @convention(block) () -> String = { scriptInfoJSON }
        expose("scriptInfo", unsafeBitCast(scriptInfo, to: AnyObject.self))

        let log: @convention(block) (String, String) -> Void = { [weak self] level, message in
            self?.onLog?(level, message)
        }
        expose("log", unsafeBitCast(log, to: AnyObject.self))

        let setTimer: @convention(block) (Int, Double) -> Void = { [weak self] id, milliseconds in
            let delay = max(0, milliseconds) / 1000
            self?.queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, !self.isStopped else { return }
                self.context?.objectForKeyedSubscript("__lx_internal")?
                    .invokeMethod("fireTimer", withArguments: [id])
            }
        }
        expose("setTimer", unsafeBitCast(setTimer, to: AnyObject.self))

        let request: @convention(block) (Int, String, String) -> Void = { [weak self] id, url, optionsJSON in
            self?.performRequest(id: id, url: url, optionsJSON: optionsJSON)
        }
        expose("request", unsafeBitCast(request, to: AnyObject.self))

        let cancelRequest: @convention(block) (Int) -> Void = { [weak self] id in
            self?.tasks.removeValue(forKey: id)?.cancel()
        }
        expose("cancelRequest", unsafeBitCast(cancelRequest, to: AnyObject.self))

        let send: @convention(block) (String, String) -> Void = { [weak self] event, json in
            self?.handleSend(event: event, json: json)
        }
        expose("send", unsafeBitCast(send, to: AnyObject.self))

        let resolve: @convention(block) (Int, String) -> Void = { [weak self] callID, json in
            guard let continuation = self?.calls.removeValue(forKey: callID) else { return }
            let value = (try? JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed])) as? [Any]
            guard let value else {
                continuation.resume(throwing: LXScriptError.invalidResult)
                return
            }
            let first = value.first
            continuation.resume(returning: LXValue(raw: first is NSNull ? nil : first))
        }
        expose("resolve", unsafeBitCast(resolve, to: AnyObject.self))

        let reject: @convention(block) (Int, String) -> Void = { [weak self] callID, message in
            self?.calls.removeValue(forKey: callID)?.resume(throwing: LXScriptError.script(message))
        }
        expose("reject", unsafeBitCast(reject, to: AnyObject.self))

        let md5: @convention(block) (String) -> String = { base64 in
            let data = Data(base64Encoded: base64) ?? Data()
            return Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        expose("md5", unsafeBitCast(md5, to: AnyObject.self))

        let randomBytes: @convention(block) (Int) -> String = { count in
            var bytes = [UInt8](repeating: 0, count: max(0, min(count, 1 << 20)))
            _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            return Data(bytes).base64EncodedString()
        }
        expose("randomBytes", unsafeBitCast(randomBytes, to: AnyObject.self))

        let aesEncrypt: @convention(block) (String, String, String, String) -> String? = { data, mode, key, iv in
            LXCrypto.aesEncrypt(
                Data(base64Encoded: data) ?? Data(), mode: mode,
                key: Data(base64Encoded: key) ?? Data(), iv: Data(base64Encoded: iv) ?? Data()
            )?.base64EncodedString()
        }
        expose("aesEncrypt", unsafeBitCast(aesEncrypt, to: AnyObject.self))

        let rsaEncrypt: @convention(block) (String, String) -> String? = { data, key in
            LXCrypto.rsaEncryptRaw(Data(base64Encoded: data) ?? Data(), publicKeyPEM: key)?.base64EncodedString()
        }
        expose("rsaEncrypt", unsafeBitCast(rsaEncrypt, to: AnyObject.self))

        let inflate: @convention(block) (String) -> String? = { data in
            LXCrypto.inflate(Data(base64Encoded: data) ?? Data())?.base64EncodedString()
        }
        expose("inflate", unsafeBitCast(inflate, to: AnyObject.self))

        let deflate: @convention(block) (String) -> String? = { data in
            LXCrypto.deflate(Data(base64Encoded: data) ?? Data())?.base64EncodedString()
        }
        expose("deflate", unsafeBitCast(deflate, to: AnyObject.self))

        return bridge
    }

    private func handleSend(event: String, json: String) {
        let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
        switch event {
        case "inited":
            guard initContinuation != nil else { return }
            let registered = (object["sources"] as? [String: Any] ?? [:]).compactMap { id, value -> LXRegisteredSource? in
                guard let source = value as? [String: Any] else { return nil }
                let type = source["type"] as? String ?? "music"
                guard type == "music" else { return nil }
                return LXRegisteredSource(
                    id: id,
                    name: (source["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? LXPlatform.displayName(for: id),
                    actions: source["actions"] as? [String] ?? [],
                    qualities: source["qualitys"] as? [String] ?? source["qualities"] as? [String] ?? []
                )
            }
            .sorted { LXPlatform.sortKey($0.id) < LXPlatform.sortKey($1.id) }
            finishInit(.success(registered))
        case "updateAlert":
            let log = (object["log"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !log.isEmpty else { return }
            let url = (object["updateUrl"] as? String).flatMap { $0.hasPrefix("http") ? $0 : nil }
            onUpdateAlert?(LXUpdateAlert(log: String(log.prefix(1024)), updateURL: url))
        default:
            break
        }
    }

    private func performRequest(id: Int, url urlString: String, optionsJSON: String) {
        let options = (try? JSONSerialization.jsonObject(with: Data(optionsJSON.utf8))) as? [String: Any] ?? [:]
        guard let url = URL(string: urlString) ?? URL(string: urlString.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? "") else {
            // Never call back into JS while it is still inside `request()`.
            queue.async { [weak self] in
                self?.deliverResponse(id: id, error: "Invalid URL: \(urlString)", response: nil, data: nil)
            }
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = (options["method"] as? String) ?? "GET"
        if let timeout = options["timeout"] as? Double, timeout > 0 {
            request.timeoutInterval = min(timeout / 1000, 60)
        } else {
            request.timeoutInterval = 60
        }
        for (key, value) in options["headers"] as? [String: String] ?? [:] {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let form = options["form"] as? [String: Any] {
            request.httpBody = Data(LXCrypto.formEncoded(form).utf8)
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            }
        } else if let body = options["body"] as? String {
            request.httpBody = Data(body.utf8)
        } else if let body = options["body"] as? [String: Any], let base64 = body["base64"] as? String {
            request.httpBody = Data(base64Encoded: base64)
        }

        let task = session.dataTask(with: request) { [weak self] data, response, error in
            self?.queue.async { [weak self] in
                guard let self, self.tasks.removeValue(forKey: id) != nil else { return }
                self.deliverResponse(id: id, error: error?.localizedDescription, response: response as? HTTPURLResponse, data: data)
            }
        }
        tasks[id] = task
        task.resume()
    }

    private func deliverResponse(id: Int, error: String?, response: HTTPURLResponse?, data: Data?) {
        guard !isStopped, let context else { return }
        var headers: [String: String] = [:]
        for (key, value) in response?.allHeaderFields ?? [:] {
            headers[String(describing: key).lowercased()] = String(describing: value)
        }
        let headersJSON = String(decoding: (try? JSONSerialization.data(withJSONObject: headers)) ?? Data("{}".utf8), as: UTF8.self)
        let data = data ?? Data()
        let statusCode = response?.statusCode ?? 0
        context.objectForKeyedSubscript("__lx_internal")?.invokeMethod("response", withArguments: [
            id,
            error.map { $0 as Any } ?? NSNull(),
            statusCode,
            HTTPURLResponse.localizedString(forStatusCode: statusCode),
            headersJSON,
            String(decoding: data, as: UTF8.self),
            data.base64EncodedString(),
        ])
    }
}

/// LX Music's platform ids and their usual names.
enum LXPlatform {
    static let order = ["wy", "tx", "kw", "kg", "mg"]

    static func displayName(for id: String) -> String {
        switch id {
        case "wy": return String(localized: "网易云音乐")
        case "tx": return String(localized: "QQ音乐")
        case "kw": return String(localized: "酷我音乐")
        case "kg": return String(localized: "酷狗音乐")
        case "mg": return String(localized: "咪咕音乐")
        default: return id
        }
    }

    static func sortKey(_ id: String) -> String {
        if let index = order.firstIndex(of: id) { return "0\(index)" }
        return "1\(id)"
    }
}

/// The byte-level helpers behind `lx.utils`.
enum LXCrypto {
    /// `mode` is LX's cipher name, e.g. `aes-128-cbc` or `aes-128-ecb`. LX
    /// passes it straight to Node, which uses no padding for these modes when
    /// the caller has padded already; PKCS7 is what scripts expect in practice.
    static func aesEncrypt(_ data: Data, mode: String, key: Data, iv: Data) -> Data? {
        let lower = mode.lowercased()
        let ecb = lower.hasSuffix("ecb")
        guard [kCCKeySizeAES128, kCCKeySizeAES192, kCCKeySizeAES256].contains(key.count) else { return nil }
        if !ecb, iv.count != kCCBlockSizeAES128 { return nil }
        var options = CCOptions(kCCOptionPKCS7Padding)
        if ecb { options |= CCOptions(kCCOptionECBMode) }
        var out = Data(count: data.count + kCCBlockSizeAES128)
        var written = 0
        let outCapacity = out.count
        let status = out.withUnsafeMutableBytes { outPtr in
            data.withUnsafeBytes { dataPtr in
                key.withUnsafeBytes { keyPtr in
                    iv.withUnsafeBytes { ivPtr in
                        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), options,
                                keyPtr.baseAddress, key.count, ecb ? nil : ivPtr.baseAddress,
                                dataPtr.baseAddress, data.count, outPtr.baseAddress, outCapacity, &written)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return out.prefix(written)
    }

    /// RSA without padding (Node's `RSA_NO_PADDING`), the way LX encrypts.
    /// The input is left-padded with zeros to the modulus size.
    static func rsaEncryptRaw(_ data: Data, publicKeyPEM: String) -> Data? {
        let base64 = publicKeyPEM
            .components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----") }
            .joined()
            .trimmingCharacters(in: .whitespaces)
        guard let der = Data(base64Encoded: base64) else { return nil }
        let pkcs1 = stripSubjectPublicKeyInfo(der) ?? der
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
        ]
        guard let key = SecKeyCreateWithData(pkcs1 as CFData, attributes as CFDictionary, nil) else { return nil }
        let blockSize = SecKeyGetBlockSize(key)
        guard data.count <= blockSize else { return nil }
        let padded = Data(repeating: 0, count: blockSize - data.count) + data
        return SecKeyCreateEncryptedData(key, .rsaEncryptionRaw, padded as CFData, nil) as Data?
    }

    /// Unwraps an X.509 SubjectPublicKeyInfo to the PKCS#1 key inside, which
    /// is what `SecKeyCreateWithData` wants. Nil when it is not one.
    static func stripSubjectPublicKeyInfo(_ der: Data) -> Data? {
        let bytes = [UInt8](der)
        var index = 0
        func readLength() -> Int? {
            guard index < bytes.count else { return nil }
            let first = Int(bytes[index]); index += 1
            if first < 0x80 { return first }
            let count = first & 0x7f
            guard count > 0, count <= 4, index + count <= bytes.count else { return nil }
            var length = 0
            for _ in 0..<count { length = (length << 8) | Int(bytes[index]); index += 1 }
            return length
        }
        // SEQUENCE { SEQUENCE { algorithm }, BIT STRING { key } }
        guard bytes.first == 0x30 else { return nil }
        index = 1
        guard readLength() != nil, index < bytes.count, bytes[index] == 0x30 else { return nil }
        index += 1
        guard let algorithmLength = readLength() else { return nil }
        index += algorithmLength
        guard index < bytes.count, bytes[index] == 0x03 else { return nil }
        index += 1
        guard let bitStringLength = readLength(), bitStringLength > 1, index + bitStringLength <= bytes.count else { return nil }
        // Skip the "unused bits" byte.
        return Data(bytes[(index + 1)..<(index + bitStringLength)])
    }

    /// zlib (RFC 1950) inflate, as Node's `zlib.inflate`. Raw deflate data
    /// without the zlib wrapper is accepted too.
    static func inflate(_ data: Data) -> Data? {
        var payload = data
        if data.count > 6, data[data.startIndex] & 0x0f == 8,
           (Int(data[data.startIndex]) << 8 | Int(data[data.startIndex + 1])) % 31 == 0 {
            payload = data.dropFirst(2).dropLast(4)
        }
        return try? (payload as NSData).decompressed(using: .zlib) as Data
    }

    /// zlib (RFC 1950) deflate, as Node's `zlib.deflate`.
    static func deflate(_ data: Data) -> Data? {
        guard let raw = try? (data as NSData).compressed(using: .zlib) as Data else { return nil }
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        let adler = (b << 16) | a
        var out = Data([0x78, 0x9c])
        out.append(raw)
        out.append(contentsOf: [UInt8(adler >> 24), UInt8((adler >> 16) & 0xff), UInt8((adler >> 8) & 0xff), UInt8(adler & 0xff)])
        return out
    }

    static func formEncoded(_ form: [String: Any]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._*")
        return form.keys.sorted().map { key in
            let value = form[key].map { "\($0)" } ?? ""
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(encodedKey)=\(encodedValue)"
        }.joined(separator: "&")
    }
}
