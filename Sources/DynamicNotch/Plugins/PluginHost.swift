import Foundation
import JavaScriptCore

/// What a plugin can do to the rest of the app. All methods are called on the plugin's own queue;
/// the implementation is responsible for hopping to the main thread.
protocol PluginBridge: AnyObject {
    func toast(plugin: PluginManifest, request: ToastRequest)
    func card(plugin: PluginManifest, request: CardRequest)
    func activity(plugin: PluginManifest, request: ActivityRequest)
    func endActivity(plugin: PluginManifest, id: String)
    func timer(plugin: PluginManifest, request: TimerRequest)
    func mediaState() -> [String: Any]
    func mediaCommand(_ action: String, seconds: Double?)
    func volume() -> Double?
    func setVolume(_ level: Double)
    func open(_ url: URL)
    func log(plugin: PluginManifest, level: String, message: String)
}

/// Runs one plugin in its own JavaScriptCore context on its own serial queue, so a slow or broken
/// plugin can never block the notch or another plugin.
final class PluginHost {
    static let maxScriptBytes = 512 * 1024
    static let maxTimers = 20
    static let maxActivitiesPerPlugin = 4
    static let maxPendingEvents = 100

    let manifest: PluginManifest
    let directory: URL
    let permissions: Set<PluginPermission>
    weak var bridge: PluginBridge?

    private let queue: DispatchQueue
    private let storage: PluginStorage
    private var context: JSContext?
    private var timers: [Int: DispatchSourceTimer] = [:]
    private var nextTimerID = 1
    private var toastLimiter = RateLimiter(limit: 8, window: 10)
    private var activityIDs: Set<String> = []
    private var httpInFlight = 0
    private var shellInFlight = 0
    private var started = false

    private let pendingLock = NSLock()
    private var pending = 0

    init(manifest: PluginManifest, directory: URL, permissions: Set<PluginPermission>, storageURL: URL) {
        self.manifest = manifest
        self.directory = directory
        self.permissions = permissions
        self.storage = PluginStorage(url: storageURL)
        self.queue = DispatchQueue(label: "dynamicnotch.plugin.\(manifest.id)", qos: .utility)
    }

    // MARK: Lifecycle

    func start(completion: ((Result<Void, Error>) -> Void)? = nil) {
        queue.async { [self] in
            do {
                try boot()
                completion?(.success(()))
            } catch {
                log("error", "\(error)")
                stopOnQueue()
                completion?(.failure(error))
            }
        }
    }

    func stop() { queue.async { [self] in stopOnQueue() } }

    private func stopOnQueue() {
        timers.values.forEach { $0.cancel() }
        timers.removeAll()
        context = nil
        started = false
    }

    /// Blocks until everything queued so far has run (tests).
    func drain() { queue.sync {} }

    private struct LoadError: Error, CustomStringConvertible {
        let description: String
    }

    private func boot() throws {
        let scriptURL = directory.appendingPathComponent(manifest.main).standardizedFileURL
        // The script has to stay inside the plugin folder, whatever symlinks are in the way.
        guard scriptURL.resolvingSymlinksInPath().path.hasPrefix(directory.resolvingSymlinksInPath().path + "/") else {
            throw LoadError(description: "main script is outside the plugin folder")
        }
        guard let data = try? Data(contentsOf: scriptURL), data.count <= Self.maxScriptBytes,
              let source = String(data: data, encoding: .utf8) else {
            throw LoadError(description: "cannot read \(manifest.main) (missing, not UTF-8 or larger than \(Self.maxScriptBytes / 1024) KB)")
        }

        guard let context = JSContext() else { throw LoadError(description: "no JavaScript context") }
        context.name = manifest.name
        context.exceptionHandler = { [weak self] _, exception in
            let message = exception?.toString() ?? "unknown error"
            let line = exception?.objectForKeyedSubscript("line")?.toInt32() ?? 0
            self?.log("error", line > 0 ? "\(message) (line \(line))" : message)
        }
        self.context = context
        installNatives(in: context)
        context.evaluateScript(Self.prelude, withSourceURL: URL(string: "notch://prelude.js"))
        context.evaluateScript(source, withSourceURL: scriptURL)
        started = true
        emitOnQueue("launch", [:])
    }

    // MARK: Events

    func emit(_ event: String, _ payload: [String: Any]) {
        pendingLock.lock()
        guard pending < Self.maxPendingEvents else { pendingLock.unlock(); return }   // a stuck plugin must not pile up work
        pending += 1
        pendingLock.unlock()
        queue.async { [self] in
            pendingLock.lock(); pending -= 1; pendingLock.unlock()
            emitOnQueue(event, payload)
        }
    }

    private func emitOnQueue(_ event: String, _ payload: [String: Any]) {
        guard started, let notch = context?.objectForKeyedSubscript("notch") else { return }
        notch.invokeMethod("__emit", withArguments: [event, payload])
    }

