"""Run offline private-message checks. No test creates a network connection."""

import argparse
import json
from pathlib import Path
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile


HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
NATIVE = ROOT / "Sources/TiebaNative"
PROTOCOL = NATIVE / "Core/Networking/TiebaPrivateMessageProtocol.swift"
CACHE = NATIVE / "Features/Messages/TiebaPrivateMessageCache.swift"
TEST = HERE / "PrivateMessageTests.swift"
FIXTURES = HERE / "PrivateMessageFixtures.json"

# Protobuf text fixtures can be re-encoded with the pinned reference's actual
# schemas. Every identifier and message below is synthetic.
REFERENCE = "29d2aa2573eead7a0803ef2aa1eda9cd68b713d7"
PAYLOADS = {
    "groupMessages": ("get_group_msg", "GetGroupMsgResIdl", r'''
        data {
          groupInfo {
            groupInfo { groupId: 600 groupType: 6 }
            msgList {
              msgId: 9007199254740999 msgType: 1 content: "合成私信 🌱"
              createTime: 1700000000 userInfo { userId: 45 }
            }
            msgList {
              msgId: 9007199254741000 msgType: 18 content: "opaque test payload"
              createTime: 1700000000 userInfo { userId: 45 }
            }
            msgList {
              msgId: 9007199254740998 msgType: 1 content: "其他对象"
              createTime: 1699999999 userInfo { userId: 46 }
            }
            msgList {
              msgId: 9007199254741001 msgType: 22 userInfo { userId: 45 }
              content: "{\"eventId\":22001,\"eventParam\":{\"groupId\":600,\"readMsgId\":9007199254740999}}"
            }
            msgList {
              msgId: 9007199254741002 msgType: 22 userInfo { userId: 45 }
              content: "{\"eventId\":22001,\"eventParam\":{\"groupId\":601,\"readMsgId\":9007199254740999}}"
            }
            msgList {
              msgId: 1 msgType: 1 content: "self echo without recipient"
              createTime: 1700000000 userInfo { userId: 44 }
            }
            msgList {
              msgId: 2 msgType: 10 content: "notification in private group"
              createTime: 1700000000 userInfo { userId: 45 }
            }
          }
          groupInfo {
            groupInfo { groupId: 600 groupType: 8 }
            msgList { msgId: 3 msgType: 1 content: "activity" createTime: 1700000000 userInfo { userId: 45 } }
          }
          groupInfo {
            groupInfo { groupId: 601 groupType: 6 }
            msgList { msgId: 4 msgType: 1 content: "other group" createTime: 1700000000 userInfo { userId: 45 } }
          }
        }
    '''),
    "pushHints": ("push_notify", "PushNotifyResIdl", '''
        multiMsg { data { groupId: 600 msgId: 10 groupType: 6 type: 22 } }
        multiMsg { data { groupId: 600 msgId: 10 groupType: 6 type: 22 } }
        multiMsg { data { groupId: 600 msgId: 11 groupType: 8 } }
        multiMsg { data { groupId: 601 msgId: 11 groupType: 6 } }
    '''),
    "sendConfirmed": ("send_msg", "CommitPersonalMsgResIdl",
                      "data { msgId: 9007199254740999 groupId: 600 recordId: 953 toUid: 45 }"),
    "sendLegacy": ("send_msg", "CommitPersonalMsgResIdl", "data { msgId: 9007199254740999 }"),
    "sendWrongPeer": ("send_msg", "CommitPersonalMsgResIdl",
                      "data { msgId: 9007199254740999 groupId: 600 recordId: 953 toUid: 46 }"),
    "sendBlocked": ("send_msg", "CommitPersonalMsgResIdl", "data { blockInfo { blockErrno: 23 } }"),
    "sendRejected": ("send_msg", "CommitPersonalMsgResIdl", "error { errorno: -7 }"),
    "groupRejected": ("get_group_msg", "GetGroupMsgResIdl", "error { errorno: 14 }"),
}


def reference_fixtures(repo):
    actual = subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"], text=True).strip()
    if actual != REFERENCE:
        raise ValueError(f"Expected reference {REFERENCE}, got {actual}")
    root = repo / "src/aiotieba/api"
    output = {}
    for label, (folder, name, body) in PAYLOADS.items():
        proto_dir = root / folder / "protobuf"
        result = subprocess.run([
            "protoc", f"-I{proto_dir}", f"-I{root / '_protobuf'}",
            f"--encode={name}", f"{name}.proto",
        ], input=body.encode("utf-8"), cwd=proto_dir, check=True, capture_output=True, timeout=10)
        output[label] = result.stdout.hex()
    return output


