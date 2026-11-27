"""Check the route wiring or run offline Swift tests with the vendored Protobuf runtime."""

import argparse
import json
from pathlib import Path
import re
import runpy
import shutil
import subprocess
import tempfile


HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
NATIVE = ROOT / "Sources" / "TiebaNative"


def read(relative):
    return (NATIVE / relative).read_text(encoding="utf-8")


def declaration(path, signature, closing="}"):
    matches = re.findall(
        rf"^{re.escape(signature)}[^\n]*\n.*?^{re.escape(closing)}$",
        read(path), re.MULTILINE | re.DOTALL,
    )
    if len(matches) != 1:
        raise AssertionError(f"{path}: expected one declaration starting with {signature}")
    return matches[0]


def project_sources():
    previous_runner = HERE.parent / "deep-link" / "run_deep_link_tests.py"
    runner = runpy.run_path(str(previous_runner))
    return "\n\n".join([
        runner["project_sources"](),
        declaration("UI/Components/TiebaForumCommon.swift", "enum TiebaForumFormat {"),
        declaration("Core/Networking/TiebaForumAPI.swift", "enum TiebaForumAPIError:"),
        declaration("Core/Networking/TiebaNativeClient.swift", "enum TiebaClientError:"),
        declaration("Core/Networking/TiebaPageCache.swift", "enum TiebaPageCacheKind:"),
        declaration("Core/Networking/TiebaPageCache.swift", "struct TiebaPageCacheScope:"),
        declaration("Core/Networking/TiebaPageCache.swift", "struct TiebaPageCacheEntry:"),
        "extension TiebaPageCache {\n"
        + declaration("Core/Networking/TiebaPageCache.swift", "  static func shouldFallbackToCache(", "  }")
        + "\n}",
    ])


def check_sources():
    fields = json.loads(read("Proto/proto-descriptors.json"))["nested"]["tieba"]["nested"]
    page_fields = fields["pbPage"]["nested"]["PbPageRequestData"]["fields"]
    expected = {"kz": 4, "pid": 7, "pn": 18, "forumId": 56}
    assert {key: page_fields[key]["id"] for key in expected} == expected
    assert "kw" not in page_fields
    pb = read("Proto/Generated/PbPage_PbPageRequestData.pb.swift")
    assert "_pn != 0" in pb and "var hasForumID: Bool" in pb
    print("PASS: checked-in pb/page fields, default pn and optional forum_id")

    entries = {
        "Explore/TiebaExploreFeedViewController.swift": "TiebaThreadCardTarget.card(thread)",
        "Explore/TiebaHotListViewController.swift": "TiebaThreadCardTarget.card(threads[index].row)",
        "Explore/TiebaTopicViewController.swift": "TiebaThreadCardTarget.card(threads[index])",
        "Forum/TiebaForumViewController.swift": "TiebaThreadCardTarget.card(row)",
        "Forum/TiebaForumSearchViewController.swift": ".thread(id: hit.threadId, forumId: forumId, forumName: forumName)",
        "Search/TiebaSearchViewController.swift": "TiebaThreadCardTarget.card(hit.row)",
        "Profile/TiebaHistoryViewController.swift": "forumId: entry.forumId, forumName: entry.forumName",
        "Profile/TiebaUserProfileViewController.swift": "TiebaThreadCardTarget.card(row)",
        "Thread/TiebaThreadStoreViewController.swift": "target.route(fromFavorites: true)",
        "Thread/TiebaSubpostsViewController.swift": ".thread(id: threadId, forumId: forumId, forumName: forumName)",
    }
    for path, snippet in entries.items():
        assert snippet in read("Features/" + path), path
    feed = read("Features/Explore/TiebaExploreFeedViewController.swift")
    assert "TiebaFeedAPI.personalized(" in feed and "TiebaFeedAPI.userLike(" in feed
    assert "forumName: forumName" in read("App/TiebaNativeRoute.swift")
    view = read("Features/Thread/TiebaThreadViewController.swift")
    assert view.count("forumId: self.knownForumID") == 4
    api = read("Core/Networking/TiebaThreadAPI.swift")
    assert "request.kz = parameters.threadID" in api
    assert "request.pn = parameters.pageNumber" in api
    assert "if let fid = parameters.forumID { request.forumID = fid }" in api
    assert "allowStaleOnError: !composerRefresh" in view
    print("PASS: feed, search, history, favorites and thread request wiring")

    components = {
        "UI/ListKit/TiebaFeedRowModel.swift": "TiebaForumFormat.displayName(forumName)",
        "UI/ListKit/TiebaFeedRowView+Configure.swift": "chipLabel.text = model.forumChipText",
        "UI/ListKit/TiebaFeedRowView+Accessibility.swift": "label: model.forumChipText",
        "Features/Home/TiebaHomeViewController+Part.swift": "TiebaForumFormat.displayName(",
        "Features/Explore/TiebaHotListViewController.swift": "TiebaForumFormat.displayName(",
        "Features/Forum/TiebaForumViewController.swift": "TiebaForumFormat.displayName(",
        "Features/Thread/TiebaThreadViewController+Part.swift": "TiebaForumFormat.displayName(",
        "Features/Profile/TiebaUserProfileViewController.swift": "TiebaForumFormat.displayName(",
        "Core/Networking/TiebaSearchAPI.swift": "TiebaForumFormat.displayName(name)",
    }
    suffix = re.compile(r'\)吧"|%@吧|\+\s*"吧"|hasSuffix\("吧"\)')
    for path, snippet in components.items():
        source = read(path)
        assert snippet in source, path
        assert not suffix.search(source), path
    print("PASS: shared formatting and measured/rendered/accessibility chip text")


