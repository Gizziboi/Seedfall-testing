#!/usr/bin/env python3
"""v0.2.55g SEEDFALL bot swarm: the Opus report at the end of a swarm run, with a hard monthly spend cap (owner, 2026-11-24).

  swarm_report.py check  RES_DIR            -> exit 0 if this month's Opus spend leaves room for one more run, 3 if not (prints CAP lines)
  swarm_report.py apply  RES_DIR REC_JSON   -> writes a saved report + ledger record into a fresh clone (push retry; no API call)
  swarm_report.py report RES_DIR RUN [REC]  -> reads RES_DIR/swarm/runs/<RUN>-*/ (the 5 bots' results), asks Opus for a bug + balance
                                               report, writes RES_DIR/swarm/runs/<RUN>-report/report.md, adds the cost to the ledger
                                               RES_DIR/swarm/spend.json and RES_DIR/swarm/SPEND.md (the running monthly total)

Owner's rules carried here: the bots and this report are for BUG TESTING and BALANCE NUMBERS only, never the game's vision; the report
never changes anything by itself; the API key is only read from the environment (ANTHROPIC_API_KEY, a secret the owner adds himself) and
is never printed or written anywhere. The cap: before calling, the worst case of this call (exact input tokens from the free token-count
endpoint, or a pessimistic estimate, plus the full max output) is added to this month's total; if that would pass CAP_USD the call is NOT
made. Nothing from the report goes to the public log: only "REPORT ok / skipped" lines.
"""
import base64, datetime, glob, io, json, os, sys, urllib.request

CAP_USD = 50.0                 # owner: stop before total Opus spend passes $50 a month
MODEL = "claude-opus-5-5"
IN_USD = 4.0 / 1e6             # Opus 5.5 list price per input token
OUT_USD = 20.0 / 1e6           # per output token
MAX_OUT = 6000
MAX_IMAGES = 24
API = "https://api.anthropic.com/v1"

SYSTEM = (
    "You review automated playtest results for SEEDFALL, a top-down 2D alien destruction roguelike (Godot 4). Five bots ran an encrypted "
    "test build on cloud runners with no GPU (software rendering, so frame rates and timings say nothing about real performance). "
    "Your job is BUG TESTING and BALANCE NUMBERS ONLY. The game's owner decides the game's vision, content and design: do not suggest "
    "new features, content, art direction or design changes, and do not tell the owner what the game should be. For balance, report the "
    "numbers (threat reached, deaths and what killed the bot, level and time, upgrade picks, damage taken per 30 s) and where they jump; "
    "you may say a number looks out of line with the other species, but never propose a fix. For bugs, list each with: where (job, "
    "species / variant, test, screenshot name or log line), what you see, and how sure you are. Screenshots from a previous run may be "
    "included for comparison: only point out differences that look like breakage (missing UI, text over text, things drawn through the "
    "machines, stuck screens). Write plain Markdown, short sections: Bugs, Balance numbers, Run problems (crashes, timeouts, missing "
    "results). Be terse.")


def month() -> str:
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m")


def load_ledger(res: str) -> dict:
    p = os.path.join(res, "swarm", "spend.json")
    try:
        with open(p) as f:
            return json.load(f)
    except Exception:
        return {"cap_usd": CAP_USD, "months": {}}


def save_ledger(res: str, L: dict) -> None:
    os.makedirs(os.path.join(res, "swarm"), exist_ok=True)
    with open(os.path.join(res, "swarm", "spend.json"), "w") as f:
        json.dump(L, f, indent=1)
    m = L["months"].get(month(), {"usd": 0.0, "runs": []})
    lines = ["# SEEDFALL swarm: Opus spend", "", "Cap: $%.2f a month (owner). The report is skipped when a run could pass it." % CAP_USD, "",
             "**%s total: $%.4f** (%d report(s))" % (month(), m["usd"], len(m["runs"])), "", "| run | date (UTC) | input tok | output tok | cost | status |", "|---|---|---|---|---|---|"]
    for r in m["runs"]:
        lines.append("| %s | %s | %s | %s | $%.4f | %s |" % (r.get("run"), r.get("date"), r.get("in", 0), r.get("out", 0), r.get("usd", 0.0), r.get("status", "")))
    with open(os.path.join(res, "swarm", "SPEND.md"), "w") as f:
        f.write("\n".join(lines) + "\n")


