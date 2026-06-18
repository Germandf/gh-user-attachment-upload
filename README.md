# gh-user-attachment-upload

Small PowerShell CLI for uploading local images to GitHub `user-attachments` and printing Markdown links.

This exists for AI-agent PR evidence workflows where screenshots need to be embedded in private GitHub PRs without committing files, creating releases, creating gists, or depending on a third-party binary.

## Background

- Official GitHub CLI feature request: [cli/cli#13256](https://github.com/cli/cli/issues/13256)
- Reverse-engineered flow this is based on: [drogers0/gh-image](https://github.com/drogers0/gh-image)

GitHub does not currently expose a public REST, GraphQL, or `gh` API for creating `https://github.com/user-attachments/assets/...` uploads. This tool uses the same private upload flow as the web UI. It does not read browser cookies.

## Install

```powershell
git clone https://github.com/Germandf/gh-user-attachment-upload
cd gh-user-attachment-upload
.\install.ps1
gh-upload-image -Help
```

The installer copies `gh-upload-image.ps1` and a `gh-upload-image.cmd` shim to `$HOME\.dotnet\tools`.

## Agent Setup

When an agent is asked to configure this tool from the repository URL, it should:

1. Clone the repository.
2. Run `.\install.ps1`.
3. Verify `gh-upload-image -Help`.
4. If no session is configured, ask the user to run `gh-upload-image configure` locally. Do not ask for the cookie in chat.

## Use

First-time local setup:

```powershell
gh-upload-image configure
```

Then upload images:

```powershell
gh-upload-image Eternet/Eternet.Netmap .\screenshot.png
```

Output:

```markdown
![screenshot.png](https://github.com/user-attachments/assets/...)
```

Multiple files are supported:

```powershell
gh-upload-image owner/repo .\before.png .\after.png
```

## Requirements

- PowerShell 7+
- GitHub CLI authenticated with `gh auth login`
- Write access to the target repository
- A configured GitHub web session through `gh-upload-image configure`

`configure` asks for a GitHub `user_session` cookie value once and stores it locally for the current OS user using PowerShell secure-string encryption. On Windows, that uses DPAPI/current-user protection. For CI or temporary one-off usage, `GH_USER_SESSION` can still be set as an environment variable and takes precedence over the saved session.

`user_session` is a full GitHub web session credential. Treat it like a password. Do not paste it in chat, commit it, log it, or pass it as a command-line argument.

## Why Configure Instead Of Fully Automatic Login?

GitHub's private upload endpoint does not accept a normal `gh auth token` or PAT. Fully automatic setup would require reading browser cookie stores, which is more invasive and fragile. This tool keeps that sensitive step explicit, local, and separate from AI-agent chat.

## AGENTS.md Snippet

```markdown
## PR Evidence Screenshots
- If the user explicitly asks to upload screenshots through GitHub `user-attachments`, use `gh-upload-image owner/repo path\image.png` from `https://github.com/Germandf/gh-user-attachment-upload`; it uploads local images as GitHub `user-attachments` and prints Markdown links. Requires prior `gh-upload-image configure` or local env var `GH_USER_SESSION`; never ask the user to paste that cookie in chat and never echo it in logs.
```
