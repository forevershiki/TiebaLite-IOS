import Foundation

private struct TestFailure: Error, CustomStringConvertible {
  let description: String
}

@main
@MainActor
enum DeepLinkTests {
  static func main() throws {
    try testNameRoundTrips()
    try testRoutingCompatibility()
    try testInvalidInputs()
    print("PASS: offline Swift name round trips, compatibility and invalid inputs")
  }

  private static func testNameRoundTrips() throws {
    let names = [
      "百度", "程序员", "yy小说吧", "A/B", "A/detail", "/", "A//B", "A?B", "A?name=C&forumId=9",
      "A#B", "A&B", "A=B", "A+B", "A B", " A ", "A%B", "A%2FB", "A%252FB", "A%GG",
      "中文Dev吧", "𝄞 café🧪", "Cafe\u{0301}", "Caf\u{00E9}",
    ]
    for name in names {
      let share = TiebaForumLink.forum(name)
      let encoded = TiebaRoutePath.segment(name)
      try expectForum(externalRoute(share), name, "share \(share)")
      try expectForum(TiebaLinkOpener.inAppRoute(share), name, "post body \(share)")
      try expectForum(externalRoute("https://m.tieba.baidu.com/mo/q/m?word=\(encoded)"), name, "mobile word")
      try expectForum(externalRoute("com.baidu.tieba://unidispatch/frs?kw=\(encoded)"), name, "Baidu scheme")
      try expectForum(externalRoute("tiebalite://forum/\(encoded)"), name, "tiebalite")
      try expectForum(externalRoute("tblite://forum/\(encoded)"), name, "tblite")
      try expectForum(TiebaRouteTable.parse(path: "/forum/\(encoded)"), name, "Debug path")
    }
    try expect(TiebaForumLink.forum("A+B").hasSuffix("kw=A%2BB"), "share must encode plus")
    try expectForum(externalRoute("https://tieba.baidu.com/f?kw=A+B"), "A+B", "raw URL plus")
    try expectForum(TiebaLinkOpener.inAppRoute("https://tieba.baidu.com/f?kw=A+B"), "A+B", "body URL plus")
    try expectForum(externalRoute("https://tieba.baidu.com/f?kw=A#B"), "A", "fragment delimiter")
    try expectForum(externalRoute("https://tieba.baidu.com/f?kw=A&B"), "A", "query delimiter")
    try expect(TiebaRoute.forum(name: "A/B").signature != TiebaRoute.forum(name: "A%2FB").signature,
               "literal percent sequence and slash must have different navigation signatures")
    try expect(TiebaRoute.forum(name: "Cafe\u{0301}").signature != TiebaRoute.forum(name: "Caf\u{00E9}").signature,
               "composed and decomposed Unicode must keep their original bytes")
  }

  private static func testRoutingCompatibility() throws {
    try expectForum(externalRoute("https://tieba.baidu.com/f?kw=First&kw=Second&word=Other"), "First", "first kw")
    try expectForum(externalRoute("https://tieba.baidu.com/f?kw&word=Fallback"), "Fallback", "valueless kw")
    try expectForum(externalRoute("https://tieba.baidu.com/f?%6Bw=A&name=B&forumId=9"), "A", "external key precedence")
    try expectForum(externalRoute("com.baidu.tieba://dispatch/unidispatch/frs?kw=A%252FB"), "A%2FB", "Baidu dispatch path")
    try expectForum(externalRoute("tiebalite://forum//A//?name=B&kw=C&forumId=9"), "A", "scheme path precedence")
    try expectForum(TiebaLinkOpener.inAppRoute("https://www.tieba.baidu.com/f?kw=A&kw=B"), "A", "body link")
    try expect(externalRoute("tiebalite://forum/A/detail?name=B") == .forumDetail(name: "A"), "explicit forum subpage")
    try expect(externalRoute("tblite://forum/A%2FB/rules") == .forumRules(name: "A/B"), "encoded subpage name")
    try expect(TiebaRouteTable.parse(path: "/forum/A?name=B&name=C&forumId=9") == .forum(name: "C", forumId: "9"),
               "Debug route query overrides path and keeps the final duplicate")

    let external: [(String, TiebaRoute)] = [
      ("https://tieba.baidu.com/p/123?kw=Other", .thread(id: "123")),
      ("http://tieba.baidu.com/%70/%30%31%32%33/extra#floor", .thread(id: "0123")),
      ("https://tieba.baidu.com/f?kz=123&kw=Other", .thread(id: "123")),
      ("com.baidu.tieba://unidispatch/frs?tid=123&kw=Other", .thread(id: "123")),
      ("tblite://thread/123", .thread(id: "123")),
      ("tblite://thread/%31%32%33/extra", .thread(id: "123")),
      ("tiebalite://notifications/2", .notifications(initialTab: 2)),
      ("tiebalite://search?q=A%252FB%26C%3DD", .search(keyword: "A%2FB&C=D")),
      ("tblite://history?tab=forum", .history(tab: "forum")),
    ]
    for (raw, expected) in external {
      try expect(externalRoute(raw) == expected, raw)
    }
    try expect(TiebaLinkOpener.inAppRoute("https://tieba.baidu.com/p/123/extra") == .thread(id: "123"), "body thread")
    try expect(TiebaLinkOpener.inAppRoute("//tieba.baidu.com/p/123") == .thread(id: "123"), "relative body thread")
    let internalPaths: [(String, TiebaRoute)] = [
      ("/", .index),
      ("/settings", .settings),
      ("/search?q=A%2BB", .search(keyword: "A+B")),
      ("/thread/123?postId=456&seeLz=1", .thread(id: "123", postId: "456", seeLz: true)),
      ("/thread/123/more?sort=1", .threadMore(id: "123", canDelete: false, seeLz: false, sort: .desc)),
      ("/user/456?tab=forum", .user(uid: "456", tab: "forum")),
      ("/topic/789?name=A%23B%26C%3DD", .topic(id: "789", name: "A#B&C=D")),
      ("/history?tab=forum", .history(tab: "forum")),
    ]
    for (path, expected) in internalPaths {
      try expect(TiebaRouteTable.parse(path: path) == expected, path)
    }
  }

