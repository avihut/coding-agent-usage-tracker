# Security policy

This app reads a local OAuth access token and local agent transcripts, so
reports about how it handles them are taken seriously.

## Reporting a vulnerability

Report privately through GitHub: **Security → Report a vulnerability** on this
repository (private vulnerability reporting is enabled). Please don't open a
public issue for anything exploitable. This is a one-maintainer project;
expect an acknowledgement within a week.

## What counts

The app's hard rules are written down in `docs/SPEC.md` §10 and summarized in
the README's "Credential rules". A way to make the app break one of them is a
vulnerability — for example:

- the access token (or any credential) being logged, persisted, placed in a
  URL or an error message, or sent anywhere but the vendor's own API;
- the refresh token being read, or the Keychain being written;
- a request to any host outside the documented destinations, or account data
  attached to one of the anonymous ones (pricing, status, release feed);
- a write inside an agent's home other than the one documented retention
  setting;
- the update path installing something the person didn't click, or a bundle
  that wasn't verified;
- the control socket or the on-disk digest being usable by another user.

## Supported versions

Only the newest tagged version. There are no binaries to patch — every
install is built from source, so the fix is a new tag and a rebuild.

## Releases are source only

This repository publishes no binaries (README → Install). Anything offering a
prebuilt "Agent Usage" / "AgentUsage" download is not from this project.
