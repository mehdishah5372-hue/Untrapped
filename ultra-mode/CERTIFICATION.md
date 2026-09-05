# Untrapped certification model

## Certificate A — Diagnostic GREEN

The existing canonical reporter/checker compatibility floor remains independently certifiable. The reporter schema and persistence contract must not be weakened to accommodate policy work.

## Certificate B — System GREEN

The complete system is GREEN only when Certificate A remains valid and all new policy/enforcement gates pass:

1. syntax
2. JSON/config validity
3. shared structured policy engine
4. exhaustive PowerShell policy corpus
5. canonical reporter compatibility
6. ErrorLibrary persistence
7. checker/policy differential tests
8. UAUD/UARD
9. behavioural sandbox
10. WinDivert substrate
11. browser integration
12. final Windows OS response
13. protected boundary

## OS response levels

### Level 1 — substrate

Administrator/elevation, Windows PowerShell, effective execution-policy list, DLL loading, WinDivert driver, `WinDivertOpen`, `WinDivertClose`, packet-filter parsing and canonical JSON consumption.

### Level 2 — lifecycle

Redundant workers must start, initialise, open filters, remain alive, refresh, reload configuration, survive a single worker termination and enter the emergency fail-closed path for invalid policy.

### Level 3 — observable behaviour

The certification VM performs a real outbound HTTPS request, proves baseline ALLOW, activates a WinDivert DROP filter, proves the real request is BLOCKED, removes the filter and proves the same request is ALLOWED again.

### Level 4 — perturbation/recovery

DNS cache perturbation, unresolved policy targets, invalid JSON, worker termination, redundant recovery and adapter-integrity checks are exercised automatically. Sleep/wake is deliberately not faked: hosted GitHub runners cannot safely suspend the certification VM and retain the CI control plane. Therefore sleep/wake remains a required local/disposable-VM certification item and prevents `SYSTEM GREEN` until it has been exercised successfully.

## Fail-closed rules

* A policy parsing/control-plane error keeps the last known-good filter when one exists.
* If no valid destination set can be resolved while blocking is active, an emergency HTTPS/QUIC DROP filter is opened.
* Filter refresh opens the new handle before closing the old handle.
* Two independent WinDivert workers use distinct priorities so one worker failure does not remove the only enforcement handle.
* A certification failure cannot be converted into GREEN by changing the reporter/checker output.

## Evidence

The Windows workflow uploads the policy, OS-level report, perturbation report, differential failures and `certification.json` as GitHub Actions artifacts. `certification.json` is only created when every hard gate succeeds.

## Railway boundary

Railway is an orchestration/observability/deployment-health layer only. A healthy Railway deployment is never treated as Windows blocker certification. The Windows workflow remains authoritative for OS GREEN.