def run_swift(swiftc, source):
    with tempfile.TemporaryDirectory(prefix="tieba-dynamic-thread-") as directory:
        stage = Path(directory)
        generated = stage / "Production.swift"
        generated.write_text(source, encoding="utf-8")

        def swift(*args):
            subprocess.run(
                [swiftc, "-swift-version", "6", "-parse-as-library", *map(str, args)],
                check=True, timeout=1200,
            )

        def library(name, files, *flags):
            swift(
                "-emit-library", "-emit-module", "-module-name", name,
                "-whole-module-optimization",
                "-emit-module-path", stage / (name + ".swiftmodule"),
                "-o", stage / ("lib" + name + ".dylib"),
                *flags, *sorted(files),
            )

        vendor = ROOT / "Vendor" / "SwiftProtobuf" / "Sources" / "SwiftProtobuf"
        library("SwiftProtobuf", vendor.rglob("*.swift"), "-package-name", "SwiftProtobuf")
        library("TiebaNativeProto", (NATIVE / "Proto" / "Generated").rglob("*.swift"),
                "-I", stage, "-L", stage, "-lSwiftProtobuf")
        fixture = stage / "DynamicFeedThreadTests"
        sources = [
            "Exports.swift",
            "App/TiebaNavigationRoute.swift",
            "Core/Networking/TiebaThreadAPI.swift",
            "Core/Networking/TiebaThreadPageRequest.swift",
            "Core/Proto/TiebaProtoCodec.swift",
            "Core/Proto/TiebaViewModelMapper.swift",
            "Core/Routing/TiebaRoute.swift",
            "Core/Routing/TiebaRoutePath.swift",
            "Core/Routing/TiebaThreadCardTarget.swift",
        ]
        swift(
            "-I", stage, "-L", stage, "-lSwiftProtobuf", "-lTiebaNativeProto",
            "-Xlinker", "-rpath", "-Xlinker", stage,
            *(NATIVE / name for name in sources),
            generated, HERE / "DynamicFeedThreadTests.swift", "-o", fixture,
        )
        subprocess.run([str(fixture)], check=True, timeout=60)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check-sources", action="store_true", help="run static checks without Swift")
    args = parser.parse_args()
    source = project_sources()
    check_sources()
    if args.check_sources:
        print("PASS: production source extraction. Swift compiler and runtime were not invoked.")
        return
    swiftc = shutil.which("swiftc")
    if not swiftc:
        parser.error("macOS with Swift 6 is required to compile and run the offline regression")
    run_swift(swiftc, source)


if __name__ == "__main__":
    main()