def check_sql():
    source = CACHE.read_text(encoding="utf-8")
    statements = dict(re.findall(r'private static let (\w+SQL) = """\n(.*?)\n    """', source, re.S))
    db = sqlite3.connect(":memory:")
    try:
        db.executescript("CREATE TABLE visit_history (content TEXT); INSERT INTO visit_history VALUES ('existing');")
        db.executescript(statements["schemaSQL"])
        db.executescript(statements["schemaSQL"])
        assert db.execute("PRAGMA user_version").fetchone() == (1,)
        rows = [(600, 102, 45, 100, 1, "first"), (600, 101, 45, 100, 18, None),
                (600, 102, 46, 200, 1, "duplicate"), (601, 102, 48, 100, 1, "other group")]
        db.executemany(statements["insertSQL"], rows)
        conversation = statements["conversationsSQL"]
        assert db.execute(conversation, (600,)).fetchall() == [(102, 45, 100, 1, "first", 2)]
        history = statements["historySQL"]
        assert db.execute(history, (600, 45, 100, 102, 2)).fetchall() == [(101, 45, 100, 18, None)]
        assert db.execute(statements["readSQL"], (600, 46, 102)).rowcount == 0
        assert db.execute(statements["readSQL"], (600, 45, 102)).rowcount == 1
        assert db.execute(statements["readSQL"], (600, 45, 101)).rowcount == 0
        assert db.execute(conversation, (600,)).fetchone()[-1] == 0
        assert db.execute(conversation, (601,)).fetchone()[-1] == 1
        assert db.execute("SELECT content FROM visit_history").fetchone() == ("existing",)
    finally:
        db.close()
    print("PASS: production SQLite schema, duplicate, cursor, scope and local-read SQL", flush=True)


def check_sources():
    source = PROTOCOL.read_text(encoding="utf-8")
    if 'static let verifiedService: URL? = nil' not in source or 'url.scheme == "wss"' not in source:
        raise ValueError("Production IM endpoint must fail closed until verified")
    for file in (PROTOCOL, CACHE):
        text = file.read_text(encoding="utf-8")
        if any(symbol in text for symbol in ("URLSession", "TiebaSession", "BDUSS", "STOKEN", "UserNotifications")):
            raise ValueError(f"Unexpected transport, credentials or notification dependency in {file.name}")
    fixtures = json.loads(FIXTURES.read_text(encoding="utf-8"))
    if set(fixtures) != set(PAYLOADS) or not all(bytes.fromhex(value) for value in fixtures.values()):
        raise ValueError("Missing or malformed offline fixture")
    print("PASS: fail-closed production endpoint and offline fixture inventory", flush=True)


def syntax_check():
    from tree_sitter import Language, Parser
    import tree_sitter_swift

    parser = Parser(Language(tree_sitter_swift.language()))
    for file in (PROTOCOL, CACHE, TEST):
        if parser.parse(file.read_bytes()).root_node.has_error:
            raise ValueError(f"Syntax error in {file.name}")
    print("PASS: Swift syntax trees for protocol, cache and tests", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check-sources", action="store_true")
    parser.add_argument("--swift-syntax", action="store_true")
    parser.add_argument("--verify-reference", type=Path, help="re-encode fixture payloads from a pinned aiotieba checkout")
    args = parser.parse_args()
    check_sources()
    check_sql()
    if args.verify_reference:
        actual = reference_fixtures(args.verify_reference.resolve())
        if actual != json.loads(FIXTURES.read_text(encoding="utf-8")):
            raise ValueError("Fixture bytes differ from pinned upstream protobuf schemas")
        print("PASS: fixtures match protoc output from the pinned aiotieba schemas", flush=True)
    if args.swift_syntax:
        syntax_check()
    composer = ROOT / "docs/features/composer/run_composer_tests.py"
    if args.check_sources:
        subprocess.run([sys.executable, str(composer), "--check-sources"], check=True, timeout=60)
        return

    swiftc = shutil.which("swiftc")
    if not swiftc:
        parser.error("Swift 6 and a macOS SDK are required. Use --check-sources on Windows.")
    with tempfile.TemporaryDirectory(prefix="tieba-private-message-") as directory:
        executable = Path(directory) / "PrivateMessageTests"
        subprocess.run([
            swiftc, "-swift-version", "6", "-parse-as-library", "-lsqlite3",
            str(NATIVE / "Core/TiebaMutex.swift"), str(NATIVE / "Core/TiebaSQLite.swift"),
            str(PROTOCOL), str(CACHE), str(TEST), "-o", str(executable),
        ], check=True, timeout=120)
        subprocess.run([str(executable), str(FIXTURES)], check=True, timeout=30)
    subprocess.run([sys.executable, str(composer)], check=True, timeout=450)


if __name__ == "__main__":
    main()
