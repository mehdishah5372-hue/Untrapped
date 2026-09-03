# Untrapped — OSblocker

## OSblocker 1.0.0 baseline

The `ultra-mode` OSblocker is now established at **1.0.0** as the known-good functional baseline.

The baseline is the working Windows network-control system validated through the observable UAUD launch chain. Future changes must preserve the 1.0.0 behaviour and pass the validation/regression gates before becoming a new baseline.

### Baseline behaviour

- **05:00–22:00:** YouTube and ChatGPT are blocked.
- **22:00–05:00:** the scheduled block is inactive.
- **Always blocked:** CrushOn.
- **Always allowed:** Windows-MCP/PyPI package infrastructure listed in the canonical configuration.
- The existing override mechanism remains the only supported policy bypass.

### Validation architecture

```text
config.json
  ↓
000–999 middleman
  ↓
JSON → PowerShell sandbox
  ↓
PowerShell parser
  ↓
adaptive repair
  ↓
PowerShell/AST → canonical representation
  ↓
canonical equivalence
  ↓
disposable Windows behavioural sandbox
  ↓
UAUD evidence/report
  ↓
UARD
  ↓
INSTALL
```

The pipeline is fail-closed: uncertainty or failed validation must not install a candidate. The internal UAUD pipeline version remains independent of the product baseline version.

### Regression protection

Known parser and pipeline failures are covered by regression tests and the persistent ErrorLibrary. Reintroducing a known failure is intended to fail validation rather than silently becoming the new known-good state.

### Important distinction

`OSblocker 1.0.0` is the **product functional baseline**. Internal components such as UAUD and the 000–999 middleman retain their own versions/protocol identifiers.

## Original Untrapped browser extension

The original project is a browser extension intended to reduce YouTube distractions by hiding recommended content and modifying the YouTube interface.

## Technology

The browser extension uses JavaScript and WebExtensions/Chrome APIs, with HTML and CSS for its interface.
