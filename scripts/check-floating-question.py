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
import signal
import subprocess
import sys
import time
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
assert all(field in prompt for field in ("cite_passage", "selection_context_id", "connection_policy", "⟦", "citations"))
if Path(sys.argv[0]).name == "codex":
    settings = dict(sys.argv[index + 1].split("=", 1) for index, arg in enumerate(sys.argv[:-1]) if arg == "-c")
    command = settings["mcp_servers.paperdesk.command"]
    assert r"\/" not in command and os.path.isfile(json.loads(command))
    assert "--question-request" in json.loads(settings["mcp_servers.paperdesk.args"])
    assert json.loads(settings["sandbox_mode"]) == "read-only"
    for tool in ("capture_reading_state", "cite_passage", "save_discussion"):
        assert json.loads(settings[f"mcp_servers.paperdesk.tools.{tool}.approval_mode"]) == "approve"
    if "First frozen question" in prompt:
        fixture = Path(os.environ["PAPERDESK_QUESTION_TEST_CLIENTS"])
        def stopped(_signal, _frame):
            (fixture / "codex-stopped").touch()
            sys.exit(0)
        signal.signal(signal.SIGTERM, stopped)
        emit(type="thread.started", thread_id="018fcc03-c390-7c5b-8d0f-a952e9c104f5")
        sys.stdout.write('{"type":"turn.')
        sys.stdout.flush()
        time.sleep(0.05)
        sys.stdout.write('started"}\n')
        sys.stdout.flush()
        (fixture / "codex-waiting").touch()
        time.sleep(10)
        raise AssertionError("The waiting Codex request was not stopped")
    if "Legacy Codex continuation" in prompt:
        session = "018fcc03-c390-7c5b-8d0f-a952e9c104f3"
        assert "resume" in sys.argv and session in sys.argv
        answer = "Legacy Codex continuation answer"
    else:
        assert "Separate Codex question" in prompt and "resume" not in sys.argv
        session = "018fcc03-c390-7c5b-8d0f-a952e9c104f4"
        answer = "Codex answer ⟦1⟧"
        connector = [json.loads(command)] + json.loads(settings["mcp_servers.paperdesk.args"])

        def cite_selection(call):
            status = call("paperdesk_connection_status")
            snapshot = call("capture_reading_state")
            assert snapshot["connection_policy"] == status and status["citation_mode"] == "selected_passages"
            citation = call("cite_passage", snapshot_id=snapshot["snapshot_id"],
                            selection_context_id=snapshot["context_id"])
            assert citation["number"] == 1

        paperdesk(connector, cite_selection)
    emit(type="thread.started", thread_id=session)
    emit(type="item.completed", item=dict(type="agent_message", text=answer))
    emit(type="turn.completed")
    sys.exit(0)

session = "ses_paperdesk_fixture"
if "Failed question" in prompt:
    sys.exit(2)
emit(type="step_start", sessionID=session, part=dict(type="step-start"))
if "Follow-up question" in prompt:
    assert sys.argv[sys.argv.index("--session") + 1] == session
    answer = "Follow-up answer"
else:
    assert "First frozen question" in prompt and "--session" not in sys.argv
    time.sleep(0.2)
    answer = "First answer ⟦1⟧."
    connector = json.loads(os.environ["OPENCODE_CONFIG_CONTENT"])["mcp"]["paperdesk"]["command"]

    def check_original(call):
        snapshot = call("capture_reading_state")
        assert snapshot["current_page_index"] == 1
        assert [item["label"] for item in snapshot["selections"]] == ["A", "B", "C"]
        assert snapshot["connection_policy"]["citation_mode"] == "selected_passages"
        quote = call("cite_passage", snapshot_id=snapshot["snapshot_id"],
                     selection_context_id=snapshot["selections"][0]["context_id"])
        call("save_discussion", snapshot_id=snapshot["snapshot_id"], question="Transport wrapper is not the user question",
             answer=answer, source_context_ids=[snapshot["selections"][0]["context_id"]],
             citations=[dict(context_id=quote["citation_id"], label="1")], idempotency_key="synthetic")

    paperdesk(connector, check_original)

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