def spent(L: dict) -> float:
    return float(L["months"].get(month(), {}).get("usd", 0.0))


def cmd_check(res: str) -> int:
    L = load_ledger(res)
    s = spent(L)
    # room for one more report: its worst case is bounded by MAX_IMAGES + the text limits below + MAX_OUT (about $0.35-0.45)
    worst = 200000 * IN_USD + MAX_OUT * OUT_USD
    if s + worst > CAP_USD:
        print("CAP reached for %s: the swarm does not run (owner's $%.0f monthly cap)" % (month(), CAP_USD))
        return 3
    print("CAP ok")
    return 0


def _jpeg_b64(path: str, width: int = 1024) -> str:
    from PIL import Image
    im = Image.open(path).convert("RGB")
    if im.width > width:
        im = im.resize((width, int(im.height * width / im.width)))
    b = io.BytesIO()
    im.save(b, "JPEG", quality=78)
    return base64.b64encode(b.getvalue()).decode()


def _tail(path: str, keep: int) -> str:
    try:
        with open(path, errors="replace") as f:
            t = f.read()
    except Exception:
        return ""
    return t if len(t) <= keep else "[... cut ...]\n" + t[-keep:]


def build_content(res: str, run: str) -> list:
    base = os.path.join(res, "swarm", "runs")
    mine = sorted(glob.glob(os.path.join(base, "%05d-*" % int(run))))
    mine = [d for d in mine if not d.endswith("-report")]
    content = [{"type": "text", "text": "Swarm run %s. Jobs: %s" % (run, ", ".join(os.path.basename(d) for d in mine) or "none")}]
    imgs = 0
    for d in mine:
        job = os.path.basename(d)
        content.append({"type": "text", "text": "\n## Job %s: summary.md\n%s" % (job, _tail(os.path.join(d, "summary.md"), 9000))})
        for lg in sorted(glob.glob(os.path.join(d, "logs", "*.log"))):
            errs = []
            with open(lg, errors="replace") as f:
                for line in f:
                    if any(k in line for k in ("SCRIPT ERROR", "ERROR:", "Invalid call", "Invalid access", "Out of bounds", "BOT_END", "_FAIL", "LEAK")):
                        errs.append(line.rstrip()[:300])
            if errs:
                content.append({"type": "text", "text": "### %s %s (errors / end lines, max 50)\n%s" % (job, os.path.basename(lg), "\n".join(errs[:50]))})
        shots = sorted(glob.glob(os.path.join(d, "shots", "*", "*.jpg")))
        per = 6 if "menus" in job else 3
        pick = shots[-per:] if len(shots) > per else shots
        for sp in pick:
            if imgs >= MAX_IMAGES:
                break
            content.append({"type": "text", "text": "Screenshot %s / %s" % (job, os.path.relpath(sp, d))})
            content.append({"type": "image", "source": {"type": "base64", "media_type": "image/jpeg", "data": _jpeg_b64(sp)}})
            imgs += 1
            # the menus bot's shots are compared with the same shot from the last swarm run that has it
            if "menus" in job and imgs < MAX_IMAGES:
                rel = os.path.relpath(sp, d)
                older = sorted(glob.glob(os.path.join(base, "*-" + job.split("-", 1)[1], rel)))
                older = [o for o in older if not o.startswith(d + os.sep)]
                if older:
                    content.append({"type": "text", "text": "Previous run's %s (for comparison)" % rel})
                    content.append({"type": "image", "source": {"type": "base64", "media_type": "image/jpeg", "data": _jpeg_b64(older[-1])}})
                    imgs += 1
    content.append({"type": "text", "text": "\nWrite the report now (bugs + balance numbers only)."})
    return content


def _post(path: str, body: dict, key: str) -> dict:
    req = urllib.request.Request(API + path, data=json.dumps(body).encode(), method="POST",
                                 headers={"x-api-key": key, "anthropic-version": "2023-06-01", "content-type": "application/json"})
    with urllib.request.urlopen(req, timeout=600) as r:
        return json.loads(r.read().decode())


