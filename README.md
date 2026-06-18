# gh-user-attachment-upload

Small PowerShell CLI for uploading local images to GitHub `user-attachments` and printing Markdown links.

This exists for AI-agent PR evidence workflows where screenshots need to be embedded in private GitHub PRs without committing files, creating releases, creating gists, or depending on a third-party binary.

## Background

- Official GitHub CLI feature request: [cli/cli#13256](https://github.com/cli/cli/issues/13256)
- Reverse-engineered flow this is based on: [drogers0/gh-image](https://github.com/drogers0/gh-image)

GitHub does not currently expose a public REST, GraphQL, or `gh` API for creating `https://github.com/user-attachments/assets/...` uploads. This tool uses the same private upload flow as the web UI. It does not read browser cookies and does not persist credentials.

## Install

```powershell
git clone https://github.com/Germandf/gh-user-attachment-upload
cd gh-user-attachment-upload
.\install.ps1
```

The installer copies `gh-upload-image.ps1` and a `gh-upload-image.cmd` shim to `$HOME\.dotnet\tools`.

## Use

```powershell
$env:GH_USER_SESSION = '<github.com user_session cookie value>'
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
- `GH_USER_SESSION` set locally to a valid GitHub `user_session` cookie value

`GH_USER_SESSION` is a full GitHub web session credential. Treat it like a password. Do not paste it in chat, commit it, log it, or pass it as a command-line argument.

## AGENTS.md Snippet

See [AGENTS-SNIPPET.md](AGENTS-SNIPPET.md).
