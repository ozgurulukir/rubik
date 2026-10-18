# First Session with Rubik

This tutorial takes you from an installed Rubik CLI to a reviewed file change.
It uses an OpenRouter account; see the [installation guide](../how-to/installation.md)
for source checkouts and Windows build notes.

## 1. Install and set a provider key

Rubik requires Ruby 3.4 or later. Install the published gem:

```sh
gem install rubik
```

Set your OpenRouter key before launching Rubik. Replace `your-key` with the key
from your account.

On Linux or macOS:

```sh
export OPENROUTER_API_KEY="your-key"
```

In PowerShell:

```powershell
$env:OPENROUTER_API_KEY = "your-key"
```

## 2. Register a provider and model

Start Rubik in the project directory:

```sh
rubik
```

At the REPL prompt, register the provider using the environment variable, then
select its model:

```text
!provider add openrouter openai_compatible https://openrouter.ai/api/v1/chat/completions --key-env=OPENROUTER_API_KEY --model=anthropic/claude-sonnet-5.5 --context=200000 -g
!model openrouter/anthropic/claude-sonnet-5.5
```

The `-g` option saves the provider in the global user configuration. The key is
read from the environment rather than included in that provider command. The
provider and model commands are documented in the
[REPL command reference](../reference/commands.md).

## 3. Ask for a change and review it

Enter a task at the prompt, for example:

```text
Summarize the files in this project and suggest one small documentation improvement.
```

When Rubik stages edits, inspect them with `!diff`. Apply them with `!apply` only
after reviewing the diff, or discard unapplied changes with `!undo`.

For configuration options, see the [configuration guide](../how-to/configuration.md).
For the security checks and optional sandbox, see
[Security Practices](../../SECURITY.md).

---

Return to the [documentation index](../index.md) or the [README](../../README.md).
