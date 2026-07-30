# o1-openvm — working notes

Universal Mina pickles verifier running in the OpenVM zkVM. The verifier core is
shared with the SP1 port; this repo is the OpenVM entrypoint, I/O, and chip
wiring.

Everything below was learned the hard way. Read it before touching the OpenVM
integration — most of these failures are silent or surface far from their cause.

## Repo topology

Three repos, all forks under `youtpout`:

| repo | branch | role |
|---|---|---|
| `proof-systems` | `openvm-on-sp1-on-master` | `mina-curves` + `poly-commitment` chip integration |
| `o1js-to-zkvm` | `perf/batched-accumulator` | `pickles-verifier` (the shared core) + SP1 guest |
| `o1-openvm` | `main` | this repo: OpenVM guest |

`proof-systems` is o1-labs' `sp1-on-master` (which carries the SP1 `sys_bigint`
feature — **not merged into master**) plus a mirrored `openvm` feature.

Feature cascade, one switch at the guest:
`pickles-verifier/openvm` → `kimchi/openvm` → `poly-commitment/openvm` →
`mina-curves/openvm`.

### For fast iteration

Flip all three to local `path` deps, then back to git before committing. Git
round-trips cost minutes per edit. **Never commit with local paths** — the repo
stops building anywhere else.

## Measured results

Verifying a real mainnet Mina blockchain SNARK. Same input bytes as the SP1 port,
so the numbers compare like for like.

| configuration | instructions | trace cells | vs baseline |
|---|---|---|---|
| no chips | 31,819,681,513 | 1,170,322,141,177 | — |
| + modular (Fp/Fq) | 24,221,887,063 | 896,055,841,422 | ×1.31 |
| + Vesta curve | 5,815,088,237 | 220,926,602,404 | ×5.47 |
| + Pallas curve | 2,249,380,517 | 86,644,291,990 | ×14.15 |
| **+ checked point construction** | **2,286,997,815** | **88,224,421,019** | **×13.91** |

The last row is the shipped configuration. Validating the curve equation on every
point costs **+1.67% instructions / +1.82% cells** — trivial, and not a tradeoff
worth having a conversation about.

SP1 (riscv64, `sys_bigint`) costs 4,378,867,074 cycles for the same work, so
OpenVM with both curve chips lands ~1.95× *better* — on a 32-bit core.

Two lessons in that table:

- **The modular chip alone is nearly worthless here (×1.31).** Accelerating field
  multiplication underneath software curve arithmetic cannot pay: ~95% of cycles
  are in point operations, and a point add is ~12 field muls wrapped in code that
  stays in software. Go for the curve level.
- Cells and instructions moved together (×14.15 / ×13.51), so the chips' wider
  rows did not eat the gain. Do not assume that — always read both.

### Other measurements worth knowing

- **Lagrange bases baked: ×14.8.** Without them kimchi recomputes the basis via
  an IFFT over curve points — 64.8B vs 4.4B cycles on SP1, i.e. 93% of the total.
  Never ship a guest without them.
- **`parallel` off: ~×12.** A zkVM is single-threaded; arkworks' parallel paths
  pay chunking and atomics for nothing. Leaving it on cost Zeko's settlement
  guest exactly this.
- **SP1's `sys_bigint`: ×1.96.** Real, but small next to the above.

## OpenVM gotchas

### Start from `guest-libs/k256/src/internal.rs`

Four of the five things that blocked the curve integration were already solved in
that 40-line file. For a macro-driven API the compiling example beats the docs:
the docs say nothing about which names the expansion references.

### declare and init always pair up