    // MARK: Logging and errors

    private func log(_ level: String, _ message: String) {
        bridge?.log(plugin: manifest, level: level, message: String(message.prefix(2000)))
    }

    private func fail(_ message: String) {
        guard let context = JSContext.current() ?? self.context else { return }
        context.exception = JSValue(newErrorFromMessage: message, in: context)
    }

    private func requires(_ permission: PluginPermission) -> Bool {
        guard permissions.contains(permission) else {
            fail("permission \"\(permission.rawValue)\" is required (add it to plugin.json and approve it)")
            return false
        }
        return true
    }

    // MARK: Native API

    private func installNatives(in context: JSContext) {
        let global = context.globalObject!

        // console
        let console = JSValue(newObjectIn: context)!
        for level in ["log", "info", "warn", "error"] {
            let block: @convention(block) () -> Void = { [weak self] in
                let args = JSContext.currentArguments() as? [JSValue] ?? []
                self?.log(level == "log" ? "info" : level, args.map { $0.toString() ?? "" }.joined(separator: " "))
            }
            console.setObject(block, forKeyedSubscript: level as NSString)
        }
        global.setObject(console, forKeyedSubscript: "console" as NSString)

        let notch = JSValue(newObjectIn: context)!
        global.setObject(notch, forKeyedSubscript: "notch" as NSString)
        notch.setObject("2", forKeyedSubscript: "apiVersion" as NSString)
        notch.setObject(["id": manifest.id, "name": manifest.name, "version": manifest.version,
                         "permissions": manifest.permissions], forKeyedSubscript: "plugin" as NSString)

        // Showing things
        let toast: @convention(block) (JSValue) -> Void = { [weak self] value in
            guard let self, let json = value.toDictionary() as? [String: Any] else { return self?.fail("toast expects an object") ?? () }
            guard self.toastLimiter.allow() else { return self.log("warn", "toast dropped: more than 8 in 10 seconds") }
            do { self.bridge?.toast(plugin: self.manifest, request: try ToastRequest.parse(json, defaultDuration: 2.2)) }
            catch let error as APIError { self.fail(error.message) } catch { self.fail("\(error)") }
        }
        notch.setObject(toast, forKeyedSubscript: "toast" as NSString)

        let card: @convention(block) (JSValue) -> Void = { [weak self] value in
            guard let self, let json = value.toDictionary() as? [String: Any] else { return self?.fail("card expects an object") ?? () }
            guard self.toastLimiter.allow() else { return self.log("warn", "card dropped: more than 8 in 10 seconds") }
            do { self.bridge?.card(plugin: self.manifest, request: try CardRequest.parse(json, defaultDuration: 5)) }
            catch let error as APIError { self.fail(error.message) } catch { self.fail("\(error)") }
        }
        notch.setObject(card, forKeyedSubscript: "card" as NSString)

        let activity: @convention(block) (JSValue) -> Void = { [weak self] value in
            guard let self, let json = value.toDictionary() as? [String: Any] else { return self?.fail("activity expects an object") ?? () }
            do {
                let request = try ActivityRequest.parse(json)
                if !self.activityIDs.contains(request.id), self.activityIDs.count >= Self.maxActivitiesPerPlugin {
                    return self.fail("a plugin can show at most \(Self.maxActivitiesPerPlugin) activities at once")
                }
                self.activityIDs.insert(request.id)
                self.bridge?.activity(plugin: self.manifest, request: request)
            } catch let error as APIError { self.fail(error.message) } catch { self.fail("\(error)") }
        }
        notch.setObject(activity, forKeyedSubscript: "activity" as NSString)

        let endActivity: @convention(block) (String) -> Void = { [weak self] id in
            guard let self else { return }
            self.activityIDs.remove(id)
            self.bridge?.endActivity(plugin: self.manifest, id: id)
        }
        notch.setObject(endActivity, forKeyedSubscript: "endActivity" as NSString)

        let timer: @convention(block) (JSValue) -> Void = { [weak self] value in
            guard let self, let json = value.toDictionary() as? [String: Any] else { return self?.fail("timer expects an object") ?? () }
            do { self.bridge?.timer(plugin: self.manifest, request: try TimerRequest.parse(json)) }
            catch let error as APIError { self.fail(error.message) } catch { self.fail("\(error)") }
        }
        notch.setObject(timer, forKeyedSubscript: "timer" as NSString)

        // Media and system
        let media = JSValue(newObjectIn: context)!
        notch.setObject(media, forKeyedSubscript: "media" as NSString)
        let mediaState: @convention(block) () -> [String: Any] = { [weak self] in self?.bridge?.mediaState() ?? [:] }
        media.setObject(mediaState, forKeyedSubscript: "state" as NSString)
        for (name, action) in [("toggle", "toggle"), ("next", "next"), ("previous", "previous")] {
            let block: @convention(block) () -> Void = { [weak self] in
                guard let self, self.requires(.control) else { return }
                self.bridge?.mediaCommand(action, seconds: nil)
            }
            media.setObject(block, forKeyedSubscript: name as NSString)
        }
        let seek: @convention(block) (Double) -> Void = { [weak self] seconds in
            guard let self, self.requires(.control) else { return }
            guard seconds.isFinite, seconds >= 0 else { return self.fail("seek needs a number of seconds >= 0") }
            self.bridge?.mediaCommand("seek", seconds: seconds)
        }
        media.setObject(seek, forKeyedSubscript: "seek" as NSString)

        let system = JSValue(newObjectIn: context)!
        notch.setObject(system, forKeyedSubscript: "system" as NSString)
        let volume: @convention(block) () -> Any = { [weak self] in self?.bridge?.volume() ?? NSNull() }
        system.setObject(volume, forKeyedSubscript: "volume" as NSString)
        let setVolume: @convention(block) (Double) -> Void = { [weak self] level in
            guard let self, self.requires(.control) else { return }
            guard level.isFinite else { return self.fail("setVolume needs a number between 0 and 1") }
            self.bridge?.setVolume(min(max(level, 0), 1))
        }
        system.setObject(setVolume, forKeyedSubscript: "setVolume" as NSString)

        let open: @convention(block) (String) -> Void = { [weak self] text in
            guard let self, self.requires(.control) else { return }
            guard let safe = JSONField.safeURL(text), let url = URL(string: safe) else {
                return self.fail("openURL only opens http, https, mailto and system settings links")
            }
            self.bridge?.open(url)
        }
        notch.setObject(open, forKeyedSubscript: "openURL" as NSString)

        installHidden(in: context, global: global)
    }

