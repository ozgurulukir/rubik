# First Session with Rubik

This tutorial guides you through your very first interactive session with Rubik.
By the end of this lesson, you will:

1. Install Rubik and configure provider credentials in your environment.
2. Launch the interactive REPL and connect an LLM provider and model.
3. Submit a coding task, inspect staged changes in the in-memory buffer using `!diff`,
   and safely apply or discard them.

For building from source or Windows prerequisites, see the
[installation guide](../how-to/installation.md).

---

## Prerequisites

- **Ruby 3.4 or later** installed (`ruby -v`).
- An active **OpenRouter API key** (or an alternate supported provider such as
  Anthropic, OpenAI, or a local Ollama instance).

---

## 1. Install and set a provider key

Install the published Ruby gem:

```sh
gem install rubik
```

Export your provider key into the environment so Rubik can authenticate without
hardcoding credentials into your repository or configuration files. Replace
`your-key` with your actual API key:

On Linux or macOS:

```sh
export OPENROUTER_API_KEY="your-key"
```

In Windows PowerShell:

```powershell
$env:OPENROUTER_API_KEY = "your-key"
```

---

## 2. Launch the REPL and register your provider

Navigate to the project directory where you want to work and start Rubik:

```sh
rubik
```

**Checkpoint:** You will see the Rubik prompt display the current directory and
active Git branch:

```text
rubik (my_project) [main] >
```

At the prompt, register your provider and select a model. The `-g` flag saves
the provider globally in `~/.rubik/config.yml` so you only need to configure it once:

```text
!provider add openrouter openai_compatible https://openrouter.ai/api/v1/chat/completions --key-env=OPENROUTER_API_KEY --model=anthropic/claude-sonnet-5.5 --context=200000 -g
!model openrouter/anthropic/claude-sonnet-5.5
```

**Checkpoint:** Rubik will confirm that the provider has been registered and set
the active model for this and subsequent turns.

---

## 3. Submit a task and review staged changes

Ask Rubik to examine the project and propose a small change:

```text
Summarize the files in this project and suggest one small documentation improvement.
```

Rubik reads the workspace files using read-only tools and, if asked to modify code,
writes changes **exclusively to an in-memory virtual buffer**. Nothing is written
to disk yet.

### Reviewing the Diff

Check the exact changes staged in the buffer before committing them to disk:

```text
!diff
```

Rubik displays a colorized, unified diff showing added and removed lines.

### Applying or Discarding Changes

- **To write the changes to disk**, run:
  ```text
  !apply
  ```
  Rubik atomically applies the changes to your workspace files.

- **To discard the proposed changes without modifying disk**, run:
  ```text
  !undo
  ```
  The virtual buffer unwinds, restoring the baseline workspace state.

---

## Summary & Next Steps

Congratulations! You have completed your first session with Rubik. You learned how
to connect a model provider and how Rubik's virtual buffer allows you to review all
agent-generated edits before they ever touch your files.

- **Customize your environment:** See the [Configuration Guide](../how-to/configuration.md)
  to set up custom models, token ceilings, and fallback providers.
- **Connect compilers & linters:** See [Set Up Language Servers](../how-to/language-servers.md)
  for real-time diagnostic feedback during edits.
- **Explore all commands:** Browse the [REPL Command Reference](../reference/commands.md)
  for `!goal`, `!plan`, `!workspace`, and session controls.

---

Return to the [documentation index](../index.md) or the [README](../../README.md).