Anything `moduli_declare!`d or `sw_declare!`d in a library **must** be listed in
the binary's `openvm.toml`, or you get `undefined symbol:
sw_add_ne_extern_func_<Name>` at link time. `openvm::init!()` in the binary
generates the init side from that file.

Ordering in `openvm.toml` must match declaration order. A mismatch does not fail
to build — it computes in the wrong field. Guard against it with a known-good
output (see "Verification protocol").

### `sw_declare!` must live in the same crate as `moduli_declare!`

The generated `from_const_bytes` it needs for the curve's `b` constant is
**private**. Hence both Pasta curves are declared in `mina-curves`
(`pasta/openvm_curves.rs`), not downstream.

### The binary needs the guest crates too

`openvm::init!()` expands to `openvm_algebra_guest::moduli_macros::moduli_init!`
and `sw_init!`, so `openvm-algebra-guest` and `openvm-ecc-guest` must be direct
dependencies of the **binary** — having them in the declaring library is not
enough.

### No `///` inside a macro invocation

`sw_declare!` sees a doc comment and **silently generates nothing**. The error
then surfaces as "unresolved import" somewhere else entirely. Use `//`.

### Traits must be in scope for the expansion

`use core::ops::{Add, Neg};` and `use openvm_ecc_guest::{weierstrass::WeierstrassPoint, Group};`.
The expansion references them by bare name.

### `from_xy` is `unsafe`, despite the docs

The docs call it the constructor "which checks if the point is either identity or
on the affine curve". It does check the curve equation — but **not subgroup
membership**, and it is marked `unsafe`. `poly-commitment` denies `unsafe_code`,
so the exception is confined to one `#[allow(unsafe_code)]` on `try_msm` with the
obligation written out.

### `msm` is a software Pippenger, not a chip

`openvm_ecc_guest::msm` is a Rust loop whose inner `Add` is the intrinsic
(`extensions/ecc/guest/src/msm.rs`). The win is per point-addition, not
algorithmic — arkworks already runs Pippenger with a comparable window.

### The ECC extension takes arbitrary curves

The docs list "K256 and P256", which describes the shipped *guest libs*, not a
limit. `openvm.toml` takes `(modulus, scalar, a, b)`; Pallas and Vesta are both
`a = 0, b = 5`.

### User public output is exactly 32 bytes

`reveal_bytes32` fills slots 0..8 and that is the whole budget — writing anything
at slot 8 traps with `Memory access out of bounds: start=32 memory_size=32`. Fold
the attestation into one digest instead. We use
`keccak256(abi.encode(bytes32 vkHash, bytes32[] statement))`, verifiable with
`cast abi-encode` + `cast keccak`.

### OpenVM 2.0 is riscv32

`RUSTC_TARGET = riscv32im-risc0-zkvm-elf`; there is no rv64 extension. SP1 is
riscv64. So 256-bit arithmetic needs ~4× more instructions per operation unless it
goes through a chip — instruction counts are **not** comparable across the two
VMs without saying this.

### `--mode meter` needs `app.pk`

Run `cargo openvm keygen --app-only` first, and again after any `openvm.toml`
change. `openvm/` is generated (`app.pk`, `app.vk`, the transpiled vmexe) and
gitignored.

## Cargo gotchas

- **Never insert a `[target.'cfg(...)'.dependencies]` header mid-`[dependencies]`.**
  Everything after it silently moves into the target section. This produced 14
  bogus errors (`type annotations needed`, `mismatched types`) whose real cause
  was `serde_json` disappearing from the normal build.
- **One source per crate.** A `path` dep in one place and a `git` dep in another
  puts two `mina-curves` in the graph, and their `Fp` types do not unify. All six
  proof-systems crates move together.
- **You cannot `[patch]` a `path` dependency.** Only registry/git sources. This is
  why patching an internal crate of a path-linked workspace forces either a fork
  or full vendoring — and why Zeko vendored all of proof-systems.
- **Cargo fetches git deps with `--recurse-submodules`.** A registered submodule
  in a repo you depend on gets cloned in full. The `mina` submodule cost 15+
  minutes and gigabytes (including `optimism`) before a build even started; it is
  now removed, with `make mina-checkout` cloning it on demand for the OCaml
  fixture dumpers.

## Point provenance decides the constructor — and when unsure, check

I got this wrong once and the mistake is worth recording. `openvm_ec::vesta_msm`
has two call sites:

