"""Select the active Xcode macOS toolchain for standalone Swift tests."""

import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile


class SwiftHost:
    def __init__(self):
        if sys.platform != "darwin":
            raise SystemExit("macOS and Xcode are required for Swift tests. Use --check-sources for Python checks.")

        # xcrun must resolve the macOS SDK even if the caller exported an iOS SDKROOT.
        self.env = os.environ.copy()
        self.env.pop("SDKROOT", None)
        self.swiftc = Path(self.xcrun("--find", "swiftc"))
        self.sdk = Path(self.xcrun("--show-sdk-path"))
        if not self.swiftc.is_absolute() or not self.swiftc.is_file():
            raise SystemExit(f"Selected swiftc does not exist: {self.swiftc}")
        if not self.sdk.is_absolute() or not self.sdk.is_dir():
            raise SystemExit(f"Selected macOS SDK does not exist: {self.sdk}")
        self.env["SDKROOT"] = str(self.sdk)

    def xcrun(self, *args):
        return subprocess.check_output(
            ["xcrun", "--sdk", "macosx", *args], env=self.env, text=True, timeout=30,
        ).strip()

    def compile(self, *args, timeout=120):
        subprocess.run(
            [str(self.swiftc), "-sdk", str(self.sdk), "-swift-version", "6", "-parse-as-library", *map(str, args)],
            env=self.env, check=True, timeout=timeout,
        )


def diagnostic(*command, env=None, required=True):
    command = [str(arg) for arg in command]
    print(f"$ {shlex.join(command)}", flush=True)
    result = subprocess.run(command, env=env, text=True, capture_output=True, timeout=30)
    if result.stdout:
        print(result.stdout.rstrip(), flush=True)
    if result.stderr:
        print(result.stderr.rstrip(), file=sys.stderr, flush=True)
    if result.returncode:
        print(f"Exit status: {result.returncode}", flush=True)
        if required:
            result.check_returncode()
    return result.stdout


def main():
    for name in ("SDKROOT", "DEVELOPER_DIR", "TOOLCHAINS"):
        print(f"Inherited {name}={os.environ.get(name, '<unset>')}", flush=True)
    developer = Path(diagnostic("xcode-select", "-p").strip()).resolve()
    diagnostic("xcodebuild", "-version")
    # These two probes show how the original invocation resolved the SDK.
    diagnostic("xcrun", "--find", "swiftc", required=False)
    host = SwiftHost()
    print(f"Selected swiftc (xcrun --sdk macosx --find swiftc): {host.swiftc}", flush=True)
    print(f"Selected SDKROOT (xcrun --sdk macosx --show-sdk-path): {host.sdk}", flush=True)
    diagnostic("xcrun", "--sdk", "macosx", "--show-sdk-version", env=host.env)
    diagnostic(host.swiftc, "--version", env=host.env)
    diagnostic(host.swiftc, "-print-target-info", required=False)
    target_info = diagnostic(host.swiftc, "-sdk", host.sdk, "-print-target-info", env=host.env)
    triple = json.loads(target_info)["target"]["triple"]
    if "-apple-macosx" not in triple:
        raise SystemExit(f"Expected a macOS host target, got {triple}")
    if developer not in host.swiftc.resolve().parents or developer not in host.sdk.resolve().parents:
        raise SystemExit(f"swiftc and macOS SDK must both belong to the selected developer directory: {developer}")

    with tempfile.TemporaryDirectory(prefix="tieba-swift-host-") as directory:
        source = Path(directory) / "FoundationSmoke.swift"
        source.write_text(
            """import Foundation

@main
struct FoundationSmoke {
    static func main() {
        let message = "macOS Swift and Foundation are available"
        precondition(String(data: Data(message.utf8), encoding: .utf8) == message)
        print(message)
    }
}
""",
            encoding="utf-8",
        )
        executable = Path(directory) / "FoundationSmoke"
        host.compile(source, "-o", executable)
        subprocess.run([str(executable)], check=True, timeout=30)


if __name__ == "__main__":
    main()
