# AI Config Manager

![Platform](https://img.shields.io/badge/platform-Windows%20%7C%20macOS-0078D6?logo=apple&logoColor=white)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-012456?logo=powershell&logoColor=white)
![Bash](https://img.shields.io/badge/Bash-3.2%2B-4EAA25?logo=gnu-bash&logoColor=white)
![Issues](https://img.shields.io/github/issues/TechTronixx/Custom-modelswitch)
![Stars](https://img.shields.io/github/stars/TechTronixx/Custom-modelswitch)
![Last commit](https://img.shields.io/github/last-commit/TechTronixx/Custom-modelswitch)

![Claude Code](https://img.shields.io/badge/Claude%20Code-3A3A3A?logo=anthropic&logoColor=white)
![OpenCode](https://img.shields.io/badge/OpenCode-0057B8)
![Codex](https://img.shields.io/badge/Codex-412991?logo=openai&logoColor=white)
![Hermes Desktop](https://img.shields.io/badge/Hermes%20Desktop-FF6B6B)

One-liner to switch Claude Code, OpenCode, Codex, and Hermes Desktop to a custom AI gateway. Supports **Windows** (PowerShell) and **macOS** (Bash).

Model lists are fetched live from the gateway when possible, with curated
fallbacks. Every config file is backed up before it's touched.

## Quick start

### macOS

```bash
curl -fsSL https://raw.githubusercontent.com/TechTronixx/Custom-modelswitch/main/bootstrap.sh | bash
```

### Windows

```powershell
irm https://raw.githubusercontent.com/TechTronixx/Custom-modelswitch/main/bootstrap.ps1 | iex
```

Downloads to `~/AI-Config-Manager` and launches the interactive menu. Re-run the one-liner any time to update and start again.

## Requirements

### macOS
- macOS (Intel or Apple Silicon)
- Bash 3.2+ (built-in standard shell)
- `curl` and `python3` (built-in standard tools)

### Windows
- Windows PowerShell 5.1+ or PowerShell 7+
- `curl.exe` (bundled with Windows 10/11)

## Install (manual)

Clone and run, if you prefer not to use the one-liner above:

### macOS

```bash
git clone https://github.com/TechTronixx/Custom-modelswitch.git
cd Custom-modelswitch
chmod +x AI-Config-Manager.sh
./AI-Config-Manager.sh
```

### Windows

```powershell
git clone https://github.com/TechTronixx/Custom-modelswitch.git
cd Custom-modelswitch
powershell -ExecutionPolicy Bypass -File .\AI-Config-Manager.ps1
```

No heavy external dependencies. `AI-Config-Presets.json` must stay next to the script.

## Usage

Pick an option with the arrow keys, **Enter** to select, **Esc** to go back.

| Option | What it does |
|--------|--------------|
| Configure Claude Code | Writes `~/.claude/settings.json` (base URL, token, model) |
| Configure OpenCode | Writes `~/.config/opencode/opencode.json` (provider + model) |
| Configure Codex | Writes `~/.codex/auth.json` + `~/.codex/config.toml`, sets an API-key env var |
| Configure Hermes Desktop | Launches `hermes model` for you to complete manually |
| Configure Claude Desktop | Writes the 3P gateway config (configLibrary entry) for the Claude Desktop app |
| Configure Both | Claude Code + OpenCode in one pass |
| View current configuration | Shows what each tool is currently pointed at |

Pick a gateway from the list, or choose **Custom base URL** to enter one at
runtime. Then enter your API key and pick a model.

## Gateways

The gateway list comes from `AI-Config-Presets.json`. Add your own by copying a
block — no code changes. Each preset defines, per tool, a base URL, provider
labels, and a curated model fallback list.

```json
{
  "presets": [
    {
      "id": "mygateway",
      "label": "My Gateway",
      "dashboard": "https://example.com/keys",
      "fetchModels": true,
      "modelsApiUrl": null,
      "claude":   { "baseUrl": "https://example.com", "curatedModels": ["claude-opus-4-8"] },
      "opencode": { "baseUrl": "https://example.com/v1", "providerKey": "mygateway", "providerName": "My Gateway", "npmPackage": "@ai-sdk/openai-compatible", "curatedModels": ["gpt-5.5"] },
      "codex":    { "baseUrl": "https://example.com" }
    }
  ]
}
```

Field notes:

- `dashboard` — signup/key page shown at the API-key prompt (`null` to omit).
- `fetchModels` — try a live model list before falling back to `curatedModels`.
- `modelsApiUrl` — optional public model-list endpoint; if set, it's used instead
  of the standard `/v1/models` call.
- Base URLs can differ per tool — set each to whatever your gateway expects.

## Notes

- **Backups:** each write leaves a `*.backup-<timestamp>` copy next to the original.
- **Codex sets an environment variable.** Configuring Codex writes a persistent
  environment variable (e.g. `MYGATEWAY_API_KEY`) holding your API key,
  because Codex resolves its provider key from the real process environment.
  On Windows, it sets a User environment variable; on macOS, it appends an `export`
  statement to `~/.zshrc` or `~/.zprofile` without creating duplicate entries.
  Fully restart the Codex app afterward for it to take effect.
- **Claude Desktop uses a 3P gateway config.** The Claude Desktop Electron app
  stores its gateway settings in a managed config file inside
  `%LOCALAPPDATA%\Claude-3p\configLibrary\` (Windows) or `~/Library/Application Support/Claude-3p/configLibrary/` (macOS). The script finds the active entry
  (via `_meta.json`'s `appliedId`) and writes the gateway base URL, API key, auth
  scheme, and model list. Fully restart the app afterward. If a setup screen
  appears, go to Menu > Developer > Configure Third-Party Inference to verify the
  config loaded. Each gateway uses its own model ID format, so pick the model
  from the live-fetched list that matches your gateway.
- **Secrets:** API keys are written into these config files and, for Codex, into
  an environment variable — plaintext, local only. They're excluded from git
  via `.gitignore`.

## Development

Run the built-in self-test for the scroll-window math (no terminal needed):

### macOS

```bash
./AI-Config-Manager.sh -SelfTest
```

### Windows

```powershell
powershell -File .\AI-Config-Manager.ps1 -SelfTest
```

## Contributing

Contributions welcome — see [CONTRIBUTING.md](CONTRIBUTING.md) for the branch
workflow (`dev` → PR → `main`) and guidelines.

Found a bug or want a new gateway/tool? [Open an issue](https://github.com/TechTronixx/Custom-modelswitch/issues) —
issue templates are provided for bug reports and feature requests. Questions and
ideas can go in [Discussions](https://github.com/TechTronixx/Custom-modelswitch/discussions).

## Disclaimer

This tool edits your own config files to point Claude Code, OpenCode, Codex, and
Hermes at a gateway you choose. It does not bypass authentication or pirate
access — you supply your own API keys. Routing official clients to third-party
endpoints may violate those tools' Terms of Service and can result in account
bans or service termination. You are responsible for complying with your
gateway's and each tool's terms. The software is provided "AS IS" without
warranty; the author is not liable for any damage, bans, or service loss.

## License

MIT — see [LICENSE](LICENSE).