- `accumulator_check` passes the baked SRS generators — protocol constants.
- `accumulator_check_batch` passes each proof's `challenge_polynomial_commitment`
  — **prover-supplied**, and parsed host-side with arkworks' `new_unchecked`.

I had written a comment asserting the bases were all trusted, which was true of
the first site and false of the second, and the comment made the hole look
reasoned. Both paths now use the checking `from_xy`.

Do not "optimise" by splitting into a fast unchecked path plus a checked one.
That builds an invariant that lives in someone's memory rather than in the code,
and a third call site wired to the wrong one reintroduces the hole silently. At
under 2% the uniform checked version has no such failure mode.

Related, and still open: `wire.rs` parses `challenge_polynomial_commitment` with
`Vesta::new_unchecked`, so the *arkworks* path does not validate the curve
equation either. The OpenVM path is therefore now stricter than the reference.
Both end up rejecting the proof (the final equality fails), but by different
mechanisms. The clean fix is to validate on ingest in `wire.rs`, which would
benefit both zkVMs.

## Verification protocol

Never report a number without these, in order:

1. **The ELF exists.** `strings` on a missing file returns nothing and
   `grep -c` reports `0` — a false negative that reads like success.
2. **`rayon` is absent.** `strings <elf> | grep -ci rayon` should be 0–1. 386
   means the parallel paths came back.
3. **The digest matches** `0xb971a6a7…` for the mainnet fixture (vk_hash
   `0x0607c216…`, equal to o1js's `verificationKey.hash`). This single check
   validates the Montgomery↔canonical conversions, the Fp/Fq crossing (Vesta's
   coordinates are Fq, its scalars Fp — swapping them still typechecks and still
   yields a point), the moduli ordering, and `poly-commitment`'s `TypeId`
   dispatch.
4. **Then** the cycles/instructions/cells.

### Rejection must be tested in the guest, not just on the host

The host suite's rejection tests exercise the *arkworks* path. A chip bug could
in principle turn a rejection into an acceptance, and identical output on a valid
proof does not rule that out. `mkinput --tamper=MODE` produces deliberately
invalid inputs for exactly this:

| mode | expected | path covered |
|---|---|---|
| `accumulator` | `AccumulatorCheckFailed` | Vesta chip, stage 2 |
| `statement` | `WrapProofInvalid` | Pallas chip, via the wrap kimchi check |

Both must panic with **no `Execution output` at all**. A revealed digest, even a
different one, is an unsound acceptance.

`--tamper=accumulator` substitutes `Vesta::generator()` — a point genuinely on
the curve. An off-curve point would be caught by the checking constructor before
reaching the verification logic, which would test the guard rather than the
verifier.

Why this is robust by construction: the chip **produces a point, it decides
nothing**. The final comparison stays on arkworks points, so a wrong chip result
yields a rejection, not an acceptance. Both tests confirm that is the failure
mode in practice.

Also: `sp1_build` silently reuses a cached ELF. `rm -rf target/elf-compilation`
before any measurement that is supposed to reflect a change — two of my early
runs returned byte-identical cycle counts because the guest was never rebuilt.

## Security invariants

Performance work must not touch these.

- **Stage 2 (the accumulator check) is not optional.** It is 60% of SP1's cycles
  and the thing fast-but-unsound designs drop.
- **The binding digests are computed in-guest.** `hash_messages_for_next_step`
  absorbs the VK's wrap index and the attested statement; a host-computed digest
  would let whoever assembles the input attest to anything.
- **`max_proofs_verified` is bound by the previous-proof vector widths**, not by
  the digest — it reaches `vk_hash` but never the wrap public input.
- **Statement arity is the caller's business.** Mina's Poseidon zero-pads its
  final block, so for some circuits a prover can present `[s]` as `[s, 0]`. The
  arity is inside the committed ABI encoding so a consumer can pin it.
- **Chip points are built with the checking constructor.** OpenVM's raw
  deserialization does not verify the curve equation; do not "optimise" to
  `from_xy_unchecked` on a path where inputs are not already arkworks-validated.
