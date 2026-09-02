# Untrapped Update Middleman

The middleman is a deliberately narrow update broker between UAUD/UARD and the canonical repository.

## Responsibilities

1. Fetch the canonical allow-listed Untrapped artifacts.
2. Produce a manifest containing artifact paths, byte counts, versions and SHA-256 hashes.
3. Normalize explicit JSON source envelopes into their native artifact bytes.
4. Validate the normalized artifact before serving it.
5. Refuse PS1 artifacts below the protected `1.0.0` baseline.
6. Serve only paths in the explicit allow-list.
7. Expose `X-Untrapped-SHA256` and `X-Untrapped-Normalized` headers on artifact responses.
8. Never make changes to the client machine, Windows networking, firewall, WFP, DNS, routes, Hosts, proxy, adapters, VPN, or override policy.

## Protocol

- `GET /health`
- `GET /v1/manifest`
- `GET /v1/artifact/<allow-listed-path>`

The client should treat the manifest as the comparison authority for that update transaction. A client must download an artifact only after the manifest says it is present, then verify the returned SHA-256 against the manifest before writing anything.

## Baseline rule

`1.0.0` is the protected true baseline. A server response may retain or upgrade the baseline, but a client must refuse a lower version even if the server claims it is canonical.

## Deployment

This directory includes a Dockerfile and docker-compose configuration. The service is intentionally stateless so it can be deployed to a VPS/container host and restarted without losing update state.

For production, put HTTPS/TLS in front of the container and restrict inbound access to the client(s) that need it. Do not expose the development HTTP port directly to the public Internet without an authenticated reverse proxy or equivalent network control.
