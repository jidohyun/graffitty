"""Build deterministic agent turns whose tool steps execute the visible commands."""
import json
import os
import re
import shlex
from pathlib import Path
import sys

output, url, diagram_directory = Path(sys.argv[1]), sys.argv[2], Path(sys.argv[3])

def tool(name, command, ms=1375):
    if os.name == "nt":
        command = command.replace("$DEMO_RUNTIME", "$env:DEMO_RUNTIME").replace(" > /dev/null", " > $null")
        command = command.replace("| jq -e '.result == true' > $null",
            "| ConvertFrom-Json | ForEach-Object { if ($_.result -ne $true) { throw 'Chromium assertion failed' } }")
        command = re.sub(r"printf '([^']*)\\n'", lambda match: "Write-Output '" + match[1] + "'", command)
        script = "$ErrorActionPreference='Stop'; $PSNativeCommandUseErrorActionPreference=$true; " + command
        return {"type": "tool", "name": "PowerShell" if name == "Bash" else name, "input": command,
                "command": ["pwsh.exe", "-NoProfile", "-Command", script], "ms": ms, "preview_lines": 2}
    return {"type": "tool", "name": name, "input": command,
            "command": ["/bin/sh", "-ec", command], "ms": ms, "preview_lines": 2}

def snapshot(name, chromium, file):
    if os.name == "nt":
        return tool(name, f'gft chromium snapshot --target {chromium} | Tee-Object -FilePath "$env:DEMO_RUNTIME/{file}" | '
                    'ConvertFrom-Json | ForEach-Object { $_.result.elements | ForEach-Object { "$($_.ref) $($_.name)" } }')
    return tool(name, f'gft chromium snapshot --target {chromium} | tee "$DEMO_RUNTIME/{file}" | '
                     "jq -r '.result.elements[] | \"\\(.ref) \\(.name)\"'")

def reference(file, name):
    if os.name == "nt":
        return f'"$((Get-Content -Raw -LiteralPath "$env:DEMO_RUNTIME/{file}" | ConvertFrom-Json).result.elements | Where-Object name -EQ \'{name}\' | Select-Object -ExpandProperty ref)"'
    return f'"$(jq -r \'.result.elements[] | select(.name == "{name}") | .ref\' "$DEMO_RUNTIME/{file}")"'

def chromium_reference(file):
    if os.name == "nt":
        return f'"$((Get-Content -Raw -LiteralPath "$env:DEMO_RUNTIME/{file}" | ConvertFrom-Json).result.chromium)"'
    return f'"$(jq -r .result.chromium "$DEMO_RUNTIME/{file}")"'

def button_click(target, count):
    click = f"gft chromium click --target {target} --ref {reference('button-snapshot.json', 'Increment')}"
    wait = f"gft chromium wait --target {target} --selector '#count' --text '{count}' --timeout-ms 750"
    # A pane can be resized while an agent is clicking. Retry the real pointer
    # action when its expected page update is not observed; still assert below.
    if os.name == "nt":
        return f"foreach ($attempt in 1..3) {{ {click}; try {{ {wait}; break }} catch {{ if ($attempt -eq 3) {{ throw }} }} }}"
    return f"for attempt in 1 2 3; do {click}; if {wait}; then break; fi; done"


chromium = chromium_reference("claude-chromium.json")
claude = [{"type": "message", "text": "I'll click the button and verify that the counter updates."},
          tool("Bash", f'gft chromium new --url {url}/button.html | tee "$DEMO_RUNTIME/claude-chromium.json"'),
          tool("Bash", f"gft chromium wait --target {chromium} --selector '#increment'")]
for i in range(1, 81):
    claude += [snapshot("Bash", chromium, "button-snapshot.json"),
               tool("Bash", button_click(chromium, i)),
               tool("Bash", f"gft chromium eval --target {chromium} --expression \"Number(document.querySelector('#count').textContent) === {i}\""
                    + f" | jq -e '.result == true' > /dev/null\nprintf 'PASS: counter = {i}\\n'")]

chromium = chromium_reference("codex-chromium.json")
codex = [{"type": "message", "text": "I'll test adding a task and marking it complete in Chromium."},
         tool("exec_command", f'gft chromium new --url {url}/tasks.html | tee "$DEMO_RUNTIME/codex-chromium.json"'),
         tool("exec_command", f"gft chromium wait --target {chromium} --selector 'form'")]
for i in range(1, 41):
    codex += [snapshot("exec_command", chromium, "task-snapshot.json"),
              tool("exec_command", f'gft chromium fill --target {chromium} --ref {reference("task-snapshot.json", "New task")} --text "Review step {i}"'),
              tool("exec_command", f'gft chromium click --target {chromium} --ref {reference("task-snapshot.json", "Add task")}'),
              snapshot("exec_command", chromium, "task-snapshot.json"),
              tool("exec_command", f'gft chromium click --target {chromium} --ref {reference("task-snapshot.json", "Complete")}'),
              tool("exec_command", f"gft chromium eval --target {chromium} --expression \"document.querySelector('li.done span')?.textContent === 'Review step {i}'\""
                   + f" | jq -e '.result == true' > /dev/null\nprintf 'PASS: task {i} added and completed\\n'")]

for provider, steps, prompt in [
    ("claude", claude, "Use graffitty chromium to run the button test"),
    ("codex", codex, "Use graffitty chromium to run the E2E test"),
]:
    config = {"animation_clock": str(output / "animation-clock"),
              "palette": {"foreground": [255, 255, 255], "background": [40, 44, 52]},
              "real_tool_calling": True, "char_ms": 23, "tip": "", "turns": [
        {"prompt": prompt, "steps": steps, "response": "All interaction checks passed."}]}
    if provider == "codex":
        config["model"] = "GPT-6-Astra medium"
    else:
        diagram = diagram_directory / "http-request.html"
        write = tool("Write", f'cat "$DEMO_RUNTIME/http-request-source.html" > {shlex.quote(str(diagram))} && cp {shlex.quote(str(diagram))} "$DEMO_RUNTIME/http-request.html"', ms=750)
        write["input"] = str(diagram)
        config["turns"].insert(0, {
            "prompt": "Explain an HTTP request with a diagram in graffitty chromium.",
            "steps": [
                {"type": "message", "text": "I'll draw the request and response, then open it beside our conversation."},
                write,
                tool("Bash", f'gft chromium open {shlex.quote(str(diagram))} --new | tee "$DEMO_RUNTIME/diagram-chromium.json"', ms=750),
            ],
            "response": "The chromium sends a request. The server returns HTML, and the chromium renders the page. The diagram is open in Chromium.",
        })
    (output / (provider + ".json")).write_text(json.dumps(config, indent=2) + "\n")
