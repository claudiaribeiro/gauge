# Contributing to Gauge

Thanks for your interest! Bug reports, ideas and pull requests are all welcome.

## Reporting a bug or suggesting an idea

Open an [issue](https://github.com/claudiaribeiro/gauge/issues). For bugs, please include:

- your macOS version
- which section is wrong (Claude, Codex or both) and what you expected to see
- for Codex problems, your Codex version, since its log format can change between releases

Please don't paste whole session logs or `usage-cache.json` files. They can contain session IDs and parts of your conversations. A few lines with private text removed is enough.

## Making a change

1. Fork the repo and create a branch from `main`.
2. Make your change and build it:

   ```sh
   ./build.sh
   ```

   This installs the app to `~/Applications` and relaunches it.
3. Check the panel in both light and dark mode. You can render it with sample data:

   ```sh
   build/Gauge.app/Contents/MacOS/Gauge --snapshot out.png light
   build/Gauge.app/Contents/MacOS/Gauge --snapshot out.png dark
   ```

   If you change the UI, include before/after screenshots in your pull request.
4. If you change `statusline.sh`, test it with a real Claude Code session and with more than one session open at once.
5. Open a pull request that explains what you changed and why.

Every pull request is reviewed before it's merged.

## Ground rules

Gauge stays small and private on purpose. Changes should keep it that way:

- **No network requests.** Gauge only reads files that Claude Code and Codex already write locally. No telemetry, update checks or API calls.
- **No dependencies.** The app is one Swift file built with `swiftc`. The status line script needs only `bash`, `jq` and tools built into macOS.
- **Treat files on disk as untrusted.** Validate anything read from disk before using it, as `Limit.validated` does.
- **Keep it simple.** Match the existing style, and prefer a small focused change over a big refactor. For a larger feature, please open an issue first so we can talk it through before you build it.

## Security

If you find a security problem, please don't open a public issue. Contact the maintainer privately through their GitHub profile instead.

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
