"""Exercise PaperDesk's floating question with synthetic local clients."""

import os
from pathlib import Path
import subprocess
import sys
import tempfile


CLIENT = r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import subprocess
import sys
import traceback


def report_synthetic_client_error(error_type, error, trace):
    log = os.environ.get("PAPERDESK_QUESTION_TEST_LOG")
    if log:
        Path(log).write_text("".join(traceback.format_exception(error_type, error, trace)), encoding="utf-8")


sys.excepthook = report_synthetic_client_error


def emit(**event):
    print(json.dumps(event), flush=True)


if Path(sys.argv[0]).name == "opencode" and sys.argv[1:3] == ["session", "list"]:
    assert Path("AGENTS.md").is_file(), "title lookup must run in the paper project"
    title = Path(os.environ["PAPERDESK_QUESTION_TEST_CLIENTS"], "opencode-title").read_text(encoding="utf-8")
    print(json.dumps([{"id": "ses_unrelated", "title": "Unrelated"},
                      {"id": "ses_paperdesk_fixture", "title": title}]))
    sys.exit(0)


def paperdesk(command, action):
    with subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True) as process:
        def call(name, **arguments):
            request = dict(jsonrpc="2.0", id=1, method="tools/call", params=dict(name=name, arguments=arguments))
            process.stdin.write(json.dumps(request) + "\n")
            process.stdin.flush()
            result = json.loads(process.stdout.readline())["result"]
            assert not result.get("isError"), result
            return result["structuredContent"]

        try:
            action(call)
        finally:
            process.stdin.close()
            process.wait(timeout=4)


prompt = sys.stdin.read()
if Path(sys.argv[0]).name == "codex":
    settings = dict(sys.argv[index + 1].split("=", 1) for index, arg in enumerate(sys.argv[:-1]) if arg == "-c")
    command = settings["mcp_servers.paperdesk.command"]
    assert r"\/" not in command and os.path.isfile(json.loads(command))
    assert "--question-request" in json.loads(settings["mcp_servers.paperdesk.args"])
    assert json.loads(settings["sandbox_mode"]) == "read-only"
    if "Legacy Codex continuation" in prompt:
        session = "018fcc03-c390-7c5b-8d0f-a952e9c104f3"
        assert "resume" in sys.argv and session in sys.argv
        answer = "Legacy Codex continuation answer"
    else:
        assert "Separate Codex question" in prompt and "resume" not in sys.argv
        session = "018fcc03-c390-7c5b-8d0f-a952e9c104f4"
        answer = "Codex answer"
    emit(type="thread.started", thread_id=session)
    emit(type="item.completed", item=dict(type="agent_message", text=answer))
    emit(type="turn.completed")
    sys.exit(0)

session = "ses_paperdesk_fixture"
if "Failed question" in prompt:
    sys.exit(2)
if "Follow-up question" in prompt:
    assert sys.argv[sys.argv.index("--session") + 1] == session
    answer = "Follow-up answer"
else:
    assert "First frozen question" in prompt and "--session" not in sys.argv
    answer = "First answer ⟦1⟧."
    connector = json.loads(os.environ["OPENCODE_CONFIG_CONTENT"])["mcp"]["paperdesk"]["command"]

    def check_original(call):
        snapshot = call("capture_reading_state")
        assert snapshot["current_page_index"] == 1
        assert [item["label"] for item in snapshot["selections"]] == ["A", "B", "C"]
        # This check covers citation/archive plumbing independently of the
        # public beta's narrow default sharing scope. The app self-check opts
        # this fixture into document scope explicitly below.
        assert call("reading_status")["scope"] == "document"
        quote = call("cite_passage", snapshot_id=snapshot["snapshot_id"], page_index=0, quote="Let H be a Hermitian operator")
        call("save_discussion", snapshot_id=snapshot["snapshot_id"], question="Transport wrapper is not the user question",
             answer=answer, source_context_ids=[snapshot["selections"][0]["context_id"]],
             citations=[dict(context_id=quote["citation_id"], label="1")], idempotency_key="synthetic")

    paperdesk(connector, check_original)

emit(type="step_start", sessionID=session, part=dict(type="step-start"))
emit(type="text", sessionID=session, part=dict(id="text-1", type="text", text=answer, sessionID=session))
emit(type="step_finish", sessionID=session, part=dict(type="step-finish", reason="stop"))
'''


with tempfile.TemporaryDirectory(prefix="paperdesk-questions-", dir="/private/tmp") as directory:
    for name in ("codex", "opencode"):
        path = Path(directory, name)
        path.write_text(CLIENT, encoding="utf-8")
        path.chmod(0o700)
    environment = os.environ.copy()
    Path(directory, "opencode-title").write_text("OpenCode session title", encoding="utf-8")
    Path(directory, "session_index.jsonl").write_text(
        '{"id":"018fcc03-c390-7c5b-8d0f-a952e9c104f3","thread_name":"Legacy Codex title"}\n'
        '{"id":"018fcc03-c390-7c5b-8d0f-a952e9c104f4","thread_name":"Separate Codex title"}\n', encoding="utf-8")
    environment["CODEX_HOME"] = directory
    environment["PATH"] = directory + os.pathsep + environment.get("PATH", os.defpath)
    environment["PAPERDESK_QUESTION_TEST_CLIENTS"] = directory
    environment["PAPERDESK_QUESTION_TEST_LOG"] = str(Path(directory, "client-error.log"))
    try:
        subprocess.run([Path(sys.argv[1]).resolve(), "--check-floating-question"], env=environment, check=True, timeout=45)
    except subprocess.CalledProcessError:
        diagnostic = Path(environment["PAPERDESK_QUESTION_TEST_LOG"])
        if diagnostic.exists():
            print("Synthetic client diagnostic:\n" + diagnostic.read_text(encoding="utf-8"), file=sys.stderr)
        raise
