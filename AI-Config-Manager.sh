#!/usr/bin/env bash
# AI Config Manager for macOS
#
# Arrow-key TUI to point Claude Code, OpenCode, and Codex at a custom gateway
# (AgentRouter, EuroModels, or any OpenAI/Anthropic-compatible base URL), and to
# launch Hermes Desktop's own model setup. Presets live in AI-Config-Presets.json;
# model lists are fetched live when the gateway allows it, with curated fallbacks.
#
# Requires Bash 3.2+ and curl. Existing config files are backed up before every write.
#
# Usage:   ./AI-Config-Manager.sh
# Selftest: ./AI-Config-Manager.sh -SelfTest

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRESETS_FILE="$SCRIPT_DIR/AI-Config-Presets.json"

load_dotenv() {
    local env_file=""
    if [ -f "$SCRIPT_DIR/.env" ]; then
        env_file="$SCRIPT_DIR/.env"
    elif [ -f "$SCRIPT_DIR/.env.local" ]; then
        env_file="$SCRIPT_DIR/.env.local"
    fi

    if [ -n "$env_file" ]; then
        while IFS='=' read -r key val || [ -n "$key" ]; do
            key=$(echo "$key" | xargs)
            if [[ -z "$key" || "$key" =~ ^# ]]; then
                continue
            fi
            val=$(echo "$val" | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")
            if [ -n "$key" ] && [ -n "$val" ]; then
                export "$key=$val"
            fi
        done < "$env_file"
    fi
}

load_dotenv

# Pure scroll-window math
get_scroll_window() {
    local selected="$1"
    local count="$2"
    local page_size="$3"
    local current_top="$4"

    if [ "$count" -le "$page_size" ]; then
        echo 0
        return
    fi
    if [ "$selected" -lt "$current_top" ]; then
        echo "$selected"
        return
    fi
    if [ "$selected" -ge "$((current_top + page_size))" ]; then
        echo "$((selected - page_size + 1))"
        return
    fi
    echo "$current_top"
}

# Selftest runner
if [ "$1" = "-SelfTest" ] || [ "$1" = "--selftest" ]; then
    assert_equal() {
        local a="$1"
        local b="$2"
        local msg="$3"
        if [ "$a" -ne "$b" ]; then
            echo -e "\033[31mFAIL: $msg (expected $b, got $a)\033[0m"
            exit 1
        fi
        echo -e "\033[90mok: $msg\033[0m"
    }

    assert_equal "$(get_scroll_window 5 10 5 0)" 1 "down: selection just past window"
    assert_equal "$(get_scroll_window 9 10 5 0)" 5 "down: selection near end"
    assert_equal "$(get_scroll_window 0 10 5 3)" 0 "up: selection above window"
    assert_equal "$(get_scroll_window 0 3 5 0)" 0 "count fits page"
    assert_equal "$(get_scroll_window 2 100 5 50)" 2 "up: from far window"
    assert_equal "$(get_scroll_window 3 100 5 0)" 0 "within window: no change"
    echo -e "\033[32mAll self-test checks passed.\033[0m"
    exit 0
fi

# TTY device determination
TTY_DEV="/dev/tty"
if [ ! -c "$TTY_DEV" ]; then
    TTY_DEV="/dev/stdin"
fi

if [ ! -t 0 ] && [ ! -c "/dev/tty" ]; then
    echo -e "\033[31mThis TUI requires an interactive terminal. Run it directly, not piped.\033[0m"
    exit 1
fi

# ANSI Colors
CYAN='\033[0;36m'
CYAN_BG='\033[46;30m'
GRAY='\033[0;90m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
RESET='\033[0m'

write_banner() {
    local title="$1"
    local len="${#title}"
    local line=""
    for ((i=0; i<len+2; i++)); do line="${line}─"; done
    echo "" >&2
    echo -e "  ${CYAN}${title}${RESET}" >&2
    echo -e "  ${CYAN}${line}${RESET}" >&2
    echo "" >&2
}

pause_screen() {
    echo "" >&2
    read -p "Press Enter to continue" dummy < "$TTY_DEV"
}

normalize_base_url() {
    python3 -c 'import sys; print(sys.argv[1].strip().rstrip("/"))' "$1"
}

get_models_endpoint() {
    local base
    base=$(normalize_base_url "$1")
    if [[ "$base" =~ /v1$ ]]; then
        echo "$base/models"
    else
        echo "$base/v1/models"
    fi
}

mask_key() {
    local key="$1"
    if [ -z "$key" ]; then
        echo "(empty)"
        return
    fi
    local len="${#key}"
    if [ "$len" -le 8 ]; then
        python3 -c 'import sys; print("*" * int(sys.argv[1]))' "$len"
        return
    fi
    python3 -c '
import sys
k = sys.argv[1]
l = len(k)
mid_len = min(12, l - 8)
print(k[:4] + ("*" * mid_len) + k[-4:])
' "$key"
}

backup_file() {
    local path="$1"
    if [ -f "$path" ]; then
        local stamp
        stamp=$(date +"%Y%m%d-%H%M%S")
        local backup="${path}.backup-${stamp}"
        cp "$path" "$backup"
        echo "$backup"
    else
        echo ""
    fi
}

set_macos_env_var() {
    local key="$1"
    local val="$2"

    export "$key=$val"

    local target_profile=""
    if [ -f "$HOME/.zshrc" ]; then
        target_profile="$HOME/.zshrc"
    elif [ -f "$HOME/.zprofile" ]; then
        target_profile="$HOME/.zprofile"
    else
        target_profile="$HOME/.zshrc"
    fi

    python3 -c '
import os, sys, re
key = sys.argv[1]
val = sys.argv[2]
profile = sys.argv[3]

line = f"export {key}=\"{val}\"\n"
pattern = r"^\s*export\s+" + re.escape(key) + r"\s*=.*$"

content = ""
if os.path.exists(profile):
    with open(profile, "r", encoding="utf-8", errors="ignore") as f:
        content = f.read()

lines = content.splitlines(True)
found = False
new_lines = []

for l in lines:
    if re.match(pattern, l):
        new_lines.append(line)
        found = True
    else:
        new_lines.append(l)

if not found:
    if new_lines and not new_lines[-1].endswith("\n"):
        new_lines.append("\n")
    new_lines.append(line)

with open(profile, "w", encoding="utf-8") as f:
    f.writelines(new_lines)
' "$key" "$val" "$target_profile"
}

# TUI Menu drawer and handler
show_menu() {
    local title="$1"
    shift
    local default_idx=0
    local options=()
    local headers=()

    # Parse remaining arguments
    local parsing_options=1
    while [ "$#" -gt 0 ]; do
        if [ "$1" == "--header" ]; then
            parsing_options=0
            shift
            continue
        elif [ "$1" == "--default" ]; then
            shift
            default_idx="$1"
            shift
            continue
        fi

        if [ "$parsing_options" -eq 1 ]; then
            options+=("$1")
        else
            headers+=("$1")
        fi
        shift
    done

    local count="${#options[@]}"
    if [ "$count" -eq 0 ]; then
        echo -1
        return
    fi

    local selected="$default_idx"
    if [ "$selected" -ge "$count" ]; then
        selected=$((count - 1))
    fi

    local top=0

    # Save terminal settings
    local term_state
    term_state=$(stty -g < "$TTY_DEV" 2>/dev/null || echo "")

    while true; do
        clear >&2
        write_banner "$title"

        for h in "${headers[@]}"; do
            echo -e "  ${GRAY}${h}${RESET}" >&2
        done
        if [ "${#headers[@]}" -gt 0 ]; then
            echo "" >&2
        fi

        local term_lines
        term_lines=$(tput lines < "$TTY_DEV" 2>/dev/null || echo 24)
        local page_size=$((term_lines - 9 - ${#headers[@]}))
        if [ "$page_size" -lt 5 ]; then
            page_size=5
        fi

        top=$(get_scroll_window "$selected" "$count" "$page_size" "$top")
        local last=$((top + page_size - 1))
        if [ "$last" -ge "$count" ]; then
            last=$((count - 1))
        fi

        for ((i=top; i<=last; i++)); do
            if [ "$i" -eq "$selected" ]; then
                echo -e "${CYAN_BG} > ${options[$i]}${RESET}" >&2
            else
                echo -e "   ${options[$i]}" >&2
            fi
        done

        if [ "$top" -gt 0 ] || [ "$last" -lt $((count - 1)) ]; then
            echo "" >&2
            echo -e "  ${GRAY}($((top + 1))-$((last + 1)) of ${count})${RESET}" >&2
        fi

        echo "" >&2
        echo -e "  ${GRAY}Up/Dn navigate | Enter select | Esc back${RESET}" >&2

        # Read key input directly from TTY
        stty raw -echo < "$TTY_DEV" 2>/dev/null
        local char1
        char1=$(dd bs=1 count=1 < "$TTY_DEV" 2>/dev/null)

        if [ "$char1" = $'\x1b' ]; then
            stty -icanon min 0 time 1 < "$TTY_DEV" 2>/dev/null
            local rest
            rest=$(dd bs=2 count=1 < "$TTY_DEV" 2>/dev/null)
            if [ -n "$term_state" ]; then stty "$term_state" < "$TTY_DEV" 2>/dev/null; else stty sane < "$TTY_DEV" 2>/dev/null; fi

            case "$rest" in
                "[A") # Up
                    if [ "$selected" -gt 0 ]; then selected=$((selected - 1)); fi
                    ;;
                "[B") # Down
                    if [ "$selected" -lt $((count - 1)) ]; then selected=$((selected + 1)); fi
                    ;;
                "[H") # Home
                    selected=0
                    ;;
                "[F") # End
                    selected=$((count - 1))
                    ;;
                "") # ESC
                    if [ -n "$term_state" ]; then stty "$term_state" < "$TTY_DEV" 2>/dev/null; else stty sane < "$TTY_DEV" 2>/dev/null; fi
                    echo -1
                    return
                    ;;
            esac
        elif [ "$char1" = $'\x0a' ] || [ "$char1" = $'\x0d' ] || [ -z "$char1" ]; then
            if [ -n "$term_state" ]; then stty "$term_state" < "$TTY_DEV" 2>/dev/null; else stty sane < "$TTY_DEV" 2>/dev/null; fi
            echo "$selected"
            return
        else
            if [ -n "$term_state" ]; then stty "$term_state" < "$TTY_DEV" 2>/dev/null; else stty sane < "$TTY_DEV" 2>/dev/null; fi
        fi
    done
}

load_presets() {
    if [ ! -f "$PRESETS_FILE" ]; then
        echo -e "${RED}Preset file not found: $PRESETS_FILE${RESET}" >&2
        exit 1
    fi
    python3 -c '
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        data = json.load(f)
    print(json.dumps(data.get("presets", [])))
except Exception as e:
    sys.stderr.write(f"Preset file is invalid JSON: {e}\n")
    sys.exit(1)
' "$PRESETS_FILE"
}

get_live_models() {
    local base_url="$1"
    local api_key="$2"
    local endpoint
    endpoint=$(get_models_endpoint "$base_url")

    echo "" >&2
    echo -e "${GRAY}Fetching models from: $endpoint${RESET}" >&2

    local tmp
    tmp=$(mktemp)
    local http_code
    http_code=$(curl -sS --fail-with-body --connect-timeout 15 --max-time 45 \
        -H "Authorization: Bearer $api_key" \
        -H "Accept: application/json" \
        -o "$tmp" -w "%{http_code}" "$endpoint" 2>/dev/null || echo "000")

    if [[ ! "$http_code" =~ ^2 ]]; then
        rm -f "$tmp"
        echo "FAIL: HTTP $http_code"
        return 1
    fi

    local ids
    ids=$(python3 -c '
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        data = json.load(f)
    res = []
    if "data" in data and isinstance(data["data"], list):
        for x in data["data"]:
            if isinstance(x, str): res.append(x)
            elif isinstance(x, dict) and "id" in x: res.append(str(x["id"]))
    elif "models" in data and isinstance(data["models"], list):
        for x in data["models"]:
            if isinstance(x, str): res.append(x)
            elif isinstance(x, dict):
                if "id" in x: res.append(str(x["id"]))
                elif "name" in x: res.append(str(x["name"]))
    res = sorted(list(set([x for x in res if x])))
    print(json.dumps(res))
except Exception:
    print("[]")
' "$tmp")

    rm -f "$tmp"
    echo "$ids"
}

get_agentrouter_pricing_models() {
    local url="$1"
    echo "" >&2
    echo -e "${GRAY}Fetching model list from: $url${RESET}" >&2

    local tmp
    tmp=$(mktemp)
    local http_code
    http_code=$(curl -sS --fail-with-body --connect-timeout 15 --max-time 45 \
        -H "Accept: application/json" \
        -o "$tmp" -w "%{http_code}" "$url" 2>/dev/null || echo "000")

    if [[ ! "$http_code" =~ ^2 ]]; then
        rm -f "$tmp"
        echo "FAIL: HTTP $http_code"
        return 1
    fi

    local result
    result=$(python3 -c '
import json, sys, re
try:
    with open(sys.argv[1], "r", encoding="utf-8", errors="ignore") as f:
        text = f.read()
    text = re.sub(r",\"usable_group\"\s*:\s*\{[^}]*\}", "", text)
    data = json.loads(text)
    if not data.get("success"):
        print("FAIL: success=false")
        sys.exit(0)
    items = data.get("data", [])
    claude = []
    opencode = []
    for item in items:
        mname = item.get("model_name")
        endpoints = item.get("supported_endpoint_types", [])
        if mname:
            if "anthropic" in endpoints: claude.append(mname)
            if "openai" in endpoints: opencode.append(mname)
    print(json.dumps({"claude": sorted(list(set(claude))), "opencode": sorted(list(set(opencode)))}))
except Exception as e:
    print(f"FAIL: {e}")
' "$tmp")

    rm -f "$tmp"
    echo "$result"
}

merge_models() {
    python3 -c '
import json, sys
live = json.loads(sys.argv[1]) if sys.argv[1] else []
curated = json.loads(sys.argv[2]) if sys.argv[2] else []
merged = sorted(list(set([x for x in (live + curated) if x])))
print(json.dumps(merged))
' "$1" "$2"
}

configure_claude() {
    local base_url="$1"
    local api_key="$2"
    local model="$3"

    local claude_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    local path="$claude_dir/settings.json"
    local backup
    backup=$(backup_file "$path")

    mkdir -p "$(dirname "$path")"

    python3 -c '
import json, sys, os

path = sys.argv[1]
base_url = sys.argv[2].strip().rstrip("/")
api_key = sys.argv[3]
model = sys.argv[4]

cfg = {}
if os.path.exists(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            cfg = json.load(f)
    except Exception:
        cfg = {}

if "env" not in cfg or not isinstance(cfg["env"], dict):
    cfg["env"] = {}

cfg["env"]["ANTHROPIC_BASE_URL"] = base_url
cfg["env"]["ANTHROPIC_AUTH_TOKEN"] = api_key
cfg["env"]["ANTHROPIC_MODEL"] = model
cfg["model"] = model

with open(path, "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2)
' "$path" "$base_url" "$api_key" "$model"

    echo "PATH:$path"
    echo "BACKUP:$backup"
}

configure_claude_desktop() {
    local base_url="$1"
    local api_key="$2"
    local model="$3"
    local auth_scheme="${4:-x-api-key}"

    local dir=""
    if [ -d "$HOME/Library/Application Support/Claude-3p" ]; then
        dir="$HOME/Library/Application Support/Claude-3p"
    elif [ -d "$HOME/Library/Application Support/Claude" ]; then
        dir="$HOME/Library/Application Support/Claude"
    else
        dir="$HOME/Library/Application Support/Claude-3p"
    fi

    local library_dir="$dir/configLibrary"
    local meta_path="$library_dir/_meta.json"

    if [ ! -f "$meta_path" ]; then
        echo "ERROR: Claude Desktop configLibrary not found at $meta_path. Install and launch the Claude Desktop app once so it initializes its config."
        return 1
    fi

    local applied_id
    applied_id=$(python3 -c '
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        data = json.load(f)
    print(data.get("appliedId", ""))
except Exception:
    print("")
' "$meta_path")

    if [ -z "$applied_id" ]; then
        echo "ERROR: No appliedId in $meta_path. Open the Claude Desktop app once so it writes its active config entry."
        return 1
    fi

    local cfg_path="$library_dir/${applied_id}.json"
    local backup
    backup=$(backup_file "$cfg_path")

    python3 -c '
import json, sys, os

cfg_path = sys.argv[1]
base_url = sys.argv[2].strip().rstrip("/")
api_key = sys.argv[3]
auth_scheme = sys.argv[4]
model = sys.argv[5]

cfg = {}
if os.path.exists(cfg_path):
    try:
        with open(cfg_path, "r", encoding="utf-8") as f:
            cfg = json.load(f)
    except Exception:
        cfg = {}

cfg["inferenceProvider"] = "gateway"
cfg["inferenceGatewayBaseUrl"] = base_url
cfg["inferenceGatewayApiKey"] = api_key
cfg["inferenceGatewayAuthScheme"] = auth_scheme
cfg["inferenceModels"] = [model]

with open(cfg_path, "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2)
' "$cfg_path" "$base_url" "$api_key" "$auth_scheme" "$model"

    echo "PATH:$cfg_path"
    echo "BACKUP:$backup"
}

configure_opencode() {
    local base_url="$1"
    local api_key="$2"
    local model="$3"
    local provider_key="$4"
    local provider_name="$5"
    local npm_package="$6"

    local path="$HOME/.config/opencode/opencode.json"
    local backup
    backup=$(backup_file "$path")

    mkdir -p "$(dirname "$path")"

    python3 -c '
import json, sys, os

path = sys.argv[1]
base_url = sys.argv[2].strip().rstrip("/")
api_key = sys.argv[3]
model = sys.argv[4]
provider_key = sys.argv[5]
provider_name = sys.argv[6]
npm_package = sys.argv[7]

cfg = {}
if os.path.exists(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            cfg = json.load(f)
    except Exception:
        cfg = {}

cfg["$schema"] = "https://opencode.ai/config.json"
if "provider" not in cfg or not isinstance(cfg["provider"], dict):
    cfg["provider"] = {}

provider_obj = {
    "npm": npm_package,
    "name": provider_name,
    "options": {
        "baseURL": base_url,
        "apiKey": api_key
    },
    "models": {
        model: {"name": model}
    }
}

cfg["provider"][provider_key] = provider_obj
cfg["model"] = f"{provider_key}/{model}"

with open(path, "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2)
' "$path" "$base_url" "$api_key" "$model" "$provider_key" "$provider_name" "$npm_package"

    echo "PATH:$path"
    echo "BACKUP:$backup"
}

configure_codex() {
    local base_url="$1"
    local api_key="$2"
    local model="$3"
    local provider_key="$4"
    local provider_name="$5"

    local dir="$HOME/.codex"
    local auth_path="$dir/auth.json"
    local config_path="$dir/config.toml"

    local auth_backup
    auth_backup=$(backup_file "$auth_path")
    local config_backup
    config_backup=$(backup_file "$config_path")

    mkdir -p "$dir"

    python3 -c '
import json, sys, os

path = sys.argv[1]
api_key = sys.argv[2]

auth = {}
if os.path.exists(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            auth = json.load(f)
    except Exception:
        auth = {}

auth["auth_mode"] = "apikey"
auth["OPEN_API_KEY"] = api_key
auth["OPENAI_API_KEY"] = api_key

with open(path, "w", encoding="utf-8") as f:
    json.dump(auth, f, indent=2)
' "$auth_path" "$api_key"

    local provider="custom"
    if [ -n "$provider_key" ] && [ "$provider_key" != "openai" ]; then
        provider="$provider_key"
    fi
    if [ -z "$provider_name" ]; then
        provider_name="$provider"
    fi

    local env_key
    env_key=$(python3 -c '
import sys, re
p = sys.argv[1]
cleaned = re.sub(r"[^A-Z0-9]", "_", p.upper())
print(f"{cleaned}_API_KEY")
' "$provider")

    python3 -c '
import sys, os, re

config_path = sys.argv[1]
provider = sys.argv[2]
model = sys.argv[3]
provider_name = sys.argv[4]
base_url = sys.argv[5].strip().rstrip("/")
env_key = sys.argv[6]
api_key = sys.argv[7]

def set_toml_value(text, key, value):
    escaped_val = value.replace("\\", "\\\\").replace("\"", "\\\"")
    line = f"{key} = \"{escaped_val}\""
    pattern = r"(?m)^\s*" + re.escape(key) + r"\s*=.*$"
    
    first_table = re.search(r"(?m)^[ \t]*\[", text)
    if first_table:
        head = text[:first_table.start()]
        tail = text[first_table.start():]
    else:
        head = text
        tail = ""
        
    tail = re.sub(r"(?m)^[ \t]*" + re.escape(key) + r"[ \t]*=.*\r?\n?", "", tail)
    
    if re.search(pattern, head):
        head = re.sub(pattern, line, head, count=1)
    else:
        if head and not head.endswith("\n"):
            head += "\n"
        head += line + "\n"
    return head + tail

def set_toml_bare_value(text, key, value):
    line = f"{key} = {value}"
    pattern = r"(?m)^\s*" + re.escape(key) + r"\s*=.*$"
    
    first_table = re.search(r"(?m)^[ \t]*\[", text)
    if first_table:
        head = text[:first_table.start()]
        tail = text[first_table.start():]
    else:
        head = text
        tail = ""
        
    tail = re.sub(r"(?m)^[ \t]*" + re.escape(key) + r"[ \t]*=.*\r?\n?", "", tail)
    
    if re.search(pattern, head):
        head = re.sub(pattern, line, head, count=1)
    else:
        if head and not head.endswith("\n"):
            head += "\n"
        head += line + "\n"
    return head + tail

def set_toml_env_policy_value(text, key, value):
    escaped_val = value.replace("\\", "\\\\").replace("\"", "\\\"")
    line = f"{key} = \"{escaped_val}\""
    
    table_pattern = r"(?ms)^([ \t]*\[shell_environment_policy\.set\][ \t]*\r?\n)(.*?)(?=^\s*\[|\z)"
    m = re.search(table_pattern, text)
    if m:
        header = m.group(1)
        body = m.group(2)
        key_pattern = r"(?m)^[ \t]*" + re.escape(key) + r"[ \t]*=.*$"
        if re.search(key_pattern, body):
            body = re.sub(key_pattern, line, body, count=1)
        else:
            if body and not body.endswith("\n"):
                body += "\n"
            body += line + "\n"
        return text[:m.start()] + header + body + text[m.end():]
        
    if text and not text.endswith("\n"):
        text += "\n"
    return text + "\n[shell_environment_policy.set]\n" + line + "\n"

toml = ""
if os.path.exists(config_path):
    with open(config_path, "r", encoding="utf-8", errors="ignore") as f:
        toml = f.read()

toml = set_toml_value(toml, "model_provider", provider)
toml = set_toml_value(toml, "model", model)
toml = set_toml_value(toml, "preferred_auth_method", "apikey")
toml = set_toml_bare_value(toml, "disable_response_storage", "true")

section_pattern = r"(?ms)^\s*\[model_providers\." + re.escape(provider) + r"\]\s*.*?(?=^\s*\[|\z)"
escaped_name = provider_name.replace("\\", "\\\\").replace("\"", "\\\"")
escaped_base = base_url.replace("\\", "\\\\").replace("\"", "\\\"")
section = f"[model_providers.{provider}]\nname = \"{escaped_name}\"\nbase_url = \"{escaped_base}\"\nenv_key = \"{env_key}\"\n"

if re.search(section_pattern, toml):
    toml = re.sub(section_pattern, section, toml, count=1)
else:
    if toml and not toml.endswith("\n"):
        toml += "\n"
    toml += f"\n{section}"

def repair_toml(toml_text):
    pattern = r"(?ms)^([ \t]*\[model_providers\.([a-zA-Z0-9_\-]+)\][ \t]*\r?\n)(.*?)(?=^\s*\[|\z)"
    def fix_section(m):
        header = m.group(1)
        prov_id = m.group(2)
        body = m.group(3)
        if re.search(r"(?m)^\s*name\s*=\s*\"\"\s*$", body):
            body = re.sub(r"(?m)^\s*name\s*=\s*\"\"\s*$", f"name = \"{prov_id}\"", body, count=1)
        return header + body
    return re.sub(pattern, fix_section, toml_text)

toml = repair_toml(toml)

with open(config_path, "w", encoding="utf-8") as f:
    f.write(toml)
' "$config_path" "$provider" "$model" "$provider_name" "$base_url" "$env_key" "$api_key"

    set_macos_env_var "$env_key" "$api_key"

    echo "AUTH_PATH:$auth_path"
    echo "AUTH_BACKUP:$auth_backup"
    echo "CONFIG_PATH:$config_path"
    echo "CONFIG_BACKUP:$config_backup"
}

invoke_hermes_setup() {
    if ! command -v hermes >/dev/null 2>&1; then
        echo -e "${YELLOW}Hermes is not installed. Install Hermes first, then rerun this option.${RESET}" >&2
        pause_screen
        return
    fi

    echo -e "${CYAN}Launching Hermes model setup. Complete prompts manually.${RESET}" >&2
    hermes model
    local ret=$?
    if [ "$ret" -ne 0 ]; then
        echo -e "${YELLOW}Hermes model setup exited with code $ret.${RESET}" >&2
    fi
    pause_screen
}

show_current() {
    clear >&2
    write_banner "Current Configuration"

    local claude_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    local cp="$claude_dir/settings.json"
    echo -e "  ${GRAY}Claude Code: $cp${RESET}" >&2

    python3 -c '
import json, os, sys

def mask(key):
    if not key: return "(empty)"
    l = len(key)
    if l <= 8: return "*" * l
    mid = min(12, l - 8)
    return key[:4] + ("*" * mid) + key[-4:]

cp = sys.argv[1]
if os.path.exists(cp):
    try:
        with open(cp, "r", encoding="utf-8") as f:
            c = json.load(f)
        env = c.get("env", {})
        base_url = env.get("ANTHROPIC_BASE_URL", "")
        model_name = c.get("model", "")
        auth_token = mask(env.get("ANTHROPIC_AUTH_TOKEN", ""))
        print(f"    Base URL: {base_url}")
        print(f"    Model:    {model_name}")
        print(f"    API Key:  {auth_token}")
    except Exception:
        print("    \033[33mCould not parse config.\033[0m")
else:
    print("    \033[90mNo config found.\033[0m")
' "$cp" >&2

    local os_base="$ANTHROPIC_BASE_URL"
    if [ -n "$os_base" ]; then
        echo -e "    ${GRAY}OS env:   ANTHROPIC_BASE_URL=$os_base${RESET}" >&2
        if [ -n "$ANTHROPIC_MODEL" ]; then
            echo -e "              ${GRAY}ANTHROPIC_MODEL=$ANTHROPIC_MODEL${RESET}" >&2
        fi
    fi

    echo "" >&2
    echo -e "  ${GRAY}macOS environment variables${RESET}" >&2
    python3 -c '
import os

def mask(key):
    if not key: return "(empty)"
    l = len(key)
    if l <= 8: return "*" * l
    mid = min(12, l - 8)
    return key[:4] + ("*" * mid) + key[-4:]

vars_to_check = ["ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_MODEL", "OPENAI_API_KEY", "AGENTROUTER_API_KEY", "EUROMODELS_API_KEY", "CUSTOM_API_KEY"]
for v in vars_to_check:
    val = os.environ.get(v)
    if val:
        disp = mask(val) if "KEY" in v or "TOKEN" in v else val
        print(f"    {v}={disp}")
' >&2

    echo "" >&2
    echo -e "  ${GRAY}Claude Desktop: 3P gateway config${RESET}" >&2
    local cd_dir=""
    if [ -d "$HOME/Library/Application Support/Claude-3p" ]; then
        cd_dir="$HOME/Library/Application Support/Claude-3p"
    elif [ -d "$HOME/Library/Application Support/Claude" ]; then
        cd_dir="$HOME/Library/Application Support/Claude"
    fi

    if [ -n "$cd_dir" ] && [ -f "$cd_dir/configLibrary/_meta.json" ]; then
        python3 -c '
import json, os, sys

def mask(key):
    if not key: return "(empty)"
    l = len(key)
    if l <= 8: return "*" * l
    mid = min(12, l - 8)
    return key[:4] + ("*" * mid) + key[-4:]

cd_dir = sys.argv[1]
meta_path = os.path.join(cd_dir, "configLibrary", "_meta.json")
try:
    with open(meta_path, "r", encoding="utf-8") as f:
        meta = json.load(f)
    applied_id = meta.get("appliedId", "")
    cfg_path = os.path.join(cd_dir, "configLibrary", f"{applied_id}.json")
    if applied_id and os.path.exists(cfg_path):
        with open(cfg_path, "r", encoding="utf-8") as f:
            cfg = json.load(f)
        b_url = cfg.get("inferenceGatewayBaseUrl", "")
        a_scheme = cfg.get("inferenceGatewayAuthScheme", "")
        a_key = mask(cfg.get("inferenceGatewayApiKey", ""))
        print(f"    Config: {cfg_path}")
        print(f"    Base URL:    {b_url}")
        print(f"    Auth scheme: {a_scheme}")
        print(f"    API Key:     {a_key}")
        models = [m for m in cfg.get("inferenceModels", []) if m]
        if models:
            m_joined = ", ".join(models)
            print(f"    Models:      {m_joined}")
    else:
        print("    \033[90mNo active config entry.\033[0m")
except Exception:
    print("    \033[33mCould not parse Claude Desktop config.\033[0m")
' "$cd_dir" >&2
    else
        echo -e "    ${GRAY}No configLibrary found (Claude Desktop not installed or not launched).${RESET}" >&2
    fi

    echo "" >&2
    local op="$HOME/.config/opencode/opencode.json"
    echo -e "  ${GRAY}OpenCode: $op${RESET}" >&2
    python3 -c '
import json, os, sys

def mask(key):
    if not key: return "(empty)"
    l = len(key)
    if l <= 8: return "*" * l
    mid = min(12, l - 8)
    return key[:4] + ("*" * mid) + key[-4:]

op = sys.argv[1]
if os.path.exists(op):
    try:
        with open(op, "r", encoding="utf-8") as f:
            o = json.load(f)
        providers = o.get("provider", {})
        model_str = o.get("model", "")
        prefix = model_str.split("/")[0] if "/" in model_str else ""
        if prefix in providers:
            p = providers[prefix]
            opts = p.get("options", {})
            b_url = opts.get("baseURL", "")
            a_key = mask(opts.get("apiKey", ""))
            print(f"    Provider: {prefix} (active)")
            print(f"    Base URL: {b_url}")
            print(f"    Model:    {model_str}")
            print(f"    API Key:  {a_key}")
        else:
            print(f"    Model:    {model_str}")
            print(f"    \033[33mNo provider matches model prefix \"{prefix}\".\033[0m")
    except Exception:
        print("    \033[33mCould not parse config.\033[0m")
else:
    print("    \033[90mNo config found.\033[0m")
' "$op" >&2

    local codex_dir="$HOME/.codex"
    local codex_auth="$codex_dir/auth.json"
    local codex_config="$codex_dir/config.toml"
    echo "" >&2
    echo -e "  ${GRAY}Codex: $codex_dir${RESET}" >&2
    python3 -c '
import json, os, sys, re

def mask(key):
    if not key: return "(empty)"
    l = len(key)
    if l <= 8: return "*" * l
    mid = min(12, l - 8)
    return key[:4] + ("*" * mid) + key[-4:]

auth_path = sys.argv[1]
config_path = sys.argv[2]

if os.path.exists(auth_path):
    try:
        with open(auth_path, "r", encoding="utf-8") as f:
            ca = json.load(f)
        key = ca.get("OPENAI_API_KEY") or (ca.get("tokens", {}).get("access_token") if isinstance(ca.get("tokens"), dict) else None)
        print(f"    auth.json API Key: {mask(key)}")
    except Exception:
        print("    \033[33mCould not parse auth.json.\033[0m")
else:
    print("    \033[90mNo auth.json found.\033[0m")

if os.path.exists(config_path):
    print(f"    config.toml: {config_path}")
    with open(config_path, "r", encoding="utf-8", errors="ignore") as f:
        toml = f.read()
    m_model = re.search(r"(?m)^\s*model\s*=\s*\"([^\"]+)\"", toml)
    m_prov = re.search(r"(?m)^\s*model_provider\s*=\s*\"([^\"]+)\"", toml)
    if m_model: print(f"      Model: {m_model.group(1)}")
    if m_prov:  print(f"      Provider: {m_prov.group(1)}")
else:
    print("    \033[90mNo config.toml found.\033[0m")
' "$codex_auth" "$codex_config" >&2

    pause_screen
}

# Main Application Loop
presets_json=$(load_presets)

preset_count=$(python3 -c 'import json, sys; print(len(json.loads(sys.argv[1])))' "$presets_json")

while true; do
    target_idx=$(show_menu "AI Config Manager" \
        "Configure Claude Code" \
        "Configure OpenCode" \
        "Configure Codex" \
        "Configure Hermes Desktop" \
        "Configure Claude Desktop" \
        "Configure Both (Claude Code + OpenCode)" \
        "View current configuration" \
        "Exit")

    if [ "$target_idx" -eq -1 ] || [ "$target_idx" -eq 7 ]; then
        break
    fi

    if [ "$target_idx" -eq 6 ]; then
        show_current
        continue
    fi

    if [ "$target_idx" -eq 3 ]; then
        invoke_hermes_setup
        continue
    fi

    do_claude=0
    do_opencode=0
    do_codex=0
    do_claude_desktop=0

    case "$target_idx" in
        0) do_claude=1 ;;
        1) do_opencode=1 ;;
        2) do_codex=1 ;;
        4) do_claude_desktop=1 ;;
        5) do_claude=1; do_opencode=1 ;;
    esac

    gw_options=()
    for ((i=0; i<preset_count; i++)); do
        lbl=$(python3 -c 'import json, sys; print(json.loads(sys.argv[1])[int(sys.argv[2])]["label"])' "$presets_json" "$i")
        gw_options+=("$lbl")
    done
    gw_options+=("[ Custom base URL ]")

    gw_idx=$(show_menu "Select Gateway" "${gw_options[@]}")
    if [ "$gw_idx" -eq -1 ]; then
        continue
    fi

    preset_obj=""
    if [ "$gw_idx" -lt "$preset_count" ]; then
        preset_obj=$(python3 -c 'import json, sys; print(json.dumps(json.loads(sys.argv[1])[int(sys.argv[2])]))' "$presets_json" "$gw_idx")
    else
        while true; do
            read -p "Enter custom Base URL: " raw_url < "$TTY_DEV"
            custom_url=$(normalize_base_url "$raw_url")
            if [[ "$custom_url" =~ ^https?:// ]]; then
                preset_obj=$(python3 -c '
import json, sys
url = sys.argv[1]
p = {
    "label": "Custom",
    "dashboard": None,
    "fetchModels": True,
    "claude": {"baseUrl": url, "curatedModels": []},
    "opencode": {"baseUrl": url, "providerKey": "custom", "providerName": "Custom", "npmPackage": "@ai-sdk/openai-compatible", "curatedModels": []}
}
print(json.dumps(p))
' "$custom_url")
                break
            fi
            echo -e "${YELLOW}Enter a full http:// or https:// URL.${RESET}" >&2
        done
    fi

    preset_label=$(python3 -c 'import json, sys; print(json.loads(sys.argv[1]).get("label", "Custom"))' "$preset_obj")
    preset_id=$(python3 -c 'import json, sys; print(json.loads(sys.argv[1]).get("id", ""))' "$preset_obj")
    preset_dashboard=$(python3 -c 'import json, sys; print(json.loads(sys.argv[1]).get("dashboard") or "")' "$preset_obj")
    fetch_models=$(python3 -c 'import json, sys; print("1" if json.loads(sys.argv[1]).get("fetchModels") else "0")' "$preset_obj")
    models_api_url=$(python3 -c 'import json, sys; print(json.loads(sys.argv[1]).get("modelsApiUrl") or "")' "$preset_obj")

    claude_base_url=$(python3 -c 'import json, sys; print(json.loads(sys.argv[1]).get("claude", {}).get("baseUrl") or "")' "$preset_obj")
    opencode_base_url=$(python3 -c 'import json, sys; print(json.loads(sys.argv[1]).get("opencode", {}).get("baseUrl") or "")' "$preset_obj")
    codex_base_url=$(python3 -c '
import json, sys
p = json.loads(sys.argv[1])
codex = p.get("codex", {})
if codex and codex.get("baseUrl"): print(codex["baseUrl"])
else: print(p.get("opencode", {}).get("baseUrl") or "")
' "$preset_obj")

    opencode_provider_key=$(python3 -c 'import json, sys; print(json.loads(sys.argv[1]).get("opencode", {}).get("providerKey") or "custom")' "$preset_obj")
    opencode_provider_name=$(python3 -c 'import json, sys; print(json.loads(sys.argv[1]).get("opencode", {}).get("providerName") or "Custom")' "$preset_obj")
    opencode_npm_package=$(python3 -c 'import json, sys; print(json.loads(sys.argv[1]).get("opencode", {}).get("npmPackage") or "@ai-sdk/openai-compatible")' "$preset_obj")

    codex_provider_key=$(python3 -c '
import json, sys
p = json.loads(sys.argv[1])
codex = p.get("codex", {})
if codex and codex.get("providerKey"): print(codex["providerKey"])
elif p.get("id"): print(p["id"])
elif p.get("opencode", {}).get("providerKey"): print(p["opencode"]["providerKey"])
else: print("")
' "$preset_obj")

    codex_provider_name=$(python3 -c '
import json, sys
p = json.loads(sys.argv[1])
codex = p.get("codex", {})
if codex and codex.get("providerName"): print(codex["providerName"])
elif p.get("label"): print(p["label"])
elif p.get("opencode", {}).get("providerName"): print(p["opencode"]["providerName"])
else: print("")
' "$preset_obj")

    if [ "$do_codex" -eq 1 ] && [ -z "$codex_provider_key" ]; then
        while [ -z "$codex_provider_key" ]; do
            read -p "Codex provider key (for [model_providers.<key>]): " codex_provider_key < "$TTY_DEV"
            codex_provider_key=$(echo "$codex_provider_key" | xargs)
        done
        while [ -z "$codex_provider_name" ]; do
            read -p "Codex provider display name: " codex_provider_name < "$TTY_DEV"
            codex_provider_name=$(echo "$codex_provider_name" | xargs)
        done
    fi

    # Check pre-saved env key
    local env_var_name=""
    if [ -n "$codex_provider_key" ]; then
        env_var_name=$(python3 -c '
import sys, re
p = sys.argv[1]
cleaned = re.sub(r"[^A-Z0-9]", "_", p.upper())
print(f"{cleaned}_API_KEY")
' "$codex_provider_key")
    fi

    local env_default_key=""
    if [ -n "$env_var_name" ]; then
        eval "env_default_key=\$$env_var_name"
    fi
    if [ -z "$env_default_key" ] && [ -n "$CUSTOM_API_KEY" ]; then
        env_default_key="$CUSTOM_API_KEY"
    fi

    clear >&2
    write_banner "API Key - $preset_label"
    if [ -n "$preset_dashboard" ]; then
        echo -e "  ${GRAY}Get a key at: $preset_dashboard${RESET}" >&2
        echo "" >&2
    fi

    if [ -n "$env_default_key" ]; then
        local masked_env
        masked_env=$(mask_key "$env_default_key")
        echo -e "  ${GREEN}Found pre-saved key in .env / environment:${RESET} ${GRAY}$masked_env${RESET}" >&2
        echo -e "  ${GRAY}(Press Enter to use pre-saved key, or type a new key below)${RESET}" >&2
        echo "" >&2
    fi

    stty -echo < "$TTY_DEV" 2>/dev/null
    read -p "Enter API Key: " api_key < "$TTY_DEV"
    stty echo < "$TTY_DEV" 2>/dev/null
    echo "" >&2

    if [ -z "$api_key" ] && [ -n "$env_default_key" ]; then
        api_key="$env_default_key"
    fi

    if [ -z "$api_key" ]; then
        echo -e "${RED}API key cannot be empty.${RESET}" >&2
        pause_screen
        continue
    fi

    live_claude="[]"
    live_opencode="[]"
    can_refresh=0

    if [ "$fetch_models" -eq 1 ]; then
        if [ -n "$models_api_url" ]; then
            pricing_res=$(get_agentrouter_pricing_models "$models_api_url")
            if [[ "$pricing_res" =~ ^FAIL ]]; then
                echo -e "${YELLOW}Live model list unavailable: $pricing_res${RESET}" >&2
                echo -e "${GRAY}Showing known models instead.${RESET}" >&2
            else
                live_claude=$(python3 -c 'import json, sys; print(json.dumps(json.loads(sys.argv[1])["claude"]))' "$pricing_res")
                live_opencode=$(python3 -c 'import json, sys; print(json.dumps(json.loads(sys.argv[1])["opencode"]))' "$pricing_res")
                can_refresh=1
            fi
        else
            live_res=$(get_live_models "$opencode_base_url" "$api_key")
            if [[ "$live_res" =~ ^FAIL ]]; then
                echo -e "${YELLOW}Live model list unavailable: $live_res${RESET}" >&2
                echo -e "${GRAY}Showing known models instead.${RESET}" >&2
            else
                live_claude="$live_res"
                live_opencode="$live_res"
                can_refresh=1
            fi
        fi
    fi

    claude_curated=$(python3 -c 'import json, sys; print(json.dumps(json.loads(sys.argv[1]).get("claude", {}).get("curatedModels", [])))' "$preset_obj")
    opencode_curated=$(python3 -c 'import json, sys; print(json.dumps(json.loads(sys.argv[1]).get("opencode", {}).get("curatedModels", [])))' "$preset_obj")

    claude_models=$(merge_models "$live_claude" "$claude_curated")
    opencode_models=$(merge_models "$live_opencode" "$opencode_curated")

    # Choose model helper loop
    choose_model() {
        local models_json="$1"
        local can_ref="$2"
        local gw_label="$3"
        local client_label="$4"
        local client_type="$5" # "claude" or "opencode"

        local current_models="$models_json"

        while true; do
            local model_list=()
            local count
            count=$(python3 -c 'import json, sys; print(len(json.loads(sys.argv[1])))' "$current_models")
            for ((i=0; i<count; i++)); do
                m=$(python3 -c 'import json, sys; print(json.loads(sys.argv[1])[int(sys.argv[2])])' "$current_models" "$i")
                model_list+=("$m")
            done

            local opts=("${model_list[@]}")
            opts+=("[ Enter custom model ID ]")
            if [ "$can_ref" -eq 1 ]; then
                opts+=("[ Refresh model list ]")
            fi
            opts+=("[ Back ]")

            local p_idx
            p_idx=$(show_menu "Select Model" "${opts[@]}" --header "Gateway: $gw_label" "Client: $client_label" "Available: $count")

            if [ "$p_idx" -eq -1 ]; then
                echo ""
                return
            fi

            if [ "$p_idx" -lt "$count" ]; then
                echo "${model_list[$p_idx]}"
                return
            fi

            local chosen_opt="${opts[$p_idx]}"
            if [[ "$chosen_opt" =~ "custom" ]]; then
                read -p "Enter exact model ID: " custom_m < "$TTY_DEV"
                custom_m=$(echo "$custom_m" | xargs)
                if [ -n "$custom_m" ]; then
                    echo "$custom_m"
                    return
                fi
                echo ""
                return
            elif [[ "$chosen_opt" =~ "Refresh" ]]; then
                if [ -n "$models_api_url" ]; then
                    rf=$(get_agentrouter_pricing_models "$models_api_url")
                    if [[ ! "$rf" =~ ^FAIL ]]; then
                        c_live=$(python3 -c 'import json, sys; print(json.dumps(json.loads(sys.argv[1])["'$client_type'"]))' "$rf")
                        c_cur=$(if [ "$client_type" == "claude" ]; then echo "$claude_curated"; else echo "$opencode_curated"; fi)
                        current_models=$(merge_models "$c_live" "$c_cur")
                    fi
                else
                    rf=$(get_live_models "$opencode_base_url" "$api_key")
                    if [[ ! "$rf" =~ ^FAIL ]]; then
                        c_cur=$(if [ "$client_type" == "claude" ]; then echo "$claude_curated"; else echo "$opencode_curated"; fi)
                        current_models=$(merge_models "$rf" "$c_cur")
                    fi
                fi
                continue
            else
                echo ""
                return
            fi
        done
    }

    while true; do
        claude_model=""
        opencode_model=""
        codex_model=""
        claude_desktop_model=""

        if [ "$do_claude" -eq 1 ] || [ "$do_claude_desktop" -eq 1 ]; then
            if [ "$do_claude" -eq 1 ]; then
                claude_model=$(choose_model "$claude_models" "$can_refresh" "$preset_label" "Claude Code" "claude")
                if [ -z "$claude_model" ]; then break; fi
            fi
            if [ "$do_claude_desktop" -eq 1 ]; then
                claude_desktop_model=$(choose_model "$claude_models" "$can_refresh" "$preset_label" "Claude Desktop" "claude")
                if [ -z "$claude_desktop_model" ]; then break; fi
            fi
        fi

        if [ "$do_opencode" -eq 1 ] || [ "$do_codex" -eq 1 ]; then
            if [ "$do_opencode" -eq 1 ]; then
                opencode_model=$(choose_model "$opencode_models" "$can_refresh" "$preset_label" "OpenCode" "opencode")
                if [ -z "$opencode_model" ]; then break; fi
            fi
            if [ "$do_codex" -eq 1 ]; then
                codex_model=$(choose_model "$opencode_models" "$can_refresh" "$preset_label" "Codex" "opencode")
                if [ -z "$codex_model" ]; then break; fi
            fi
        fi

        target_name=""
        if [ "$do_claude" -eq 1 ] && [ "$do_opencode" -eq 1 ]; then
            target_name="Claude Code + OpenCode"
        elif [ "$do_claude" -eq 1 ]; then
            target_name="Claude Code"
        elif [ "$do_claude_desktop" -eq 1 ]; then
            target_name="Claude Desktop"
        elif [ "$do_codex" -eq 1 ]; then
            target_name="Codex"
        else
            target_name="OpenCode"
        fi

        summary_headers=()
        summary_headers+=("Target:  $target_name")
        summary_headers+=("Gateway: $preset_label")
        if [ "$do_claude" -eq 1 ]; then summary_headers+=("Claude model:        $claude_model"); fi
        if [ "$do_claude_desktop" -eq 1 ]; then summary_headers+=("Claude Desktop model:$claude_desktop_model"); fi
        if [ "$do_opencode" -eq 1 ]; then summary_headers+=("OpenCode model:      $opencode_model"); fi
        if [ "$do_codex" -eq 1 ]; then summary_headers+=("Codex model:         $codex_model"); fi
        masked_k=$(mask_key "$api_key")
        summary_headers+=("API Key: $masked_k")

        confirm_idx=$(show_menu "Confirm" \
            "Apply configuration" \
            "Choose another model" \
            "Cancel" \
            --header "${summary_headers[@]}")

        if [ "$confirm_idx" -eq 1 ] || [ "$confirm_idx" -eq -1 ]; then
            continue
        fi
        if [ "$confirm_idx" -eq 2 ]; then
            break
        fi

        echo "" >&2
        if [ "$do_claude" -eq 1 ]; then
            res=$(configure_claude "$claude_base_url" "$api_key" "$claude_model")
            p_val=$(echo "$res" | grep "^PATH:" | cut -d: -f2-)
            b_val=$(echo "$res" | grep "^BACKUP:" | cut -d: -f2-)
            echo -e "${GREEN}[OK] Claude Code configured${RESET}" >&2
            echo "     $p_val" >&2
            if [ -n "$b_val" ]; then echo -e "     ${GRAY}Backup: $b_val${RESET}" >&2; fi
        fi

        if [ "$do_claude_desktop" -eq 1 ]; then
            res=$(configure_claude_desktop "$claude_base_url" "$api_key" "$claude_desktop_model")
            p_val=$(echo "$res" | grep "^PATH:" | cut -d: -f2-)
            b_val=$(echo "$res" | grep "^BACKUP:" | cut -d: -f2-)
            if [[ "$res" =~ ^ERROR: ]]; then
                echo -e "${RED}$res${RESET}" >&2
            else
                echo -e "${GREEN}[OK] Claude Desktop configured (3P gateway config)${RESET}" >&2
                echo "     $p_val" >&2
                if [ -n "$b_val" ]; then echo -e "     ${GRAY}Backup: $b_val${RESET}" >&2; fi
                echo "" >&2
                echo -e "  ${CYAN}Next steps in the Claude Desktop app:${RESET}" >&2
                echo -e "  ${GRAY}1. Fully quit and reopen the app (Cmd+Q, not just close window)${RESET}" >&2
                echo -e "  ${GRAY}2. Verify Third-Party Inference config loaded in Developer Settings${RESET}" >&2
            fi
        fi

        if [ "$do_opencode" -eq 1 ]; then
            res=$(configure_opencode "$opencode_base_url" "$api_key" "$opencode_model" "$opencode_provider_key" "$opencode_provider_name" "$opencode_npm_package")
            p_val=$(echo "$res" | grep "^PATH:" | cut -d: -f2-)
            b_val=$(echo "$res" | grep "^BACKUP:" | cut -d: -f2-)
            echo -e "${GREEN}[OK] OpenCode configured${RESET}" >&2
            echo "     $p_val" >&2
            if [ -n "$b_val" ]; then echo -e "     ${GRAY}Backup: $b_val${RESET}" >&2; fi
            if [ "$preset_id" == "agentrouter" ]; then
                echo -e "     ${GRAY}If OpenCode rejects the key, run: opencode providers login --provider agentrouter${RESET}" >&2
            fi
        fi

        if [ "$do_codex" -eq 1 ]; then
            res=$(configure_codex "$codex_base_url" "$api_key" "$codex_model" "$codex_provider_key" "$codex_provider_name")
            a_p=$(echo "$res" | grep "^AUTH_PATH:" | cut -d: -f2-)
            a_b=$(echo "$res" | grep "^AUTH_BACKUP:" | cut -d: -f2-)
            c_p=$(echo "$res" | grep "^CONFIG_PATH:" | cut -d: -f2-)
            c_b=$(echo "$res" | grep "^CONFIG_BACKUP:" | cut -d: -f2-)
            echo -e "${GREEN}[OK] Codex configured${RESET}" >&2
            echo "     $a_p" >&2
            if [ -n "$a_b" ]; then echo -e "     ${GRAY}Backup: $a_b${RESET}" >&2; fi
            echo "     $c_p" >&2
            if [ -n "$c_b" ]; then echo -e "     ${GRAY}Backup: $c_b${RESET}" >&2; fi
        fi

        echo "" >&2
        echo -e "${GREEN}Configuration complete.${RESET}" >&2
        echo "Close existing Claude Code, OpenCode, or Codex sessions and start a new terminal session." >&2
        pause_screen
        break
    done
done
