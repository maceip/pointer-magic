# Contributing

Thanks for helping with Pointer Magic.

## Native app (primary)

```bash
cd apps/pointer-magic-macos
swift test
./scripts/check-release-hygiene.sh
./scripts/build-app.sh --open
```

The assembled app is `.build/app/Pointer Magic.app` (ad-hoc signed by default).

## Browser showcase (secondary)

```bash
cd apps/showcase
npm install
npm run dev
```

## Guidelines

- Prefer small, focused PRs with tests for behavioral changes.
- Do not commit machine-specific absolute paths (for example a developer home directory). Use `NSHomeDirectory()`, temporary directories, or neutral fixtures such as `/Users/example/...`.
- Pointer follow must stay on the hard present lane: never await OCR, propose, actors, or network from `acceptPointerSample`.
- Shelf enrichment is soft and droppable; late results must lose to a newer generation.
- Do not add keystroke injection, event posting, or background focus stealing. Terminal focus is allowed only after an explicit shelf click, via Apple Events.

## License

By contributing, you agree that your contributions are licensed under the MIT License in [`LICENSE`](LICENSE).