  private static func testInvalidInputs() throws {
    let unsupported = [
      "https://example.com/f?kw=A", "https://tieba.baidu.com.example.com/f?kw=A",
      "https://example.com/?url=tblite://thread/123", "https://tieba.baidu.com/f?name=A",
      "https://tieba.baidu.com/f?kw=&word=Fallback", TiebaForumLink.forum(""),
      "https://tieba.baidu.com/f?kw=%FF&word=Fallback", "com.baidu.tieba://unidispatch/frs?word=A",
      "https://tieba.baidu.com/f?kw=A%00B", "com.baidu.tieba://unidispatch/frs?kw=A%00B",
      "ftp://tieba.baidu.com/f?kw=A", "ftp://tieba.baidu.com/p/123",
      "https://tieba.baidu.com/mo%2Fq%2Fm?kw=A", "com.baidu.tieba://dispatch/unidispatch-other/frs?kw=A",
      "https://tieba.baidu.com/p/123%2Fextra", "https://tieba.baidu.com/p/123suffix",
      "https://tieba.baidu.com/f?kz=123%3Fid%3D456", "https://tieba.baidu.com/f?kz=%FF&kw=Other",
      "https://tieba.baidu.com/f?kz=&kw=Other", "com.baidu.tieba://unidispatch/frs?tid=123%2Fmore",
      "tblite://forum", "tblite://forum///", "tblite://forum/?kw=A", "tblite://unknown/A",
      "tiebalite://thread/not-a-number", "tiebalite://user/42", "tiebalite://topic/42",
      "tiebalite://thread/123%2Fextra", "tiebalite://thread/%EF%BC%91%EF%BC%92%EF%BC%93",
    ]
    for raw in unsupported {
      try expect(externalRoute(raw) == nil, "Must not route \(raw)")
    }
    try expect(externalRoute("tblite://forum/A/B") == .notFound(path: "forum/A/B"), "unknown raw subpage")
    try expect(externalRoute("tblite://forum/%FF/detail") == .notFound(path: "forum/%FF/detail"), "invalid UTF-8 path")
    try expect(externalRoute("tblite://forum/A%00B") == .notFound(path: "forum/A%00B"), "NUL forum name")
    let invalidPaths = [
      "/unknown", "/forum/", "/forum/%GG", "/forum/%FF", "/forum/A%00B", "/forum/A?name=%00",
      "/forum/A?name=", "/forum/A?name=%FF", "/thread/", "/user/", "/topic/",
    ]
    for path in invalidPaths {
      try expect(TiebaRouteTable.parse(path: path) == nil, "Invalid Debug path \(path)")
    }
    try expect(TiebaLinkOpener.inAppRoute("https://m.tieba.baidu.com/f?kw=A") == nil, "body host allowlist")
    try expect(TiebaLinkOpener.inAppRoute(TiebaForumLink.forum("")) == nil, "empty body query")
    try expect(TiebaLinkOpener.inAppRoute("https://tieba.baidu.com/f?kw=%FF") == nil, "invalid body query decoding")
    try expect(TiebaLinkOpener.inAppRoute("https://tieba.baidu.com/f?kw=A%00B") == nil, "NUL body query")
    try expect(TiebaLinkOpener.inAppRoute("https://tieba.baidu.com/p/123suffix") == nil, "invalid ID in body link")
    try expect(TiebaLinkOpener.inAppRoute("ftp://tieba.baidu.com/p/123") == nil, "non-web scheme in body link")
    if #available(macOS 14.0, iOS 17.0, *) {
      try expect(URL(string: "https://tieba.baidu.com/f?kw=A%GG", encodingInvalidCharacters: false) == nil,
                 "strict URL parser must reject malformed escapes")
    }
  }

  private static func externalRoute(_ raw: String) -> TiebaRoute? {
    guard let url = URL(string: raw) else { preconditionFailure("Invalid URL fixture: \(raw)") }
    let navigator = TiebaNavigator()
    let handled = navigator.open(url: url)
    precondition(handled == (navigator.capturedRoute != nil), "Routing result disagrees with open(url:)")
    return navigator.capturedRoute
  }

  private static func expectForum(_ route: TiebaRoute?, _ name: String, _ context: String) throws {
    guard case let .forum(actual, forumId)? = route, actual.utf8.elementsEqual(name.utf8), forumId.isEmpty else {
      throw TestFailure(description: "\(context) expected forum \(name), got \(String(describing: route))")
    }
  }

  private static func expect(_ condition: Bool, _ description: String) throws {
    guard condition else { throw TestFailure(description: description) }
  }
}
