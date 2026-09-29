#!/usr/bin/env python3
"""Behavioural tests for .github/workflows/telegram-ci-summary.yml.

The real `run:` script of the notifier step is extracted from the workflow
file and executed under bash. Only the network is replaced: `curl` is a
fake that serves recorded GitHub API responses (check-runs and
commits/<sha>/pulls) from a scenario directory and captures the Telegram
sendMessage payload; the poll/timeout knobs are set to zero so a missing
or running check reaches its timeout branch immediately.

No repository secrets and no network are used. Exit code 0 = all pass.
"""
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORKFLOW = os.path.join(ROOT, ".github", "workflows", "telegram-ci-summary.yml")

REPO = "ekucher/BRAVO-Toolkit"
PUSH_SHA = "40ac0847856b7c1ca03415bc12ab3a0385e99082"
TOKEN = "TESTBOT:SENTINEL-TOKEN-NOT-REAL"
CHAT = "-100SENTINELCHAT"
RESPONSE_MARKER = "SENTINEL-RESPONSE-BODY"

PUSH_CHECKS = [
    "Parser / BOM / JSON (push)",
    "PSScriptAnalyzer (push)",
    "BRAVO_SELF_TEST.ps1 (push)",
    "BRAVO_DATA_RESTORE_MATRIX_TEST.ps1 (push)",
    "Secret scanning (gitleaks) (push)",
]
PR_CHECKS = [
    "Parser / BOM / JSON",
    "PSScriptAnalyzer",
    "BRAVO_SELF_TEST.ps1",
    "BRAVO_DATA_RESTORE_MATRIX_TEST.ps1",
    "Secret scanning (gitleaks)",
    "Config parity (BRAVO_CONFIG_LOADER)",
    "Build + verify + happy-path + rollback + failure-injection",
    "GitGuardian Security Checks",
]

FAKE_CURL = r'''#!/usr/bin/env bash
# Fake curl for the notifier tests: no network.
set -u
scenario="$FAKE_SCENARIO_DIR"
url=""
out=""
writeout=""
data=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output) out="$2"; shift 2 ;;
    --write-out) writeout="$2"; shift 2 ;;
    --data) data="$2"; shift 2 ;;
    --header|--retry|--retry-delay|--connect-timeout|--max-time|--request)
      shift 2 ;;
    --*) shift ;;
    *) url="$1"; shift ;;
  esac
done
echo "$url" >> "$scenario/requests.log"
case "$url" in
  https://api.telegram.org/bot*/sendMessage)
    count_file="$scenario/telegram.count"
    n=0
    [ -f "$count_file" ] && n="$(cat "$count_file")"
    n=$((n + 1))
    echo "$n" > "$count_file"
    cp "${data#@}" "$scenario/telegram-$n.json"
    status="$(cat "$scenario/telegram.status" 2>/dev/null || echo 200)"
    body="$(cat "$scenario/telegram.body" 2>/dev/null || echo '{"ok":true}')"
    if [ -n "$out" ]; then printf '%s' "$body" > "$out"; fi
    if [ -n "$writeout" ]; then printf '%s' "$status"; fi
    exit 0
    ;;
  https://api.github.com/repos/*/commits/*/check-runs*)
    sha="${url#*/commits/}"; sha="${sha%%/*}"
    cat "$scenario/checkruns-$sha.json" 2>/dev/null || echo '{"check_runs":[]}'
    exit 0
    ;;
  https://api.github.com/repos/*/commits/*/pulls*)
    sha="${url#*/commits/}"; sha="${sha%%/*}"
    cat "$scenario/pulls-$sha.json" 2>/dev/null || echo '[]'
    exit 0
    ;;
esac
echo "unexpected URL: $url" >&2
exit 22
'''


def extract_step_script(step_name):
    """Return the `run: |` body of the named step, dedented."""
    with open(WORKFLOW, "r", encoding="utf-8", newline="") as handle:
        lines = handle.read().replace("\r\n", "\n").split("\n")
    header = "      - name: " + step_name
    start = lines.index(header)
    run_index = next(i for i in range(start, len(lines)) if lines[i] == "        run: |")
    body = []
    for line in lines[run_index + 1:]:
        if line.strip() and not line.startswith("          "):
            break
        body.append(line[10:] if line.startswith("          ") else "")
    return "\n".join(body) + "\n"


