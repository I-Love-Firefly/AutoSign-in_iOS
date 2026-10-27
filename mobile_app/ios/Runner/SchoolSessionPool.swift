import Foundation

/// One connection pool per account AND HTTPS origin. CAS and acad can resolve
/// to the same IP with a shared certificate, but the school gateway rejects
/// acad requests coalesced onto CAS's HTTP/2 connection (HTTP 421).
/// Cookie storage stays scoped to the account, preserving normal domain/path
/// matching across the CAS redirect flow without sharing transport connections.
/// Call the pool's methods on the main queue, as the Flutter channel does.
final class SchoolSessionPool {
  private final class AccountSessions {
    let configuration: URLSessionConfiguration
    var sessions: [String: URLSession] = [:]

    init() {
      configuration = .ephemeral
      configuration.allowsCellularAccess = false
      configuration.timeoutIntervalForRequest = 25
      configuration.timeoutIntervalForResource = 30
    }

    func resetConnections() {
      for session in sessions.values { session.invalidateAndCancel() }
      sessions.removeAll()
    }

    func close() {
      resetConnections()
      if let cookies = configuration.httpCookieStorage {
        for cookie in cookies.cookies ?? [] { cookies.deleteCookie(cookie) }
      }
    }
  }

  private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
      willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
      completionHandler: @escaping (URLRequest?) -> Void) {
      // Dart validates each hop, then chooses the destination's own session.
      // Following a redirect here would defeat origin isolation.
      completionHandler(nil)
    }
  }

  private let redirectDelegate = NoRedirectDelegate()
  private var accounts: [Int: AccountSessions] = [:]
  private static let hosts: Set<String> = ["cas.xmu.edu.my", "acad.xmu.edu.my", "ac.xmu.edu.my"]

  func session(account id: Int, for url: URL) -> URLSession? {
    guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
      url.port == nil || url.port == 443, let host = url.host?.lowercased(),
      Self.hosts.contains(host) else { return nil }
    let account: AccountSessions
    if let existing = accounts[id] { account = existing }
    else {
      account = AccountSessions()
      accounts[id] = account
    }
    // All accepted URLs have scheme=https and port=443, so host is the origin key.
    if let existing = account.sessions[host] { return existing }
    let session = URLSession(configuration: account.configuration,
      delegate: redirectDelegate, delegateQueue: nil)
    account.sessions[host] = session
    return session
  }

  func resetConnections(account id: Int) {
    // Keep this account's cookies, but never retain connections after a route change.
    accounts[id]?.resetConnections()
  }

  func close(account id: Int) {
    accounts.removeValue(forKey: id)?.close()
  }

  deinit {
    for account in accounts.values { account.close() }
  }
}
