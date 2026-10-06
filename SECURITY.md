# Security

## Reporting a vulnerability

Please report security issues privately through [GitHub Security Advisories](https://github.com/rayone/MusicStudio/security/advisories/new) rather than public issues. Include steps to reproduce, the affected version, and your macOS and Mac model. Expect an acknowledgement within a week.

## Security model

MusicStudio is a local, single-user desktop app. It opens no listening ports. Its network traffic is:

| Destination | When | What is sent |
|---|---|---|
| `pypi.org` / `files.pythonhosted.org` | First launch | Package downloads (pinned versions) |
| `huggingface.co` | Model download, first AI Search, SongBench setup | Model file requests. Your Hugging Face token, if you set one in Settings. |
| Your Songwriter server (default `http://127.0.0.1:8000`) | Only when the Songwriter integration is enabled and used | Bearer token, song IDs, generation parameters and scores |

Prompts, lyrics and audio are never sent anywhere except to a Songwriter server you configure.

### Things to be aware of

- **Songwriter token default.** The default token is the placeholder `musicstudio`, intended for a local server on `127.0.0.1`. If you point MusicStudio at a remote server, set a real token in Settings → API, or use the `SONGWRITER_API_TOKEN` environment variable.
- **Plain HTTP is permitted** (`NSAllowsArbitraryLoads`) so local Songwriter servers work without TLS. Use `https://` for any server that isn't on your own machine.
- **Tokens are stored in UserDefaults**, not the Keychain (`~/Library/Preferences/ai.opencode.mlx.musicstudio.plist`, readable by your user account).
- **Plugins run with the app's privileges.** Audio Unit and VST3 plugins are native code. Library validation is disabled in signed builds so third-party plugins can load. Only load plugins you trust.
- **v0.1.0 binaries are ad-hoc signed, not notarized.** Verify the download against the published SHA-256, or build from source.
