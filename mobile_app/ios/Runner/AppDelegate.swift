import Flutter
import UIKit
import Network
import NetworkExtension
import Darwin
import UniformTypeIdentifiers

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate, UIDocumentPickerDelegate, URLSessionTaskDelegate {
  private var academicSessions: [Int: URLSession] = [:]
  private var channels: [FlutterMethodChannel] = []
  private var pendingSave: FlutterResult?
  private var exportURL: URL?
  private var joiningStudent = false
  private let session: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.allowsCellularAccess = false
    config.timeoutIntervalForRequest = 25
    return URLSession(configuration: config)
  }()

  override func application(_ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "IosAdapters") else { return }
    for suffix in ["network", "enterprise", "ios"] {
      let channel = FlutterMethodChannel(name: "com.xmum.attendance_assistant/\(suffix)", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { [weak self] call, result in
        self?.handle(suffix, call, result)
      }
      channels.append(channel)
    }
  }
  private func wifiIP() -> String? {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0 else { return nil }
    defer { freeifaddrs(head) }
    var cursor = head
    while let node = cursor {
      let row = node.pointee
      if String(cString: row.ifa_name) == "en0", let addr = row.ifa_addr,
         addr.pointee.sa_family == UInt8(AF_INET) {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host,
          socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
          return String(cString: host)
        }
      }
      cursor = row.ifa_next
    }
    return nil
  }
  private func handle(_ suffix: String, _ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    if suffix == "ios", call.method == "releaseStudent5g" {
      NEHotspotConfigurationManager.shared.getConfiguredSSIDs { ssids in
        DispatchQueue.main.async {
          if ssids.contains("Student-5G") {
            NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: "Student-5G")
          }
          result(nil)
        }
      }
      return
    }
    if suffix == "ios", call.method == "connectStudent5g" {
      guard !joiningStudent else {
        result(FlutterError(code: "NETWORK_BUSY", message: "正在连接 Student-5G，请稍候", details: nil)); return
      }
      joiningStudent = true
      guard let args = call.arguments as? [String: Any],
        args["forceReconfigure"] as? Bool == true,
        let username = args["username"] as? String, !username.isEmpty,
        let password = args["password"] as? String, !password.isEmpty else {
        joiningStudent = false
        result(FlutterError(code: "NETWORK_PASSWORD_MISSING", message: "请填写 Campus ID 和校园网密码", details: nil)); return
      }
      replaceStudent5g(username: username, password: password, result: result)
      return
    }
    if suffix == "ios", call.method == "httpClose" {
      if let args = call.arguments as? [String: Any], let id = args["session"] as? Int {
        academicSessions.removeValue(forKey: id)?.invalidateAndCancel()
      }
      result(nil); return
    }
    if suffix == "ios", call.method == "http" {
      guard let args = call.arguments as? [String: Any], let id = args["session"] as? Int,
        let address = args["url"] as? String, let url = URL(string: address),
        url.scheme == "https", url.user == nil, url.password == nil,
        url.port == nil || url.port == 443,
        ["cas.xmu.edu.my", "acad.xmu.edu.my", "ac.xmu.edu.my"].contains(url.host ?? ""),
        let method = args["method"] as? String, ["GET", "POST"].contains(method),
        let ip = wifiIP(), ip.hasPrefix("10.") else {
        result(FlutterError(code: "NETWORK_ERROR", message: "请连接校园 Wi-Fi 后重试", details: nil)); return
      }
      let active: URLSession
      if let existing = academicSessions[id] { active = existing }
      else {
        let config = URLSessionConfiguration.ephemeral
        config.allowsCellularAccess = false
        config.timeoutIntervalForRequest = 25
        active = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        academicSessions[id] = active
      }
      var request = URLRequest(url: url)
      request.httpMethod = method
      request.allowsCellularAccess = false
      request.httpBody = (args["body"] as? String)?.data(using: .utf8)
      request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
      request.setValue("XMUMAttendanceAssistant/0.7.11 iOS", forHTTPHeaderField: "User-Agent")
      for (key, value) in args["headers"] as? [String: String] ?? [:] { request.setValue(value, forHTTPHeaderField: key) }
      active.dataTask(with: request) { data, response, error in
        DispatchQueue.main.async {
          guard error == nil, self.wifiIP() == ip, let http = response as? HTTPURLResponse,
            let data = data, data.count <= 8 * 1024 * 1024,
            let text = String(data: data, encoding: .utf8) else {
            result(FlutterError(code: "NETWORK_ERROR", message: "校园 Wi-Fi 请求失败或地址已变化", details: nil)); return
          }
          var reply: [String: Any] = ["status": http.statusCode, "body": text]
          if let location = http.value(forHTTPHeaderField: "Location") { reply["location"] = location }
          result(reply)
        }
      }.resume()
      return
    }
    if suffix == "ios", call.method == "save" {
      guard pendingSave == nil else { result(FlutterError(code: "BUSY", message: "文件窗口已打开", details: nil)); return }
      guard let args = call.arguments as? [String: Any], let bytes = args["bytes"] as? FlutterStandardTypedData,
        bytes.data.count <= 4 * 1024 * 1024 else {
        result(FlutterError(code: "INVALID_ARCHIVE", message: "文件无效", details: nil)); return
      }
      let name = URL(fileURLWithPath: args["name"] as? String ?? "accounts.xmumaccounts").lastPathComponent
      let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      do {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try bytes.data.write(to: url, options: .atomic)
        guard let root = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
          .flatMap({ $0.windows }).first(where: { $0.isKeyWindow })?.rootViewController else {
          try? FileManager.default.removeItem(at: folder)
          result(FlutterError(code: "FILE_UI", message: "无法打开文件窗口", details: nil)); return
        }
        var presenter = root
        while let presented = presenter.presentedViewController { presenter = presented }
        pendingSave = result
        exportURL = url
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.delegate = self
        presenter.present(picker, animated: true)
      } catch { result(FlutterError(code: "FILE_SAVE", message: "无法导出文件", details: nil)) }
      return
    }
    if suffix == "enterprise" {
      if call.method == "preferences" { result(["mode": "student5g", "phase2": "MSCHAPV2"]); return }
      result(FlutterError(code: "IOS_MANUAL_WIFI", message: "请在 iPhone 设置中连接校园 Wi-Fi", details: nil)); return
    }
    guard suffix == "network" else { result(FlutterMethodNotImplemented); return }
    if call.method == "release" { result(nil); return }
    guard let ip = wifiIP(), ip.hasPrefix("10.") else {
      result(FlutterError(code: "NETWORK_WIFI", message: "请先在系统设置连接 Student（需要 10.x 地址）", details: nil)); return
    }
    if call.method == "bind" || call.method == "activate" { result(call.method == "bind" ? ip : nil); return }
    var components = URLComponents(string: "https://srun.xmu.edu.my")!
    if call.method == "portal" { components.path = "/srun_portal_phone" }
    else if call.method == "get", let args = call.arguments as? [String: Any],
      let path = args["path"] as? String,
      ["/cgi-bin/rad_user_info", "/cgi-bin/rad_user_dm", "/cgi-bin/srun_portal", "/cgi-bin/get_challenge", "/v1/srun_portal_online"].contains(path) {
      components.path = path
      let params = args["params"] as? [String: String] ?? [:]
      components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
      if path.hasPrefix("/cgi-bin/") { components.queryItems?.append(URLQueryItem(name: "callback", value: "campusFlow")) }
    } else {
      result(FlutterError(code: "IOS_MANUAL_WIFI", message: "请在系统设置和学校网页完成网络认证", details: nil)); return
    }
    var request = URLRequest(url: components.url!)
    request.allowsCellularAccess = false
    request.setValue("https://srun.xmu.edu.my/srun_portal_phone", forHTTPHeaderField: "Referer")
    session.dataTask(with: request) { data, response, error in
      DispatchQueue.main.async {
        guard error == nil, self.wifiIP() == ip, let http = response as? HTTPURLResponse,
          http.url?.host == "srun.xmu.edu.my", http.statusCode == 200,
          let data = data, data.count <= 4 * 1024 * 1024,
          let text = String(data: data, encoding: .utf8) else {
          result(FlutterError(code: "NETWORK_REQUEST", message: "校园 Wi-Fi 请求失败或地址已变化", details: nil)); return
        }
        result(text)
      }
    }.resume()
  }
  // Updating an existing enterprise profile can retain its old identity.
  // Remove only our own profile and wait for its association to end before
  // applying a completely new identity/password pair.
  private func replaceStudent5g(username: String, password: String, result: @escaping FlutterResult) {
    NEHotspotConfigurationManager.shared.getConfiguredSSIDs { ssids in
      DispatchQueue.main.async {
        if ssids.contains("Student-5G") {
          NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: "Student-5G")
          self.waitForStudentRemoval(username: username, password: password, remaining: 20, result: result)
        } else {
          NEHotspotNetwork.fetchCurrent { network in
            DispatchQueue.main.async {
              if network == nil && self.wifiIP() != nil {
                self.joiningStudent = false
                result(FlutterError(code: "IOS_WIFI_STATE_UNAVAILABLE",
                  message: "无法读取当前 Wi-Fi，未写入新密码。请确认签名保留访问 Wi-Fi 信息权限，并先在系统设置忽略旧 Student-5G。",
                  details: nil)); return
              }
              guard network?.ssid != "Student-5G" else {
                // A previous run may still be disconnecting after cleanup.
                // Wait, but never merge new credentials into that association.
                self.waitForStudentRemoval(username: username, password: password, remaining: 20, result: result)
                return
              }
              self.applyFreshStudent5g(username: username, password: password, result: result)
            }
          }
        }
      }
    }
  }
  private func waitForStudentRemoval(username: String, password: String, remaining: Int, result: @escaping FlutterResult) {
    NEHotspotConfigurationManager.shared.getConfiguredSSIDs { ssids in
      NEHotspotNetwork.fetchCurrent { network in
        DispatchQueue.main.async {
          let associationEnded = network != nil
            ? network?.ssid != "Student-5G" : self.wifiIP() == nil
          if !ssids.contains("Student-5G"), associationEnded {
            self.applyFreshStudent5g(username: username, password: password, result: result)
            return
          }
          guard remaining > 0 else {
            self.joiningStudent = false
            result(FlutterError(code: "IOS_WIFI_OLD_PROFILE",
              message: "旧 Student-5G 配置或连接尚未清除，未写入新密码。请在系统设置忽略 Student-5G 后重试。",
              details: nil)); return
          }
          DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            self.waitForStudentRemoval(username: username, password: password, remaining: remaining - 1, result: result)
          }
        }
      }
    }
  }
  private func applyFreshStudent5g(username: String, password: String, result: @escaping FlutterResult) {
    let eap = NEHotspotEAPSettings()
    eap.supportedEAPTypes = [NSNumber(value: 25)] // PEAP
    eap.username = username
    eap.outerIdentity = username
    eap.password = password
    eap.isTLSClientCertificateRequired = false
    eap.trustedServerNames = ["*.xmu.edu.my", "xmu.edu.my"]
    let config = NEHotspotConfiguration(ssid: "Student-5G", eapSettings: eap)
    config.joinOnce = false
    NEHotspotConfigurationManager.shared.apply(config) { error in
      DispatchQueue.main.async {
        // An existing association is no longer accepted as a successful
        // credential replacement after requesting a fresh profile.
        if let error = error as NSError? {
          self.joiningStudent = false
          result(FlutterError(code: "IOS_WIFI_CONFIGURATION",
            message: "Student-5G 新配置未被系统确认（\(error.domain)，代码 \(error.code)）。请检查加入提示、热点权限；如有旧网络，请先忽略再试。",
            details: ["domain": error.domain, "code": error.code])); return
        }
        self.waitForStudent(remaining: 30, result: result)
      }
    }
  }
  private func waitForStudent(remaining: Int, result: @escaping FlutterResult) {
    NEHotspotNetwork.fetchCurrent { network in
      DispatchQueue.main.async {
        if network?.ssid == "Student-5G", let ip = self.wifiIP(), ip.hasPrefix("10.") {
          self.joiningStudent = false
          result(["ssid": "Student-5G", "ip": ip]); return
        }
        guard remaining > 0 else {
          self.joiningStudent = false
          result(FlutterError(code: "IOS_WIFI_NOT_CONFIRMED",
            message: "系统尚未确认 Student-5G 连接和校园 IP。请检查校园网密码、学校证书和网络覆盖，并确认签名保留热点配置及访问 Wi-Fi 信息权限；未提交签到。",
            details: nil)); return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
          self.waitForStudent(remaining: remaining - 1, result: result)
        }
      }
    }
  }
  func urlSession(_ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
  private func finishSave(_ success: Bool) {
    pendingSave?(success)
    pendingSave = nil
    if let url = exportURL { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    exportURL = nil
  }
  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { finishSave(!urls.isEmpty) }
  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finishSave(false) }
}
