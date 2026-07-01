#!/usr/bin/env bash
# Commit nlp_user_examples.jsonl with an auto-generated message describing
# exactly what the bot learned since the last commit.
set -e
cd "$(dirname "$0")"

if git diff --quiet nlp_user_examples.jsonl && git diff --cached --quiet nlp_user_examples.jsonl; then
    echo "No changes in nlp_user_examples.jsonl — nothing to commit."
    exit 0
fi

# Parse new lines from diff and build commit body
BODY=$(python3 - <<'PYEOF'
import subprocess, json, sys

diff = subprocess.check_output(["git", "diff", "nlp_user_examples.jsonl"], text=True)
if not diff:
    diff = subprocess.check_output(["git", "diff", "--cached", "nlp_user_examples.jsonl"], text=True)

LABELS = {
    "plot":               "plot [sensor]",
    "pressure_reading":   "pressure reading",
    "temperature_reading":"temperature reading",
    "pump_status":        "pump status",
    "heater_status":      "heater status",
    "valve_status":       "valve status",
    "change_threshold":   "change threshold",
    "reset_threshold":    "reset threshold",
    "sentinel":           "sentinel on/off",
    "set_mode":           "set mode",
    "ack":                "acknowledge alert",
    "daily_summary":      "daily summary",
    "help":               "help",
    "status":             "current status",
    "pause_alerts":       "pause alerts",
    "resume_alerts":      "resume alerts",
    "unknown":            "unknown",
}

lines = []
for raw in diff.splitlines():
    if not raw.startswith("+{"):
        continue
    try:
        e = json.loads(raw[1:])
    except Exception:
        continue
    text     = e.get("text", "")
    intent   = e.get("intent", "?")
    source   = e.get("source", "user")
    from_i   = e.get("from_intent")
    label    = LABELS.get(intent, intent)
    from_lbl = LABELS.get(from_i, from_i) if from_i else None

    if source == "corrected" and from_lbl:
        lines.append(f'- Corrected: "{text}" — was [{from_lbl}], now [{label}]')
    elif source == "corrected":
        lines.append(f'- Corrected: "{text}" → [{label}]')
    elif source == "confirmed":
        lines.append(f'- Confirmed: "{text}" → [{label}]')
    elif source == "inferred":
        lines.append(f'- Inferred:  "{text}" → [{label}]')
    else:
        lines.append(f'- Learned:   "{text}" → [{label}]')

if not lines:
    print("(no parseable new examples)")
else:
    print("\n".join(lines))
PYEOF
)

COUNT=$(echo "$BODY" | grep -c "^-" || true)
TITLE="NLP: record ${COUNT} user-taught example(s)"

git add nlp_user_examples.jsonl
git commit -m "$(printf '%s\n\n%s\n\nCo-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>' "$TITLE" "$BODY")"
git push origin main

echo ""
echo "Pushed to GitHub:"
echo "$BODY"
