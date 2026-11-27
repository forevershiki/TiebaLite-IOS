"""Build an offline Swift executable from the production retry and cache paths."""

import argparse
from pathlib import Path
import re
import subprocess
import sys
import tempfile


HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
CORE = ROOT / "Sources" / "TiebaNative" / "Core"
NETWORKING = CORE / "Networking"
sys.path.insert(0, str(ROOT / "docs" / "ci"))
from swift_host_toolchain import SwiftHost


def declarations(file, *signatures):
    source = (NETWORKING / file).read_text(encoding="utf-8")
    selected = []
    for signature in signatures:
        closing = "  }" if signature.startswith("  ") else "}"
        pattern = rf"^{re.escape(signature)}[^\n]*\n.*?^{closing}$"
        matches = re.findall(pattern, source, re.MULTILINE | re.DOTALL)
        if len(matches) != 1:
            raise ValueError(f"{file}: expected one declaration starting with {signature!r}")
        selected.append(matches[0])
    return "\n\n".join(selected)


def production_source():
    # Match the real declarations at their original indentation. Swift fixtures supply
    # only the surrounding dependencies, and the selected method bodies stay verbatim.
    forum = declarations(
        "TiebaForumAPI.swift", "  static func protoPost<", "  private static func shouldRetryRead("
    )
    feed = declarations(
        "TiebaForumFeedAPI.swift", "  static func page(", "  private static func cacheScope(",
        "  static func unlike(", "  private static func postForm(",
    )
    http = declarations(
        "TiebaHttpClient.swift", "  func sendData(", "  private static func isAllowedHost("
    )
    cache_types = declarations(
        "TiebaPageCache.swift", "enum TiebaPageCacheKind:", "struct TiebaPageCacheScope:",
        "struct TiebaPageCacheEntry:",
    )
    cache_policy = declarations("TiebaPageCache.swift", "  static func shouldFallbackToCache(")
    return "\n\n".join([
        "import Foundation",
        declarations("TiebaForumAPI.swift", "enum TiebaForumAPIError:"),
        "extension TiebaForumAPI {\n" + forum + "\n}",
        "extension TiebaForumFeedAPI {\n" + feed + "\n}",
        "extension TiebaHttpClient {\n" + http + "\n}",
        cache_types,
        "extension TiebaPageCache {\n" + cache_policy + "\n}",
    ]) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check-sources", action="store_true", help="verify source extraction only")
    args = parser.parse_args()
    source = production_source()
    if args.check_sources:
        print("PASS: selected production declarations extracted")
        return

    host = SwiftHost()
    with tempfile.TemporaryDirectory(prefix="tieba-http-retry-") as directory:
        projected = Path(directory) / "Production.swift"
        projected.write_text(source, encoding="utf-8")
        executable = Path(directory) / "HTTPRetryTests"
        host.compile(
            str(projected), str(HERE / "HTTPRetryTests.swift"),
            str(NETWORKING / "TiebaNativeClient.swift"),
            str(CORE / "Routing" / "TiebaRoutePath.swift"),
            str(CORE / "Proto" / "TiebaProtoCodec.swift"),
            str(CORE / "Proto" / "TiebaViewModelMapper.swift"),
            "-o", str(executable),
        )
        subprocess.run([str(executable)], check=True, timeout=45)


if __name__ == "__main__":
    main()
