import Foundation
import XCTest
@testable import SchoolTransport

// Compiled together with the actual Runner source, without Flutter or a device.
final class SchoolSessionPoolTests: XCTestCase {
  let pool = SchoolSessionPool()
  let cas = URL(string: "https://cas.xmu.edu.my/lyuapServer/login")!
  let acad = URL(string: "https://acad.xmu.edu.my/mobile/tryLoginUserInfo")!
  let ac = URL(string: "https://ac.xmu.edu.my/index.php")!

  func testDistinctOriginsAndAccountsHaveDistinctConnectionPools() throws {
    let login = try XCTUnwrap(pool.session(account: 1, for: cas))
    let identity = try XCTUnwrap(pool.session(account: 1, for: acad))
    let timetable = try XCTUnwrap(pool.session(account: 1, for: ac))
    let otherAccount = try XCTUnwrap(pool.session(account: 2, for: cas))
    XCTAssertFalse(login === identity)
    XCTAssertFalse(identity === timetable)
    XCTAssertFalse(login === otherAccount)
    XCTAssertTrue(login === pool.session(account: 1,
      for: URL(string: "https://cas.xmu.edu.my:443/lyuapServer/loginType")!))
    for session in [login, identity, timetable, otherAccount] {
      XCTAssertFalse(session.configuration.allowsCellularAccess)
      XCTAssertEqual(session.configuration.timeoutIntervalForResource, 30)
    }
  }

  func testCookiesRemainAccountScopedAcrossOriginSessions() throws {
    let login = try XCTUnwrap(pool.session(account: 1, for: cas))
    let identity = try XCTUnwrap(pool.session(account: 1, for: acad))
    let other = try XCTUnwrap(pool.session(account: 2, for: cas))
    let cookies = try XCTUnwrap(login.configuration.httpCookieStorage)
    let otherCookies = try XCTUnwrap(other.configuration.httpCookieStorage)
    XCTAssertTrue(cookies === identity.configuration.httpCookieStorage)
    XCTAssertFalse(cookies === otherCookies)
    let cookie = try XCTUnwrap(HTTPCookie(properties: [
      .name: "diagnostic-test-cookie", .value: "fake-only", .domain: ".xmu.edu.my",
      .path: "/", .secure: "TRUE"
    ]))
    cookies.setCookie(cookie)
    XCTAssertTrue(cookies.cookies(for: acad)?.contains(where: { $0.name == cookie.name }) == true)
    XCTAssertFalse(otherCookies.cookies?.contains(where: { $0.name == cookie.name }) == true)
    XCTAssertFalse(HTTPCookieStorage.shared.cookies?.contains(where: { $0.name == cookie.name }) == true)
  }

  func testResetReplacesAllOriginConnectionsButPreservesCookies() throws {
    let login = try XCTUnwrap(pool.session(account: 1, for: cas))
    let identity = try XCTUnwrap(pool.session(account: 1, for: acad))
    let other = try XCTUnwrap(pool.session(account: 2, for: cas))
    let cookies = try XCTUnwrap(identity.configuration.httpCookieStorage)
    let cookie = try XCTUnwrap(HTTPCookie(properties: [
      .name: "session-test", .value: "fake", .domain: "acad.xmu.edu.my", .path: "/"
    ]))
    cookies.setCookie(cookie)
    pool.resetConnections(account: 1)
    let newIdentity = try XCTUnwrap(pool.session(account: 1, for: acad))
    XCTAssertFalse(login === pool.session(account: 1, for: cas))
    XCTAssertFalse(identity === newIdentity)
    XCTAssertTrue(other === pool.session(account: 2, for: cas))
    XCTAssertTrue(cookies === newIdentity.configuration.httpCookieStorage)
    XCTAssertTrue(cookies.cookies?.contains(where: { $0.name == cookie.name }) == true)
  }

  func testCloseClearsOnlyTheClosedAccountCookiesAndConnections() throws {
    let login = try XCTUnwrap(pool.session(account: 1, for: cas))
    let identity = try XCTUnwrap(pool.session(account: 1, for: acad))
    let other = try XCTUnwrap(pool.session(account: 2, for: cas))
    let cookies = try XCTUnwrap(login.configuration.httpCookieStorage)
    let otherCookies = try XCTUnwrap(other.configuration.httpCookieStorage)
    let cookie = try XCTUnwrap(HTTPCookie(properties: [
      .name: "close-test", .value: "fake", .domain: "cas.xmu.edu.my", .path: "/"
    ]))
    cookies.setCookie(cookie)
    otherCookies.setCookie(cookie)
    pool.close(account: 1)
    pool.close(account: 1) // Cleanup is idempotent.
    XCTAssertTrue(cookies.cookies?.isEmpty ?? true)
    XCTAssertTrue(otherCookies.cookies?.contains(where: { $0.name == cookie.name }) == true)
    XCTAssertFalse(login === pool.session(account: 1, for: cas))
    XCTAssertFalse(identity === pool.session(account: 1, for: acad))
    XCTAssertTrue(other === pool.session(account: 2, for: cas))
  }

  func testRedirectStaysInDartForDestinationSessionSelection() throws {
    let session = try XCTUnwrap(pool.session(account: 1, for: cas))
    let delegate = try XCTUnwrap(session.delegate as? URLSessionTaskDelegate)
    let task = session.dataTask(with: cas) // Never resumed; no real requests.
    defer { task.cancel() }
    let response = try XCTUnwrap(HTTPURLResponse(url: cas, statusCode: 302,
      httpVersion: "HTTP/1.1", headerFields: ["Location": acad.absoluteString]))
    var called = false
    delegate.urlSession?(session, task: task, willPerformHTTPRedirection: response,
      newRequest: URLRequest(url: acad)) { request in
        called = true
        XCTAssertNil(request)
      }
    XCTAssertTrue(called)
  }

  func testUnsupportedOriginsCannotCreateSessions() {
    for address in ["http://acad.xmu.edu.my/mobile/", "https://acad.xmu.edu.my:8443/",
      "https://user:password@acad.xmu.edu.my/", "https://example.org/",
      "https://acad.xmu.edu.my.example.org/"] {
      XCTAssertNil(pool.session(account: 1, for: URL(string: address)!))
    }
  }
}

