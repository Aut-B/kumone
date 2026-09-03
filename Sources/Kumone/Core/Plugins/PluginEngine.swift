import Foundation
import JavaScriptCore
import os

private let log = Logger(subsystem: "sb.moe.kumone", category: "PluginEngine")

enum PluginEngineError: LocalizedError {
    case runtimeNotReady
    case timeout
    case script(String)

    var errorDescription: String? {
        switch self {
        case .runtimeNotReady: return String(localized: "插件引擎未就绪")
        case .timeout: return String(localized: "插件调用超时")
        case .script(let message): return message
        }
    }
}

/// Hosts the MusicFree-compatible plugin sandbox in JavaScriptCore.
///
/// One JSContext runs every plugin (same as the upstream RN engine, where all
/// plugins share one Hermes global). All JS access is serialized on `queue`;
/// async JS calls are completed by draining JSC's microtask queue with empty
/// `evaluateScript` checkpoints while URLSession callbacks hop onto the same
/// queue — the pump never blocks the queue, so callbacks can't deadlock it.
final class PluginEngine {
    static let shared = PluginEngine()

    private let context: JSContext
    private let queue = DispatchQueue(label: "sb.moe.kumone.plugin-engine", qos: .userInitiated)
    private let session: URLSession
    private var runtimeLoaded = false

    /// Where per-plugin userVariables JSON lives. Set by PluginManager before use.
    private var variablesDirectory: URL?

    private final class CallState {
        var result: String?
        var done = false
    }