def check_run(name, status="completed", conclusion="success", started="2026-09-29T18:00:00Z", run_id=1):
    item = {"id": run_id, "name": name, "status": status, "started_at": started,
            "details_url": "https://example.invalid/" + str(run_id)}
    item["conclusion"] = conclusion if status == "completed" else None
    return item


def all_checks(names, **overrides):
    """Every check success, with per-name overrides (dict name -> list of runs or one run kwargs)."""
    runs = []
    next_id = 100
    for name in names:
        spec = overrides.get(name, {})
        if isinstance(spec, list):
            runs.extend(spec)
        elif spec == "missing":
            continue
        else:
            runs.append(check_run(name, run_id=next_id, **spec))
        next_id += 1
    return {"check_runs": runs}


def pr_entry(number, base="developer", merged_at=None, merge_sha="x", head="h", state="open"):
    return {"number": number, "state": state, "base": {"ref": base}, "merged_at": merged_at,
            "merge_commit_sha": merge_sha, "head": {"sha": head},
            "html_url": "https://github.com/%s/pull/%d" % (REPO, number)}


class Scenario(object):
    def __init__(self, workdir):
        self.dir = workdir

    def write(self, name, payload):
        with open(os.path.join(self.dir, name), "w", encoding="utf-8") as handle:
            if isinstance(payload, str):
                handle.write(payload)
            else:
                json.dump(payload, handle)