    /// Helpers the JavaScript prelude builds the public API from.
    private func installHidden(in context: JSContext, global: JSValue) {
        let setTimer: @convention(block) (JSValue, Double, Bool) -> Int = { [weak self] fn, ms, repeating in
            guard let self else { return 0 }
            guard self.timers.count < Self.maxTimers else { self.fail("too many timers (max \(Self.maxTimers))"); return 0 }
            let id = self.nextTimerID
            self.nextTimerID += 1
            let interval = max(ms.isFinite ? ms : 0, 50) / 1000
            let source = DispatchSource.makeTimerSource(queue: self.queue)
            source.schedule(deadline: .now() + interval, repeating: repeating ? interval : .infinity)
            source.setEventHandler { [weak self, weak source] in
                _ = fn.call(withArguments: [])
                if !repeating, let self { self.timers[id]?.cancel(); self.timers[id] = nil } else { _ = source }
            }
            self.timers[id] = source
            source.resume()
            return id
        }
        global.setObject(setTimer, forKeyedSubscript: "__timer" as NSString)

        let clearTimer: @convention(block) (Int) -> Void = { [weak self] id in
            self?.timers[id]?.cancel()
            self?.timers[id] = nil
        }
        global.setObject(clearTimer, forKeyedSubscript: "__clearTimer" as NSString)

        let storageGet: @convention(block) (String) -> Any = { [weak self] key in self?.storage.get(key) ?? NSNull() }
        global.setObject(storageGet, forKeyedSubscript: "__storageGet" as NSString)
        let storageSet: @convention(block) (String, JSValue) -> Void = { [weak self] key, value in
            guard let self else { return }
            let json = value.isNull || value.isUndefined ? nil : value.toString()
            if !self.storage.set(key, json: json) { self.fail("storage is full (limit \(PluginStorage.maxBytes / 1024) KB)") }
        }
        global.setObject(storageSet, forKeyedSubscript: "__storageSet" as NSString)

        global.setObject(permissions.contains(.network), forKeyedSubscript: "__hasNetwork" as NSString)
        global.setObject(permissions.contains(.shell), forKeyedSubscript: "__hasShell" as NSString)

        let http: @convention(block) (JSValue, JSValue) -> Void = { [weak self] options, callback in
            guard let self, self.requires(.network) else { return }
            self.performHTTP(options: options, callback: callback)
        }
        global.setObject(http, forKeyedSubscript: "__http" as NSString)

        let shell: @convention(block) (String, JSValue, JSValue) -> Void = { [weak self] path, args, callback in
            guard let self, self.requires(.shell) else { return }
            self.performShell(path: path, args: args, callback: callback)
        }
        global.setObject(shell, forKeyedSubscript: "__shell" as NSString)
    }

    // MARK: Network and commands

