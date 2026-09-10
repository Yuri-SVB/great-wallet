# Great Wallet

> ⚠️ **PROOF OF CONCEPT — NOT SAFE FOR USE.** The current Great Wall
> implementation is a **substandard proof of concept**: it does not yet match the
> finalized protocol specification and has not undergone independent security
> review. **Do not use it to protect real Bitcoin, funds, or any secret of
> value.** This notice will be removed once the implementation is brought up to
> the specified protocol.

**Remember your Bitcoin — carry nothing.**

Great Wallet is a self-custody Bitcoin wallet whose seed lives only in
your memory, protected by a fractal that is easy for *you* to recall
and prohibitively expensive for anyone else to search. Nothing to
steal, nothing to seize, nothing to lose in a fire.

> It's all in your head, in nobody else's, the attacker is aware of
> that, and is nevertheless unable to rob it.

---

## Documentation and Dependencies

The authoritative specification, invariants, and development guide live in
the vendored `great-wall-docs` submodule (repo:
[`yuri-svb/great-wall-docs`](https://github.com/yuri-svb/great-wall-docs)):

- [`great-wall-docs/great-wallet/ARCHITECTURE.md`](great-wall-docs/great-wallet/ARCHITECTURE.md)
  — ecosystem-wide context
- [`great-wall-docs/great-wallet/THREAT_MODEL.md`](great-wall-docs/great-wallet/THREAT_MODEL.md)
  — technical description of the threat model the protocol aims at defending against
- [`great-wall-docs/justification-and-economics/JUSTIFICATION.{tex/pdf}`](great-wall-docs/justification-and-economics/JUSTIFICATION.pdf)
  — in-depth, quantitative analysis on the economics of problem and proposed solution

Clone with submodules:

```
git clone --recursive <url>
# or, to avoid redundant recursion of great-wall-docs:
git submodule update --init # without the flag --recursive
```

## The four properties

Great Wallet gives you four guarantees at the same time:

1. **Knowledge-Based Authentication.** Your secret lives entirely in
   your memory. No device, physical vault, or geographic location is
   required to access your funds.
2. **Individual Custody.** You depend on no one else. The core
   premise of Bitcoin — full self-custody — is kept intact.
3. **Non-Obscurity.** The method is public. It does not rely on
   hiding how it works, and it does not rely on convincing an
   attacker that your stash doesn't exist or is smaller than it is.
4. **Coercion-Resistance.** Threats and violence cannot extract the
   secret, because the knowledge that unlocks it is *tacit* (cannot
   be verbalized on demand) and the mechanism that deploys it is
   gated by an inescapably lengthy computation.

This combination — a tacit secret plus a computationally-gated
interface for deploying it — is called **Tacit Knowledge-Based
Authentication (TKBA)**. It is the only class of authentication that
can provide all four properties at once, and it is the theoretical
basis of Great Wallet.

---

## How you use it

Great Wallet has four modes that flow naturally into one another:

1. **Setup** — encode a fresh Bitcoin seed onto a fractal you will
   learn to remember.
2. **Train** — spaced-repetition practice that turns the encoding
   into reliable tacit recall.
3. **Accelerate** *(optional)* — outsource the waiting-time part of
   the computation over Lightning Network, anonymously, whenever you
   need faster access.
4. **Inherit** *(optional)* — configure a dead-man's-switch channel
   so your heirs can receive your funds if you can no longer unlock
   them yourself.

Setup and Train are the core flow. Accelerate and Inherit are opt-in
and can be added later.

---

## Running the app

The unified app lives in [`app/`](./app) — great-wallet's own UI and
orchestration. This iteration implements the **Setup** mode by integrating
`great-wall-core` (the fractal encoder engine) with `great-wall-ux` (rendering
and interaction).

```bash
# from the repository root
git submodule update --init great-wall-core great-wall-ux great-wall-docs

# 1. Build the engine the app's FFI layer loads
app/native/build_core.sh

# 2. Run the app (desktop-first; needs the Flutter SDK 3.22+)
cd app
flutter pub get
# one-time: generate the platform runner. --org sets the application id so it
# is not the Flutter default "com.example.*".
flutter create --platforms=linux --org org.greatwall --project-name great_wallet .
flutter run -d linux                 # or macos / windows

# Tests
flutter test
```

See [`app/README.md`](./app/README.md) for the full integration map, the
build prerequisites per platform, and how the two-stage pipeline is wired.

---

## Status

The fractal encoder engine (`great-wall-core`) is public and in
**beta**. The rest of the ecosystem — training, Lightning
integration, inheritance protocol, and the unified app — is under
active development and not yet public.

---

## Learn more

- **[ARCHITECTURE.md](great-wall-docs/great-wallet/ARCHITECTURE.md)** — repository
  structure, cryptographic design, security model, and the inheritance protocol.
  Written for collaborators and auditors. (Lives in the `great-wall-docs`
  submodule — see *Documentation and Dependencies* above.)

---

## Lineage & acknowledgements

Great Wallet is the current iteration of a project with a longer
history. It builds on the work of earlier contributors and codebases,
which remain public:

- **[Great-Wall-Reference](https://github.com/Yuri-SVB/Great-Wall-Reference)**
  — the Rust reference implementation of the Great Wall protocol,
  predecessor of `great-wall-core`.
- **[T3-InfoSec](https://github.com/T3-InfoSec)** — the organization
  hosting the prior Dart/Flutter generation of the project
  (`great-wall-dart`, `t3-vault`, and related libraries).

We thank everyone who contributed to those earlier iterations; the
current design carries their work forward. See
[ARCHITECTURE.md](great-wall-docs/great-wallet/ARCHITECTURE.md#predecessor-repositories) for the
detailed mapping from predecessor repositories to the current
ecosystem.

---

## ⚡ Support

This is free software. Nothing is gated, no release is delayed, and there is no
paid edition.

If it was worth something to you, there is a Lightning (BOLT12) offer and an
on-chain silent payment address at **[github.com/Yuri-SVB/SUPPORT](https://github.com/Yuri-SVB/SUPPORT)**,
alongside a dated log of what has actually shipped.

## License

Great Wallet is dual-licensed under either of:

- Apache License, Version 2.0 ([LICENSE-APACHE](./LICENSE-APACHE))
- MIT License ([LICENSE-MIT](./LICENSE-MIT))

at your option.

Unless you explicitly state otherwise, any contribution intentionally
submitted for inclusion in the work by you, as defined in the
Apache-2.0 license, shall be dual-licensed as above, without any
additional terms or conditions.