def run_notifier(script, scenario_setup, extra_env=None, step="notify"):
    workdir = tempfile.mkdtemp(prefix="tgsummary-")
    try:
        bindir = os.path.join(workdir, "bin")
        os.mkdir(bindir)
        curl_path = os.path.join(bindir, "curl")
        with open(curl_path, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(FAKE_CURL)
        os.chmod(curl_path, os.stat(curl_path).st_mode | stat.S_IEXEC)
        sleep_path = os.path.join(bindir, "sleep")
        with open(sleep_path, "w", encoding="utf-8", newline="\n") as handle:
            handle.write("#!/usr/bin/env bash\nexit 0\n")
        os.chmod(sleep_path, os.stat(sleep_path).st_mode | stat.S_IEXEC)
        scenario = Scenario(workdir)
        scenario_setup(scenario)
        env = {
            "PATH": bindir + os.pathsep + os.environ.get("PATH", ""),
            "HOME": workdir,
            "FAKE_SCENARIO_DIR": workdir,
            "GH_TOKEN": "fake-github-token",
            "TELEGRAM_BOT_TOKEN": TOKEN,
            "TELEGRAM_CHAT_ID": CHAT,
            "GITHUB_SHA": PUSH_SHA,
            "GITHUB_REPOSITORY": REPO,
            "GITHUB_SERVER_URL": "https://github.com",
            "GITHUB_ACTOR": "ekucher",
            "GITHUB_RUN_ATTEMPT": "1",
            "TELEGRAM_SUMMARY_PUSH_WAIT_SECONDS": "0",
            "TELEGRAM_SUMMARY_PR_WAIT_SECONDS": "0",
            "TELEGRAM_SUMMARY_POLL_SECONDS": "0",
            "ICON_OK": "[OK]", "ICON_FAIL": "[FAIL]", "ICON_WARN": "[WARN]", "ICON_SKIP": "[SKIP]",
            "ICON_TEST": "[TEST]", "ICON_LINK": "[LINK]", "ICON_BRANCH": "[BRANCH]",
            "ICON_COMMIT": "[COMMIT]", "ICON_USER": "[USER]", "ICON_PR": "[PR]",
        }
        env.update(extra_env or {})
        proc = subprocess.run(["bash", "-c", script], env=env, cwd=workdir,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120)
        result = {
            "rc": proc.returncode,
            "log": proc.stdout.decode("utf-8", "replace") + proc.stderr.decode("utf-8", "replace"),
            "messages": [],
            "requests": [],
        }
        for index in range(1, 10):
            path = os.path.join(workdir, "telegram-%d.json" % index)
            if os.path.exists(path):
                with open(path, "r", encoding="utf-8") as handle:
                    result["messages"].append(json.load(handle))
        requests_log = os.path.join(workdir, "requests.log")
        if os.path.exists(requests_log):
            with open(requests_log, "r", encoding="utf-8") as handle:
                result["requests"] = handle.read().split()
        return result
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


FAILURES = []
PASSED = []


def check(name, condition, detail=""):
    if condition:
        PASSED.append(name)
        print("[PASS] " + name)
    else:
        FAILURES.append(name)
        print("[FAIL] %s %s" % (name, detail))


def text_of(result):
    return result["messages"][0]["text"] if result["messages"] else ""


def main():
    notifier = extract_step_script("Wait for checks and send one Telegram summary")
    validate = extract_step_script("Validate required secrets")

    def push_only(push_overrides=None):
        def setup(sc):
            sc.write("checkruns-%s.json" % PUSH_SHA, all_checks(PUSH_CHECKS, **(push_overrides or {})))
            sc.write("pulls-%s.json" % PUSH_SHA, [pr_entry(258, head="aaa"), pr_entry(259, head="bbb")])
        return setup

    # A. 5/5 success, direct push (only open PRs are associated) -> SUCCESS, N/A
    r = run_notifier(notifier, push_only())
    text = text_of(r)
    check("A 5/5 success -> SUCCESS", r["rc"] == 0 and "Result: SUCCESS" in text
          and "post-merge checks: 5/5" in text, r["log"] + text)

    # F. direct push: no merged PR -> pre-merge N/A, not an error, one message
    check("F direct push -> pre-merge N/A, rc 0, one message",
          r["rc"] == 0 and "PR pre-merge checks: N/A" in text and len(r["messages"]) == 1
          and "pull/" not in text, r["log"] + text)

    # B. one completed failure, rest success -> FAILED
    r = run_notifier(notifier, push_only({PUSH_CHECKS[2]: {"conclusion": "failure"}}))
    text = text_of(r)
    check("B one failure + rest success -> FAILED",
          r["rc"] == 0 and "Result: FAILED" in text and "post-merge checks: 4/5" in text, text)

    # C. failure + another check missing at timeout -> FAILED (not INCOMPLETE)
    r = run_notifier(notifier, push_only({PUSH_CHECKS[0]: {"conclusion": "failure"},
                                          PUSH_CHECKS[3]: "missing"}))
    text = text_of(r)
    check("C failure + missing at timeout -> FAILED", "Result: FAILED" in text, text)
    r = run_notifier(notifier, push_only({PUSH_CHECKS[0]: {"conclusion": "failure"},
                                          PUSH_CHECKS[3]: {"status": "in_progress"}}))
    check("C2 failure + in_progress at timeout -> FAILED", "Result: FAILED" in text_of(r), text_of(r))
    r = run_notifier(notifier, push_only({PUSH_CHECKS[1]: {"conclusion": "cancelled"},
                                          PUSH_CHECKS[4]: {"status": "queued"}}))
    check("C3 cancelled + queued -> FAILED", "Result: FAILED" in text_of(r), text_of(r))

    # D. no failure, one missing / in_progress / queued after timeout -> INCOMPLETE
    for label, spec in (("missing", "missing"), ("in_progress", {"status": "in_progress"}),
                        ("queued", {"status": "queued"})):
        r = run_notifier(notifier, push_only({PUSH_CHECKS[3]: spec}))
        text = text_of(r)
        check("D no failure + %s at timeout -> INCOMPLETE" % label,
              r["rc"] == 0 and "Result: INCOMPLETE" in text and "post-merge checks: 4/5" in text, text)

    # skipped / neutral are not success
    r = run_notifier(notifier, push_only({PUSH_CHECKS[0]: {"conclusion": "skipped"}}))
    check("skipped is not success -> FAILED", "Result: FAILED" in text_of(r), text_of(r))

    # E. duplicate check name: newest run wins
    older_fail_newer_ok = [check_run(PUSH_CHECKS[2], conclusion="failure", started="2026-09-29T18:00:00Z", run_id=10),
                           check_run(PUSH_CHECKS[2], conclusion="success", started="2026-09-29T18:30:00Z", run_id=11)]
    r = run_notifier(notifier, push_only({PUSH_CHECKS[2]: older_fail_newer_ok}))
    check("E older failure + newer success -> SUCCESS", "Result: SUCCESS" in text_of(r), text_of(r))
    older_ok_newer_fail = [check_run(PUSH_CHECKS[2], conclusion="success", started="2026-09-29T18:00:00Z", run_id=10),
                           check_run(PUSH_CHECKS[2], conclusion="failure", started="2026-09-29T18:30:00Z", run_id=11)]
    r = run_notifier(notifier, push_only({PUSH_CHECKS[2]: older_ok_newer_fail}))
    check("E older success + newer failure -> FAILED", "Result: FAILED" in text_of(r), text_of(r))
    reordered = list(reversed(older_fail_newer_ok))
    r = run_notifier(notifier, push_only({PUSH_CHECKS[2]: reordered}))
    check("E order in API response does not matter", "Result: SUCCESS" in text_of(r), text_of(r))

    # G. associated merged PR (real-shaped list: open PRs + the merged PR) with pre-merge checks
    pr_head = "5740480a1b2c3d4e5f60718293a4b5c6d7e8f901"
    later_pr_head = "9d24a58c722add1918f3b469fae1f5fac7300015"

    def with_pr(pr_overrides=None, push_overrides=None):
        def setup(sc):
            sc.write("checkruns-%s.json" % PUSH_SHA, all_checks(PUSH_CHECKS, **(push_overrides or {})))
            sc.write("checkruns-%s.json" % pr_head, all_checks(PR_CHECKS, **(pr_overrides or {})))
            sc.write("pulls-%s.json" % PUSH_SHA, [
                pr_entry(258, head="46a9058aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", merge_sha="07d7921"),
                pr_entry(265, merged_at="2026-09-29T18:09:21Z", merge_sha="f6eed40", head="a4e93c0", state="closed"),
                pr_entry(266, merged_at="2026-09-29T18:53:24Z", merge_sha=PUSH_SHA, head=pr_head, state="closed"),
                pr_entry(267, head=later_pr_head, merge_sha="83d2768"),
                pr_entry(270, base="main", merged_at="2026-09-29T19:00:00Z", merge_sha=PUSH_SHA, head="ccc", state="closed"),
                # merged into developer LATER (rerun scenario): its branch also contains the commit
                pr_entry(269, merged_at="2026-09-29T19:30:00Z", merge_sha="deadbee", head=later_pr_head, state="closed"),
            ])
        return setup

    r = run_notifier(notifier, with_pr())
    text = text_of(r)
    pr_check_requests = [u for u in r["requests"] if "/check-runs" in u]
    check("G merged PR: correct number, URL, 8/8 pre-merge, 5/5 post-merge",
          r["rc"] == 0 and "Result: SUCCESS" in text and "PR #266 pre-merge checks: 8/8" in text
          and "post-merge checks: 5/5" in text and ("https://github.com/%s/pull/266" % REPO) in text
          and "#265" not in text and "#267" not in text and "#258" not in text and "#270" not in text and "#269" not in text, text)
    check("G final head SHA of the merged PR is the one queried",
          any(pr_head in u for u in pr_check_requests)
          and not any(later_pr_head in u for u in pr_check_requests), "\n".join(r["requests"]))
    check("G every required PR check name is reported",
          all(("%s: success" % name) in text for name in PR_CHECKS), text)

    # PR-layer precedence
    r = run_notifier(notifier, with_pr({PR_CHECKS[7]: {"conclusion": "failure"}}))
    check("H PR check failure + push success -> FAILED",
          "Result: FAILED" in text_of(r) and "pre-merge checks: 7/8" in text_of(r), text_of(r))
    r = run_notifier(notifier, with_pr({PR_CHECKS[5]: "missing"}))
    check("H PR check missing + push success -> INCOMPLETE",
          "Result: INCOMPLETE" in text_of(r) and "pre-merge checks: 7/8" in text_of(r), text_of(r))
    r = run_notifier(notifier, with_pr({PR_CHECKS[5]: "missing"}, {PUSH_CHECKS[0]: {"conclusion": "failure"}}))
    check("H push failure + PR check missing -> FAILED", "Result: FAILED" in text_of(r), text_of(r))
    r = run_notifier(notifier, with_pr({PR_CHECKS[5]: {"conclusion": "failure"}}, {PUSH_CHECKS[0]: {"status": "in_progress"}}))
    check("H PR failure + push in_progress -> FAILED", "Result: FAILED" in text_of(r), text_of(r))

    # I. payload contract
    r = run_notifier(notifier, with_pr(), extra_env={"ICON_OK": "\u2705", "ICON_PR": "\U0001F500"})
    message = r["messages"][0] if r["messages"] else {}
    text = message.get("text", "")
    check("I exactly one Telegram message per run", len(r["messages"]) == 1, str(len(r["messages"])))
    check("I no parse_mode, plain chat_id + text only",
          set(message.keys()) == {"chat_id", "text"} and message.get("chat_id") == CHAT, str(message.keys()))
    check("I text is far below the Telegram limit", 0 < len(text) < 2000, str(len(text)))
    check("I text carries result, branch, short sha, actor, both layers and links",
          all(part in text for part in ("Result: SUCCESS", "developer", PUSH_SHA[:7], "ekucher",
                                        "post-merge checks: 5/5", "PR #266 pre-merge checks: 8/8",
                                        "/commit/%s/checks" % PUSH_SHA, "/pull/266")), text)
    check("I Unicode icons survive into the JSON payload", "\u2705" in text, text)
    check("I no token, chat id or response body in the job log",
          TOKEN not in r["log"] and CHAT not in r["log"] and RESPONSE_MARKER not in r["log"], r["log"])
    check("I success log line", "Telegram CI summary delivered successfully." in r["log"], r["log"])

    # J. Telegram failures are surfaced, never printed
    def telegram_status(status, body):
        base = with_pr()
        def setup(sc):
            base(sc)
            sc.write("telegram.status", str(status))
            sc.write("telegram.body", body)
        return setup

    r = run_notifier(notifier, telegram_status(500, '{"ok":false,"%s":1}' % RESPONSE_MARKER))
    check("J HTTP 500 -> non-zero, body/secrets not printed",
          r["rc"] != 0 and "HTTP 500" in r["log"] and RESPONSE_MARKER not in r["log"]
          and TOKEN not in r["log"] and CHAT not in r["log"], r["log"])
    r = run_notifier(notifier, telegram_status(200, '{"ok":false,"%s":1}' % RESPONSE_MARKER))
    check("J HTTP 200 with ok:false -> non-zero, body not printed",
          r["rc"] != 0 and "did not confirm delivery" in r["log"] and RESPONSE_MARKER not in r["log"], r["log"])

    # K. missing secrets fail before anything is sent
    r = run_notifier(validate, push_only(), extra_env={"TELEGRAM_BOT_TOKEN": ""})
    check("K empty bot token -> validation fails", r["rc"] != 0 and "TELEGRAM_BOT_TOKEN" in r["log"], r["log"])
    r = run_notifier(validate, push_only(), extra_env={"TELEGRAM_CHAT_ID": ""})
    check("K empty chat id -> validation fails", r["rc"] != 0 and "TELEGRAM_CHAT_ID" in r["log"], r["log"])
    r = run_notifier(validate, push_only())
    check("K both secrets present -> validation passes, nothing printed",
          r["rc"] == 0 and TOKEN not in r["log"] and CHAT not in r["log"], r["log"])

    # L. static security invariants of the workflow (structure, not wording)
    with open(WORKFLOW, "r", encoding="utf-8") as handle:
        workflow_text = handle.read().replace("\r\n", "\n")
    executable = "\n".join(line for line in workflow_text.split("\n") if not line.lstrip().startswith("#"))
    check("L push to developer only, no pull_request trigger",
          re.search(r"^on:\n  push:\n    branches: \[developer\]\n", workflow_text, re.M) is not None
          and "pull_request" not in executable)
    check("L no checkout and no third-party actions", "uses:" not in executable)
    check("L secrets are referenced only as job-level env, never inside run lines",
          "secrets." not in extract_step_script("Wait for checks and send one Telegram summary")
          and "secrets." not in extract_step_script("Validate required secrets"))
    check("L permissions are minimal read-only",
          re.search(r"^permissions:\n  contents: read\n  checks: read\n  pull-requests: read\n", workflow_text, re.M) is not None)
    check("L run lines are ASCII-only", all(ord(ch) < 128 for ch in extract_step_script("Wait for checks and send one Telegram summary")))

    print("\npassed=%d failed=%d" % (len(PASSED), len(FAILURES)))
    return 1 if FAILURES else 0


if __name__ == "__main__":
    sys.exit(main())