    private init() {
        context = JSContext()!
        context.name = "KumonePluginEngine"
        context.exceptionHandler = { _, exception in
            log.error("JS exception: \(exception?.toString() ?? "unknown", privacy: .public)")
        }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)
        loadRuntime()
    }

    // MARK: - Runtime setup

    private static let runtimeFiles = [
        "crypto-js.js",
        "dayjs.js",
        "qs.js",
        "he.js",
        "big-integer.js",
        "__mf_lib_cheerio.js",
        "__mf_lib_webdav.js",
        "__mf_lib_whatwgurl.js",
        "__mf_lib_compareVersions.js",
        "kumone-plugin-runtime.js",
    ]

    private func loadRuntime() {
        queue.sync {
            for file in Self.runtimeFiles {
                guard let url = Bundle.module.url(forResource: file, withExtension: nil),
                      let code = try? String(contentsOf: url, encoding: .utf8) else {
                    log.error("missing JS resource: \(file, privacy: .public)")
                    continue
                }
                context.evaluateScript(code, withSourceURL: url)
            }

            // Native bridge (blocks are callable from JS)
            let httpRequest: @convention(block) (String, JSValue) -> Void = { [weak self] optionsJSON, completion in
                self?.handleHTTPRequest(optionsJSON: optionsJSON, completion: completion)
            }
            context.setObject(httpRequest, forKeyedSubscript: "__mf_nativeHttpRequest" as NSString)

            let getVariables: @convention(block) (String) -> [String: Any] = { [weak self] platform in
                self?.storedVariables(for: platform) ?? [:]
            }
            context.setObject(getVariables, forKeyedSubscript: "__mf_nativeGetUserVariables" as NSString)

            let setVariables: @convention(block) (String, String) -> Void = { [weak self] platform, json in
                self?.storeVariables(json, for: platform)
            }
            context.setObject(setVariables, forKeyedSubscript: "__mf_nativeSetUserVariables" as NSString)

            let logLine: @convention(block) (String, String) -> Void = { level, message in
                log.debug("[plugin:\(level, privacy: .public)] \(message, privacy: .public)")
            }
            context.setObject(logLine, forKeyedSubscript: "__mf_nativeLog" as NSString)

            context.evaluateScript("""
            globalThis.__mf_native = {
              httpRequest: function (optionsJSON, cb) { __mf_nativeHttpRequest(optionsJSON, cb); },
              getUserVariables: function (platform) { return __mf_nativeGetUserVariables(platform); },
              setUserVariables: function (platform, json) { __mf_nativeSetUserVariables(platform, json); },
            };
            """)
            runtimeLoaded = true
            log.info("plugin runtime loaded")
        }
    }

    // MARK: - Storage hooks

    func setVariablesDirectory(_ url: URL) {
        queue.sync { variablesDirectory = url }
    }

    private func storedVariables(for platform: String) -> [String: Any] {
        guard let dir = variablesDirectory else { return [:] }
        let url = dir.appendingPathComponent(platform + ".json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return obj
    }

    private func storeVariables(_ json: String, for platform: String) {
        guard let dir = variablesDirectory else { return }
        let url = dir.appendingPathComponent(platform + ".json")
        if let data = json.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data),
           let serialized = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            try? serialized.write(to: url, options: .atomic)
        }
    }

    // MARK: - HTTP bridge

    private func handleHTTPRequest(optionsJSON: String, completion: JSValue) {
        guard let data = optionsJSON.data(using: .utf8),
              let options = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let urlString = options["url"] as? String,
              let url = URL(string: urlString) else {
            respond(completion, withError: "invalid request options")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = ((options["method"] as? String) ?? "GET").uppercased()
        if let headers = options["headers"] as? [String: String] {
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }
        if let body = options["data"] as? String {
            request.httpBody = body.data(using: .utf8)
        }
        let timeout = (options["timeout"] as? NSNumber)?.doubleValue ?? 5

        let task = session.dataTask(with: request) { [weak self] data, response, error in
            let result: [String: Any]
            if let error {
                result = ["error": error.localizedDescription]
            } else if let http = response as? HTTPURLResponse {
                var headers: [String: String] = [:]
                for (key, value) in http.allHeaderFields {
                    if let k = key as? String, let v = value as? String {
                        headers[k.lowercased()] = v
                    }
                }
                var body = ""
                if let data,
                   let decoded = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {
                    body = decoded
                }
                result = [
                    "status": http.statusCode,
                    "statusText": HTTPURLResponse.localizedString(forStatusCode: http.statusCode),
                    "headers": headers,
                    "body": body,
                ]
            } else {
                result = ["error": "invalid response"]
            }
            let json = (try? JSONSerialization.data(withJSONObject: result)).flatMap {
                String(data: $0, encoding: .utf8)
            } ?? "{}"
            self?.queue.async {
                completion.call(withArguments: [json])
            }
        }
        task.resume()
        _ = timeout
    }

    private func respond(_ completion: JSValue, withError message: String) {
        queue.async {
            completion.call(withArguments: ["{\"error\":\"\(message)\"}"])
        }
    }

    // MARK: - JS evaluation

    /// Renders a Swift string as a JS string literal.
    /// NOTE: must NOT use JSONSerialization here — a bare String is not a
    /// valid JSON top-level type and Foundation raises an unbridgeable
    /// NSException ("Invalid top-level type in JSON write") that crashes
    /// the app when it unwinds through the JS block boundary.
    private func jsString(_ string: String) -> String {
        var output = "\""
        for scalar in string.unicodeScalars {
            switch scalar.value {
            case 0x22: output += "\\\""   // "
            case 0x5C: output += "\\\\"   // backslash
            case 0x0A: output += "\\n"
            case 0x0D: output += "\\r"
            case 0x09: output += "\\t"
            case 0x08: output += "\\b"
            case 0x0C: output += "\\f"
            case 0x2028: output += "\\u2028"
            case 0x2029: output += "\\u2029"
            case 0x00 ... 0x1F: output += String(format: "\\u%04x", scalar.value)
            default: output.unicodeScalars.append(scalar)
            }
        }
        output += "\""
        return output
    }

    /// Evaluates `script` with a completion callback named `__CALLBACK__`,
    /// pumping JSC's microtask queue until the callback fires or timeout hits.
    private func evaluateWithCallback(_ script: String, timeout: TimeInterval) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            queue.async { [self] in
                guard runtimeLoaded else {
                    continuation.resume(throwing: PluginEngineError.runtimeNotReady)
                    return
                }
                let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
                let callbackName = "__mf_done_\(token)"
                let state = CallState()
                let callback: @convention(block) (String) -> Void = { json in
                    state.result = json
                    state.done = true
                }
                context.setObject(callback, forKeyedSubscript: callbackName as NSString)
                let deadline = Date().addingTimeInterval(timeout)

                context.evaluateScript(script.replacingOccurrences(of: "__CALLBACK__", with: callbackName))

                func pump() {
                    if state.done {
                        context.setObject(nil, forKeyedSubscript: callbackName as NSString)
                        if let result = state.result {
                            continuation.resume(returning: result)
                        } else {
                            continuation.resume(throwing: PluginEngineError.script("empty callback result"))
                        }
                        return
                    }
                    if Date() > deadline {
                        context.setObject(nil, forKeyedSubscript: callbackName as NSString)
                        continuation.resume(throwing: PluginEngineError.timeout)
                        return
                    }
                    // Empty evaluate = a JSC microtask checkpoint; advances pending promises.
                    _ = context.evaluateScript("void 0")
                    queue.asyncAfter(deadline: .now() + .milliseconds(2), execute: pump)
                }
                pump()
            }
        }
    }

    // MARK: - Public API

    /// Mounts plugin code, returning its declared platform and userVariables.
    func mount(code: String, installName: String) async throws -> PluginMountResult {
        let script = "__mf_mountPlugin(\(jsString(code)), \(jsString(installName)))"
        let resultJSON = try await evaluateWithCallback(script, timeout: 12)
        guard let data = resultJSON.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw PluginEngineError.script("mount result parse failed")
        }
        guard object["ok"] as? Bool == true,
              let platform = object["platform"] as? String, !platform.isEmpty else {
            throw PluginEngineError.script((object["error"] as? String) ?? String(localized: "插件加载失败"))
        }
        let variables = (object["userVariables"] as? [[String: Any]]) ?? []
        return PluginMountResult(platform: platform, userVariables: variables)
    }

    /// Calls `method(args...)` on the mounted plugin. Returns the JSON value.
    func call(platform: String, method: String, args: [Any], timeout: TimeInterval = 25) async throws -> Any? {
        let argsData = (try? JSONSerialization.data(withJSONObject: args)) ?? Data("[]".utf8)
        let argsJSON = String(data: argsData, encoding: .utf8) ?? "[]"
        let script = "__mf_callNamed(\(jsString(platform)), \(jsString(method)), \(jsString(argsJSON)), __CALLBACK__)"
        let resultJSON = try await evaluateWithCallback(script, timeout: timeout)
        guard let data = resultJSON.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw PluginEngineError.script("call result parse failed")
        }
        guard object["ok"] as? Bool == true else {
            throw PluginEngineError.script((object["error"] as? String) ?? String(localized: "插件返回错误"))
        }
        return object["value"]
    }
}
