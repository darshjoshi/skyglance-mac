# Security

## Reporting a vulnerability

Please report privately, not as a public issue:

**[Open a private security advisory](https://github.com/darshjoshi/skyglance-mac/security/advisories/new)**

I am one person doing this in my spare time, so I cannot promise a response time and there is no
bounty. I will confirm receipt, tell you honestly whether I intend to fix it, and credit you in the
release notes unless you would rather I did not.

Useful in a report: what you did, what happened, and what you expected. A proof of concept is
welcome but not required.

## How releases are signed

Released builds are signed with an Apple Developer ID (Team `NUYTG9SV6X`), built with the hardened
runtime, and notarised by Apple. The notarisation ticket is stapled into the bundle, so Gatekeeper
accepts it without contacting Apple. You can check any copy yourself:

```bash
spctl --assess --type execute --verbose=2 /Applications/SkyGlance.app
```

Expect `accepted` and `source=Notarized Developer ID`. Anything else means the bundle was altered
after it was built, and you should not run it.

## Known and accepted risks

These are deliberate tradeoffs, documented so you can disagree with them before installing rather
than discover them afterwards.

### Your coordinate goes to third parties

Coarsened to ~1.1 km, but it does leave the machine, continuously, while the app runs. This is
inherent to answering "what is overhead". Full detail in the
[Privacy section](README.md#privacy).

### Upstream feeds are trusted for content, not for control

Aircraft data comes from volunteer-run services over TLS. Identifiers taken from their responses
are validated against a strict allowlist before they are used to build any URL, and photo URLs must
be `https`. A compromised upstream could still show you **wrong aircraft information** — there is no
way to verify that independently, and the app makes no claim to.

## Out of scope

- Wrong or missing aircraft data, or a feed being down — that is upstream, not a vulnerability.
- Gatekeeper and notarisation behaviour, which is Apple's to enforce and is described above.
- Anything requiring an attacker who already has code execution or write access to your home
  directory. They can already read the preference file and the cache.

## What the app does not do

No account, no analytics, no telemetry, no crash reporting, no server operated by me. It makes no
outbound connection except to the seven services listed in the README, opens no listening port,
requests no entitlement beyond location and notifications, and installs nothing that runs at
startup unless you enable Launch at Login yourself.
