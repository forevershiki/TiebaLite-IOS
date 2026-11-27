"""Run the app's Swift URL parsing and route table without launching UIKit."""

import argparse
from pathlib import Path
import re
import subprocess
import sys
import tempfile


HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
NATIVE = ROOT / "Sources" / "TiebaNative"
sys.path.insert(0, str(ROOT / "docs" / "ci"))
from swift_host_toolchain import SwiftHost


def extract(relative_path, signature, closing):
    source = (NATIVE / relative_path).read_text(encoding="utf-8")
    pattern = rf"^{re.escape(signature)}[^\n]*\n.*?^{re.escape(closing)}$"
    matches = re.findall(pattern, source, re.MULTILINE | re.DOTALL)
    if len(matches) != 1:
        raise ValueError(f"{relative_path}: expected one declaration starting with {signature!r}")
    return matches[0]


def project_sources():
    navigator = extract("App/TiebaNavigator.swift", "  // MARK: - 深链", "}")
    body_link = extract("App/TiebaLinkOpener.swift", "  private static func openTiebaInApp(", "  }")
    share = extract("Features/Forum/TiebaForumViewController.swift", "enum TiebaForumLink {", "}")
    sort = extract("Core/Models/TiebaThreadSort.swift", "public enum TiebaThreadSort:", "}")
    # Keep the production methods verbatim. The navigator only records the route in this executable.
    return f"""import Foundation

{sort}

{share}

@MainActor
public final class TiebaNavigator {{
  static let shared = TiebaNavigator()
  var capturedRoute: TiebaRoute?

  @discardableResult
  public func navigate(_ route: TiebaRoute) -> Bool {{
    capturedRoute = route
    return true
  }}

{navigator}

@MainActor
enum TiebaLinkOpener {{
{body_link}

  static func inAppRoute(_ raw: String) -> TiebaRoute? {{
    TiebaNavigator.shared.capturedRoute = nil
    guard openTiebaInApp(raw) else {{ return nil }}
    return TiebaNavigator.shared.capturedRoute
  }}
}}
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check-sources", action="store_true", help="check Swift source extraction only")
    args = parser.parse_args()
    source = project_sources()
    if args.check_sources:
        print("PASS: production external URL, body-link and share methods extracted")
        return

    host = SwiftHost()
    with tempfile.TemporaryDirectory(prefix="tieba-deep-link-") as directory:
        projected = Path(directory) / "Production.swift"
        projected.write_text(source, encoding="utf-8")
        executable = Path(directory) / "DeepLinkTests"
        host.compile(
            str(projected), str(HERE / "DeepLinkTests.swift"),
            str(NATIVE / "App" / "TiebaNavigationRoute.swift"),
            str(NATIVE / "Core" / "Routing" / "TiebaRoute.swift"),
            str(NATIVE / "Core" / "Routing" / "TiebaRoutePath.swift"),
            "-o", str(executable),
        )
        subprocess.run([str(executable)], check=True, timeout=30)


if __name__ == "__main__":
    main()
