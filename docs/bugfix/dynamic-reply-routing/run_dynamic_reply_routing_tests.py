"""Check reply routing on Windows or run the offline Swift/Protobuf suite on macOS."""

import argparse
import json
from pathlib import Path
import runpy


HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
NATIVE = ROOT / "Sources" / "TiebaNative"
SCHEMA = NATIVE / "Proto" / "proto-descriptors.json"
PREVIOUS = HERE.parent / "dynamic-feed-thread"


def read(relative):
    return (NATIVE / relative).read_text(encoding="utf-8")


def check_sources():
    messages = json.loads(SCHEMA.read_text(encoding="utf-8"))["nested"]["tieba"]["nested"]
    thread = messages["ThreadInfo"]["fields"]
    origin = messages["OriginThreadInfo"]["fields"]
    assert {key: thread[key]["id"] for key in (
        "id", "threadId", "firstPostId", "postId", "originThreadInfo", "isShareThread", "forumId",
    )} == {
        "id": 1, "threadId": 2, "firstPostId": 40, "postId": 52,
        "originThreadInfo": 141, "isShareThread": 143, "forumId": 27,
    }
    assert thread["postId"]["protoName"] == "post_id"
    assert thread["originThreadInfo"]["type"] == "OriginThreadInfo"
    assert {"replyInfo", "threadInfo"}.isdisjoint(thread)
    assert [(key, origin[key]["id"], origin[key]["type"]) for key in ("tid", "fid", "pid")] == [
        ("tid", 5, "string"), ("fid", 7, "int64"), ("pid", 25, "int64"),
    ]
    generated = read("Proto/Generated/OriginThreadInfo.pb.swift")
    assert "var tid: String" in generated and "var pid: Int64" in generated
    assert "fieldNumber: 25" in generated
    concern = read("Proto/Generated/UserLike_UserLike.pb.swift")
    assert "public var threadInfo: [Tieba_UserLike_ConcernData]" in concern
    assert "case 2: try { try decoder.decodeSingularMessageField(value: &self._postData) }()" in concern
    print("PASS: descriptor, normalized aliases and generated nested ID fields")

    resolver = read("Core/Routing/TiebaThreadCardTarget.swift")
    assert "allowLegacyTopicID: Bool = false" in resolver
    assert "originPID == identifiableReply" in resolver and "if isShare(row) { return quoted(row) }" in resolver
    assert "guard topicID != firstPostID" in resolver
    assert "if origin.threadId != originPID, origin.threadId != firstPostID" in resolver
    assert "forumId: conflictingReplyForum ? nil" in resolver
    assert "row[\"title\"]" not in resolver
    mapper = read("Core/Proto/TiebaViewModelMapper.swift")
    assert '"pid": firstPositiveID(od["pid"])' in mapper and 'out["routingForumId"] = routingForumID' in mapper
    assert 'if ids.count > 1 { return "" }' in mapper
    explore = read("Features/Explore/TiebaExploreFeedViewController.swift")
    assert 'return items[index]["threadInfo"] as? [String: Any]' in explore
    assert "opening.rule.unresolvedMessage" in explore and "static let unresolvedMessage" in resolver
    assert "personalized: segment == .personalized, reference: reference" in explore
    assert "guard opening.rule.requiresExactReply" in explore
    assert "reason: .missingOrigin" in resolver and "reason: .differentOriginPID" in resolver
    assert "return Opening(target: candidate, rule: .personalizedOuter(reason))" in resolver
    assert "allowLegacyTopicID: true" not in explore
    assert "TiebaThreadCardTarget.explicit(threadId: item.threadId, postId: item.postId)" in read(
        "Features/Messages/TiebaMessageListViewController.swift"
    )
    assert ".business(4" not in read("Core/Networking/TiebaThreadPageRequest.swift").split("var errorDescription")[0]
    print("PASS: mixed-feed guard, reply/reference identity, FID conflict and code 4 policy")

    diagnostics = read("Core/Routing/TiebaReplyRoutingDiagnostics.swift")
    assert diagnostics.startswith("#if DEBUG\n") and diagnostics.rstrip().endswith("#endif")
    assert "-TiebaDebugReplyRouting" in diagnostics
    for prohibited in ("BDUSS", "STOKEN", "TBS", "Cookie", "Authorization", 'row["title"]', 'row["content"]'):
        assert prohibited not in diagnostics
    assert "thread.removeValue(forKey: TiebaReplyRoutingDiagnostics.presenceKey)" in read(
        "Core/Networking/TiebaFeedAPI.swift"
    )
    api = read("Core/Networking/TiebaThreadAPI.swift")
    assert "static func verifyReply(" in api and "forumId: forumId, requiresExactReply: true" in api
    assert "if !requiresExactReply, anchor != nil" in api
    assert "requireThreadIdentity: requiresExactReply" in api
    assert "TiebaReplyRoutingDiagnostics.pageAttempt?.request(parameters)" in api
    assert "attempt?.response(networkRequest, code: response.error.errorCode)" in api
    codec = read("Core/Proto/TiebaSwiftProtoCodec.swift")
    assert "TiebaReplyRoutingDiagnostics.addPersonalizedWirePresence(bytes, to: &decoded)" in codec
    view = read("Features/Thread/TiebaThreadViewController.swift")
    assert "TiebaReplyRoutingDiagnostics.navigationTap" in view
    assert "TiebaReplyRoutingDiagnostics.$pageAttempt.withValue(attempt)" in view
    assert "forName: TiebaSession.didChangeNotification" in explore
    assert "self?.finishReplyVerification(ticket" in explore and "$openingReplyPage.withValue(verified)" in explore
    assert "self.openingReplyPage = nil" in view and "return verified.page" in view
    assert "resolveThreadAction(thread, action: .share" in explore
    assert "validateSession: validate" in explore
    assert "TiebaThreadCardTarget.forumFeedback" in explore and "TiebaThreadCardTarget.ForumTarget" in explore
    settings = read("Features/Settings/TiebaMoreSettingsViewController.swift")
    assert 'id: "replyRoutingDiagnostics", kind: .toggle' in settings
    assert "TiebaClipboard.setString(report)" in settings
    print("PASS: opt-in Debug diagnostics and snapshot exclusion")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check-sources", action="store_true")
    args = parser.parse_args()
    check_sources()
    shared = runpy.run_path(str(PREVIOUS / "run_dynamic_feed_thread_tests.py"))
    shared["check_sources"]()
    if args.check_sources:
        print("PASS: static checks only. Swift compiler and runtime were not invoked.")
        return
    support = (PREVIOUS / "DynamicFeedThreadTests.swift").read_text(encoding="utf-8").split("\n@main\n", 1)[0]
    fixtures = (HERE / "DynamicReplyRoutingTests.swift").read_text(encoding="utf-8")
    declaration = shared["declaration"]
    social = "enum TiebaSocialAPI {\n" + "\n\n".join(
        declaration("Core/Networking/TiebaSocialAPI.swift", signature, "  }")
        for signature in ("  static func signedPost(", "  private static func assertNoError(")
    ) + '\n  private static func commonParams() -> [String: String] { [:] }\n' \
        '  private static func stParams() -> [String: String] { [:] }\n}\n'
    feedback = "enum TiebaFeedAPI {\n" + declaration(
        "Core/Networking/TiebaFeedAPI.swift", "  static func submitDislike(", "  }"
    ) + "\n}"
    shared["run_swift"](
        "\n\n".join((shared["project_sources"](), social, feedback)), fixtures=support + "\n" + fixtures,
        extra_sources=(
            "Core/Networking/TiebaThreadActionAPI.swift",
            "Core/Proto/TiebaSwiftProtoCodec.swift",
            "Core/Routing/TiebaReplyRoutingDiagnostics.swift",
            "Core/TiebaMutex.swift",
        ),
        test_flags=("-DDEBUG",), test_args=(SCHEMA,),
    )


if __name__ == "__main__":
    main()
