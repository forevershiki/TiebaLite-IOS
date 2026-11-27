"""Run offline Swift composer regressions and the existing read/route suites."""

import argparse
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
NATIVE = ROOT / "Sources" / "TiebaNative"
CORE = [
    NATIVE / "Core/Networking/TiebaComposerProtocol.swift",
    NATIVE / "Core/Networking/TiebaComposerSubmission.swift",
    NATIVE / "Features/Composer/TiebaComposerDraftStore.swift",
]
INTEGRATION = [
    "Core/Networking/TiebaForumFeedAPI.swift",
    "Core/Networking/TiebaHttpClient.swift",
    "Core/Networking/TiebaThreadAPI.swift",
    "Features/Composer/TiebaComposerViewController.swift",
    "Features/Forum/TiebaForumViewController.swift",
    "Features/Settings/TiebaMoreSettingsViewController.swift",
    "Features/Thread/TiebaSubpostsViewController.swift",
    "Features/Thread/TiebaThreadViewController.swift",
    "UI/ListKit/TiebaKindListView.swift",
    "UI/ListKit/TiebaPostRowInline.swift",
    "UI/ListKit/TiebaPostRowView.swift",
]
TEST = HERE / "ComposerTests.swift"
BASELINE = [
    ROOT / "docs/bugfix/http-retry/run_retry_tests.py",
    ROOT / "docs/bugfix/deep-link/run_deep_link_tests.py",
]


def check_sources():
    http = (NATIVE / INTEGRATION[1]).read_text(encoding="utf-8")
    single_dispatch = http.split("func sendComposerForm(", 1)[1].split("// MARK: - 发送核心", 1)[0]
    if (single_dispatch.count("try await transport(") != 1 or "perform(" in single_dispatch or
            'request.httpMethod = "POST"' not in single_dispatch or "completionHandler(nil)" not in http):
        raise ValueError("Composer transport must use exactly one direct POST and reject redirects")
    protocol = CORE[0].read_text(encoding="utf-8")
    floor = protocol.split("static func fields(", 1)[1].split("static func destination(", 1)[0]
    for required in ('parameters["pid"] = parent', 'parameters["lzl_id"] = comment', 'parameters["floor"] = String(floor)'):
        if required not in floor:
            raise ValueError(f"Missing explicit reply binding: {required}")
    print("PASS: composer transport and nested reply wiring", flush=True)


def check_syntax():
    from tree_sitter import Language, Parser
    import tree_sitter_swift

    parser = Parser(Language(tree_sitter_swift.language()))
    swift_files = CORE + [NATIVE / path for path in INTEGRATION] + [TEST]
    errors = []
    for path in swift_files:
        root = parser.parse(path.read_bytes()).root_node
        stack = [root] if root.has_error else []
        while stack:
            node = stack.pop()
            if node.type == "ERROR" or node.is_missing:
                line, column = node.start_point
                errors.append(f"{path.relative_to(ROOT)}:{line + 1}:{column + 1}: {node.type}")
            stack.extend(child for child in reversed(node.children) if child.has_error or child.is_missing)
    if errors:
        raise ValueError("\n".join(errors))
    print(f"PASS: Swift syntax tree for {len(swift_files)} files", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check-sources", action="store_true", help="run source checks without swiftc")
    parser.add_argument("--suite-only", action="store_true", help="skip separately scheduled retry and deep-link suites")
    parser.add_argument("--swift-syntax", action="store_true", help="also parse Swift with tree-sitter and tree-sitter-swift")
    args = parser.parse_args()
    check_sources()
    if args.swift_syntax:
        check_syntax()
    if args.check_sources:
        if not args.suite_only:
            for suite in BASELINE:
                subprocess.run([sys.executable, str(suite), "--check-sources"], check=True, timeout=30)
        return

    swiftc = shutil.which("swiftc")
    if not swiftc:
        parser.error("Swift 6 is required to run the offline executable. Use --check-sources for static checks.")
    with tempfile.TemporaryDirectory(prefix="tieba-composer-") as directory:
        executable = Path(directory) / "ComposerTests"
        subprocess.run([
            swiftc, "-swift-version", "6", "-parse-as-library",
            *(str(file) for file in [*CORE, TEST]), "-o", str(executable),
        ], check=True, timeout=120)
        subprocess.run([str(executable)], check=True, timeout=30)
    if not args.suite_only:
        for suite in BASELINE:
            subprocess.run([sys.executable, str(suite)], check=True, timeout=150)


if __name__ == "__main__":
    main()