def _write_out(res: str, run: str, rec: dict, text: str) -> None:
    L = load_ledger(res)
    M = L.setdefault("months", {}).setdefault(month(), {"usd": 0.0, "runs": []})
    if not any(str(r.get("run")) == str(run) for r in M["runs"]):
        M["runs"].append(rec)
        M["usd"] = round(float(M["usd"]) + float(rec.get("usd", 0.0)), 6)
    save_ledger(res, L)
    out_dir = os.path.join(res, "swarm", "runs", "%05d-report" % int(run))
    os.makedirs(out_dir, exist_ok=True)
    with open(os.path.join(out_dir, "report.md"), "w") as f:
        f.write("# SEEDFALL swarm run %s: Opus report\n\n%s\n\n---\nThis run: $%.4f (%d in / %d out tokens). %s total: $%.4f of the $%.0f cap.\n"
                % (run, text, float(rec.get("usd", 0.0)), int(rec.get("in", 0)), int(rec.get("out", 0)), month(), float(M["usd"]), CAP_USD))


def cmd_apply(res: str, rec_path: str) -> int:
    with open(rec_path) as f:
        d = json.load(f)
    _write_out(res, d["run"], d["rec"], d["text"])
    print("REPORT re-applied")
    return 0


def cmd_report(res: str, run: str, rec_path: str = "") -> int:
    key = os.environ.get("ANTHROPIC_API_KEY", "")
    L = load_ledger(res)
    M = L.setdefault("months", {}).setdefault(month(), {"usd": 0.0, "runs": []})
    rec = {"run": run, "date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M"), "in": 0, "out": 0, "usd": 0.0}

    def finish(status: str, text: str) -> int:
        rec["status"] = status
        _write_out(res, run, rec, text)
        if rec_path:
            with open(rec_path, "w") as f:
                json.dump({"run": run, "rec": rec, "text": text}, f)
        print("REPORT %s" % status)
        return 0

    if not key:
        return finish("skipped: no ANTHROPIC_API_KEY secret", "No report: the ANTHROPIC_API_KEY secret is not set in Gizziboi/Seedfall-testing.")
    content = build_content(res, run)
    body = {"model": MODEL, "max_tokens": MAX_OUT, "system": SYSTEM, "messages": [{"role": "user", "content": content}]}
    try:
        n_in = int(_post("/messages/count_tokens", {"model": MODEL, "system": SYSTEM, "messages": body["messages"]}, key)["input_tokens"])
    except Exception:
        # pessimistic: ~3 characters a token for the text + 1,600 tokens an image, + 30 %
        chars = sum(len(c.get("text", "")) for c in content if c["type"] == "text")
        n_in = int((chars / 3.0 + 1600 * sum(1 for c in content if c["type"] == "image")) * 1.3)
    worst = n_in * IN_USD + MAX_OUT * OUT_USD
    if float(M["usd"]) + worst > CAP_USD:
        return finish("skipped: monthly cap", "No report: this call (worst case $%.4f) would pass the $%.0f monthly cap (spent $%.4f)." % (worst, CAP_USD, float(M["usd"])))
    try:
        r = _post("/messages", body, key)
    except Exception as e:
        return finish("failed: API error", "No report: the API call failed (%s)." % type(e).__name__)
    u = r.get("usage", {})
    rec["in"] = int(u.get("input_tokens", 0)) + int(u.get("cache_creation_input_tokens", 0)) + int(u.get("cache_read_input_tokens", 0))
    rec["out"] = int(u.get("output_tokens", 0))
    rec["usd"] = round(int(u.get("input_tokens", 0)) * IN_USD + int(u.get("cache_creation_input_tokens", 0)) * 5.0 / 1e6
                       + int(u.get("cache_read_input_tokens", 0)) * 0.2 / 1e6 + rec["out"] * OUT_USD, 6)
    text = "".join(b.get("text", "") for b in r.get("content", []) if b.get("type") == "text")
    return finish("ok", text or "(empty reply)")


if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "check":
        sys.exit(cmd_check(sys.argv[2]))
    if len(sys.argv) >= 4 and sys.argv[1] == "apply":
        sys.exit(cmd_apply(sys.argv[2], sys.argv[3]))
    if len(sys.argv) >= 4 and sys.argv[1] == "report":
        sys.exit(cmd_report(sys.argv[2], sys.argv[3], sys.argv[4] if len(sys.argv) >= 5 else ""))
    print(__doc__)
    sys.exit(2)