    private func performHTTP(options: JSValue, callback: JSValue) {
        guard let json = options.toDictionary() as? [String: Any], let text = json["url"] as? String,
              let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return fail("http needs a url starting with http:// or https://")
        }
        guard httpInFlight < 6 else { return fail("too many requests at once") }
        var request = URLRequest(url: url, timeoutInterval: 15)
        let method = ((json["method"] as? String) ?? "GET").uppercased()
        guard ["GET", "POST", "PUT", "PATCH", "DELETE"].contains(method) else { return fail("unsupported method \(method)") }
        request.httpMethod = method
        for (key, value) in (json["headers"] as? [String: Any]) ?? [:] { if let v = value as? String { request.setValue(v, forHTTPHeaderField: key) } }
        if let body = json["body"] as? String { request.httpBody = Data(body.utf8) }

        httpInFlight += 1
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            self?.queue.async {
                guard let self else { return }
                self.httpInFlight -= 1
                guard self.started else { return }
                if let error { _ = callback.call(withArguments: [error.localizedDescription]); return }
                let http = response as? HTTPURLResponse
                let body = String(data: (data ?? Data()).prefix(1_000_000), encoding: .utf8) ?? ""
                var headers: [String: String] = [:]
                for (k, v) in http?.allHeaderFields ?? [:] { if let k = k as? String, let v = v as? String { headers[k.lowercased()] = v } }
                _ = callback.call(withArguments: [NSNull(), ["status": http?.statusCode ?? 0, "body": body, "headers": headers]])
            }
        }.resume()
    }

    private func performShell(path: String, args: JSValue, callback: JSValue) {
        guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else {
            return fail("shell.run needs the absolute path of an executable, for example /usr/bin/say")
        }
        guard shellInFlight < 3 else { return fail("too many commands running at once") }
        let arguments = (args.toArray() as? [Any])?.compactMap { $0 as? String } ?? []
        shellInFlight += 1

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            var result: [String: Any] = ["code": -1, "stdout": "", "stderr": ""]
            var failure: String?
            do {
                try process.run()
                let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: killer)
                let stdout = out.fileHandleForReading.readDataToEndOfFile()
                let stderr = err.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                killer.cancel()
                result = ["code": Int(process.terminationStatus),
                          "stdout": String(data: stdout.prefix(256 * 1024), encoding: .utf8) ?? "",
                          "stderr": String(data: stderr.prefix(64 * 1024), encoding: .utf8) ?? ""]
            } catch { failure = error.localizedDescription }

            self?.queue.async {
                guard let self else { return }
                self.shellInFlight -= 1
                guard self.started else { return }
                if let failure { _ = callback.call(withArguments: [failure]) } else { _ = callback.call(withArguments: [NSNull(), result]) }
            }
        }
    }

    // MARK: JavaScript prelude

    /// Builds the friendly parts of the API (events, timers, storage, fetch) on top of the native helpers.
    static let prelude = """
    (function (global) {
      'use strict';
      var handlers = {};
      var notch = global.notch;
      notch.on = function (event, fn) {
        if (typeof fn !== 'function') throw new TypeError('notch.on needs a function');
        (handlers[event] = handlers[event] || []).push(fn);
      };
      notch.off = function (event, fn) { handlers[event] = (handlers[event] || []).filter(function (h) { return h !== fn; }); };
      notch.__emit = function (event, payload) {
        (handlers[event] || []).slice().forEach(function (fn) {
          try { fn(payload); } catch (err) { console.error(String(err) + (err && err.stack ? '\\n' + err.stack : '')); }
        });
      };
      global.setTimeout = function (fn, ms) { return __timer(fn, ms || 0, false); };
      global.setInterval = function (fn, ms) { return __timer(fn, ms || 0, true); };
      global.clearTimeout = global.clearInterval = function (id) { __clearTimer(id); };
      notch.storage = {
        get: function (key) { var v = __storageGet(String(key)); return v === null ? undefined : JSON.parse(v); },
        set: function (key, value) { __storageSet(String(key), value === undefined ? null : JSON.stringify(value)); },
        remove: function (key) { __storageSet(String(key), null); }
      };
      if (__hasNetwork) {
        notch.http = {
          request: function (options, callback) { __http(options, callback); },
          get: function (url, callback) { __http({ url: url }, callback); }
        };
        notch.fetch = function (url, options) {
          return new Promise(function (resolve, reject) {
            __http(Object.assign({ url: url }, options || {}), function (err, res) {
              if (err) { reject(new Error(err)); return; }
              resolve({
                ok: res.status >= 200 && res.status < 300, status: res.status, headers: res.headers,
                text: function () { return Promise.resolve(res.body); },
                json: function () { return Promise.resolve(JSON.parse(res.body)); }
              });
            });
          });
        };
      }
      if (__hasShell) {
        notch.shell = { run: function (path, args, callback) { __shell(path, args || [], callback); } };
      }
    })(this);
    """
}
