# How to Connect a Provider

The fastest way to add an LLM provider to rubik is the connect wizard. It runs interactively, validates your key against the live endpoint before saving anything, and writes through the same config pipeline as the manual commands — the API key lands in the OS secret store and the config file only ever holds a `rubik-secret:` reference.

## Start the wizard

Any of the three entries does the same thing:

| Entry | When to use |
| :--- | :--- |
| `rubik connect` | From the shell, before or instead of starting the REPL |
| `!connect` | Inside an interactive rubik REPL session |
| first-run offer | rubik asks once when boot could not resolve any LLM client |

`rubik connect` boots no shell and no workspace trust gate; it writes global-scope config only (a project-scope run stays an explicit `--project` flag — plaintext project secrets are still refused by the secret-write policy).

## Walk the flow

1. **Provider** — pinned favorites first (OpenAI, Anthropic, OpenRouter, DeepSeek, Groq, Mistral, xAI, Google/Gemini, local Ollama), a custom-endpoint branch, and the full models.dev catalog behind a type-to-filter submenu.
2. **Endpoint** — prefilled from the catalog; Enter accepts.
3. **Key** — masked entry with live validation. A rejected key (401/403) re-asks; an unreachable endpoint offers retry / save-anyway / cancel. Escape hatches: store the key in an environment variable instead, or skip the key for now.
4. **Model** — the endpoint's live model list when available, otherwise models.dev metadata with context limits and tool support; manual entry is always available.
5. **Roles** — bind the model to `default` only (recommended), `default + fast`, all three, or none.
6. **Confirm** — a summary frame; nothing is written before you accept. On save, role specs mirror the new model and the running REPL re-routes immediately (zero restart).

The wizard persists to **global** scope (`~/.rubik/config.yml`) by default. `!connect --project` persists to the project config; plaintext project secrets are refused by default, so a project-scope run with a typed key is rejected by the secret-write policy — use `--global`, an `api_key_env`, or set `security.allow_project_secrets` if you accept the risk.

## Catalog cache

The wizard fetches the models.dev catalog once and caches it under `~/.rubik/cache/` for 24 hours; a network failure falls back to the cached copy, and with no cache at all the wizard keeps working in manual mode (pinned providers + free-text entry).

## Adjusting afterwards

- `!provider list` — what is configured; `!provider set <name> key <value>` replaces a key.
- `!model set <role> <provider>/<model>` — re-bind a role.
- `!connect` again — connecting the same provider name overwrites that provider's spec.

Offline or scripted setup stays supported: `!provider add <name> [type] <url> [--key=...] [--model=...]` does everything the wizard does, non-interactively.
