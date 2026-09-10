# Great Wallet

**Coercion-resistant Bitcoin self-custody.** The Dart and Flutter desktop application that integrates the Great Wall libraries into one product.

This is the parent repository: it pins every library to a compatible
commit and carries the application source. The libraries have no
submodules of their own.

**Status:** In development. Proof of concept — do not put savings behind it.

**Documentation:** [great-wall-docs/great-wallet](https://github.com/Yuri-SVB/great-wall-docs/tree/main/great-wallet)
— design, architecture and threat model live there, not here.

## Clone

This repository carries every library as a flat submodule, and one of them is
`great-wall-docs` — the documentation for the whole ecosystem, including this
application. A clone without submodules gets the application source and no
documentation at all, which is why this README carries clone instructions and
the library READMEs do not.

```sh
git clone --recursive git@github.com:Yuri-SVB/Great-Wallet.git

# or, after a flat clone:
git submodule update --init
```

`--init` without `--recursive` is deliberate. The libraries are flat and hold
no submodules of their own, so recursion buys nothing here and would re-fetch
`great-wall-docs` under any library that still vendors a copy.

Once cloned, start at
[`great-wall-docs/great-wallet/ARCHITECTURE.md`](great-wall-docs/great-wallet/ARCHITECTURE.md)
— it describes every component and the dependency graph. The threat model sits
beside it, and each library's design lives in its own directory there.

**⚡ Support:** [github.com/Yuri-SVB/SUPPORT](https://github.com/Yuri-SVB/SUPPORT) — free software, nothing gated.

## License

MIT or Apache-2.0, at your option.
