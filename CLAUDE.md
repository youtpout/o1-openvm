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
| + checked point construction | 2,286,997,815 | 88,224,421,019 | ×13.91 |
| + VK validation, no heap allocs | 2,230,979,102 | 85,934,163,225 | ×14.26 |
| + OpenVM 2.1 / rv64 | 898,656,552 | 32,057,167,004 | ×35.41 |
| + canonical field storage | 724,387,584 | 25,826,089,173 | ×43.93 |
| + Poseidon on the chip | 697,235,468 | 24,905,746,771 | ×45.64 |
| + zero-copy limb bridge | 664,797,171 | 23,899,549,955 | ×47.86 |
| **+ Pippenger window c=12** | **440,506,582** | **15,851,212,777** | **×72.23** |

The last row is the shipped configuration; every row above the rv64 one is rv32
on 2.0.1.
The rv64 jump is a pure toolchain move — no code change beyond widening the
`target_os` gates — and is worth ×2.48 instructions / ×2.68 cells on its own.

Note the direction of the VK-validation row:
adding curve validation on the 28 VK commitments *and* dropping the heap
allocations in the limb conversion nets **−2.45% instructions / −2.60% cells**.
Security was added at negative cost. `to_bytes_le()` allocated a `Vec` per
coordinate — ~130k allocations per 2^16 MSM, on a path where the allocator is
plain RISC-V and every byte crosses the memory chip. Read the `[u64]` limbs via
`BigInteger: AsRef<[u64]>` instead (`.0` does not compile: `F::BigInt` is an
associated type).

### Canonical field storage — where the last ×1.24 came from

arkworks stores Montgomery form (`aR mod p`); the modular chip's `IntMod` is
canonical. Bridging them cost **two** chip instructions per multiplication: the
product `abR²`, then a multiply by `R⁻¹`. Storing canonical values makes it one.

Two constants select the representation, and they must **not** get the same
value — this is the part that is easy to get wrong:

- `R` is only ever read as `FpConfig::ONE = Fp::new_unchecked(R)`. Canonical ONE
  means `R = 1`.
- `R2` is read by the **const** constructor `Fp::new`, which is what `MontFp!`
  expands to: `mont_mul(e, R2) = e·R2·2⁻²⁵⁶`. That path is const arithmetic
  inside ark-ff and ignores every `MontConfig` override, so cancelling it needs
  `R2 = 2²⁵⁶ mod p` — the value `R` has by default. Both Pasta curve configs
  (`COEFF_B`, the generators) are `MontFp!` literals, so this is what keeps them
  correct. Set `R2 = 1` too and the curve parameters silently become garbage.

`GENERATOR` and `TWO_ADIC_ROOT_OF_UNITY` then have to be written as canonical
decimals rather than carried over as Montgomery limbs. `mina-curves`'
`openvm_canonical_constants` test pins both against the derived config.

Three things fell out of the change, in rough order of value:

- **`mul_assign`: 2 chip instructions → 1.**
- **`into_bigint` becomes a move.** It was a 16-mac Montgomery reduction, and it
  sits on the hot path twice over — every coordinate *and* every scalar crossing
  into the curve chip goes through it, ~196k times for the 2^16 MSM alone.
- **`inverse` via the chip's `DivMod`** (`ModArithBaseFunct7::DivMod`) instead of
  arkworks' software extended Euclid.

Gate all of it on the zkVM *target*, not just the feature: a host build with
`openvm` on keeps arkworks' software Montgomery multiplication, which only agrees
with Montgomery *storage*.

### The conversion around a chip op costs ~100× the chip op

The number worth remembering from the Poseidon work. Measured by adding N
permutations to the production guest and taking the delta:

| | value |
|---|---|
| permutations per verification | 303 |
| before: per permutation | 119,140 instructions |
| multiplications per permutation | 1,155 (55 rounds × [3 S-boxes × 4 + MDS 9]) |
| → per multiplication | **~103 instructions, of which 1 is the multiply** |

The other ~102 are `limbs_to_mod` / `mod_to_limbs`: arkworks stores `[u64; 4]`,
`IntMod` stores `[u8; 32]`, and the bridge copies 32 bytes three times per
multiply (two operands, one result). `fp.rs` used to say "the cost is 32 byte
copies against a chip call" — true when a multiply was two chip instructions
*plus* a Montgomery reduction. Canonical storage inverted it.

Running the whole permutation in `IntMod` (`mina-poseidon::openvm_perm`) moves
the conversions to the boundary — 3 in, 3 out, plus round constants, instead of
~3,465 — and takes a permutation to ~29,400 instructions, ×4.05. Poseidon went
from 5.0% of the guest to ~1.3%.

**The general lesson, and the next lever.** Attach the chip at the level of the
algorithm, not the operation — the same shape as the MSM bridge. And the ~25
instructions per multiply that remain are still mostly conversion: making the
limb/byte bridge itself zero-copy (both layouts are little-endian and identical;
`bytemuck::cast_ref` does it in safe Rust) would pay everywhere at once, not
just in the sponge.

Two guards on the fast path, both deliberate: it checks the sponge *shape* it
implements (width 3, all-full-rounds, `x^7`, full MDS) rather than assuming
kimchi's constants, and it dispatches by `TypeId` with a fallback. `Field` is
already `'static` in ark-ff, so no caller gains a bound.

### The MSM window was the single biggest win — and it was in someone else's code

`openvm_ecc_guest::msm` sizes its Pippenger window at `bases.len().ilog2()`,
which is **16** for the `2^16`-point accumulator MSM. That is well past the
optimum: the bucket pass costs `2^c` additions per window and overtakes the `n`
additions it is meant to save.

| window | windows | point ops | bucket memory |
|---|---|---|---|
| upstream `c = 16` (Booth) | 17 | 2.23M | 2 MiB |
| ours, `c = 12` | 22 | 1.62M | 256 KiB |

Replacing it with a plain unsigned Pippenger at the computed optimum
(`poly-commitment::openvm_pippenger`) was **−33.7% on the whole guest**, in one
change.

**Do not read that as "the MSM was 33.7%".** The operation count only predicts
×1.38; if that were the whole story the MSM would have to be more than 100% of
the guest. Something else carries most of it, and the likely candidate is the
bucket memory — upstream allocates and clears 2 MiB of buckets per window, 17
times, and in a zkVM every one of those bytes crosses the memory chip. That is a
hypothesis, not something these numbers establish.

The transferable lesson: a dependency's "reasonable default" is tuned for a
machine you are not running on. `// finetune this if needed` is in upstream's
source, right above the line.

Booth encoding would halve the bucket count again, worth roughly another 9%.
Skipped deliberately: it earns that with a signed-digit encoding that is easy to
get subtly wrong, and the window size is where the factor is.

### What did *not* pay: batch inversion

Written, measured, reverted — recorded so nobody re-derives it. With `DivMod` at
one instruction, Montgomery's trick pays ~3n multiplications to save n
inversions, so direct inversion should be ~3× cheaper. It is; the volume is just
trivial. Swapping every `batch_inversion` on the verify path for direct
inversions was **−13,554 instructions, −0.002%**, against a new module, a
feature across three crates, and eight call sites. The reasoning was right and
the change was still not worth keeping.

### How to attribute cost to a component

There is no usable per-function profiler. `perf-metrics` on the CLI enables
`function-span`, but nothing installs a `metrics` recorder — that is wired up in
OpenVM's own benchmark harness, not in `cargo openvm`. Building the CLI with it
only gets you a mandatory `GUEST_SYMBOLS_PATH` env var on every run.

What works, and what produced the table above: call the component N times in the
production guest, measure, subtract. Calibrate N against a host-side counter
first (a `static AtomicUsize` in the function of interest) so you know what one
call costs in units you care about, and keep a side effect at the end — a
comparison that can panic — or the loop is optimized away.

### fq.rs had a dead gate for the whole OpenVM path

Worth knowing because the failure mode is invisible: `impl MontConfig for
FrConfig` in `curves/src/pasta/fields/fq.rs` was `#[cfg(feature = "sp1")]`, so an
`openvm` build resolved `FrConfig` to the *derived* config and compiled none of
the OpenVM Fq code. The `mul_assign` inside it was correctly gated in itself —
it just lived in a block that never existed. `fp.rs` had the right gate all
along, which is why the table's "+ modular (Fp/Fq)" row was really Fp only.

Fq is Vesta's base field and Pallas's scalar field, i.e. every coordinate on the
chip boundary. Same lesson as the rv64 rename: an accelerated path that is not
compiled produces correct results, silently, at software speed.

### The constants blob encodes a representation, not just values

`serialize.rs` bakes points as a raw memory image and casts them straight back —
that is what makes decoding free, and it means the blob is only readable by a
consumer with the *same* field representation. A canonical guest reading a
Montgomery blob gets different curve points; it surfaced as `Vesta point not on
curve` from a constructor three layers down.

The blob now carries a representation byte. The encoder always runs on the host
and cannot detect what the consumer wants, so it is selected by
pickles-verifier's `canonical-blob` feature **on the build dependency**; the
decoder's side is derived from how that crate is actually compiled, so the
assertion compares an intent against a fact rather than a flag against itself.

Also worth recording: the identity is safe to pass into
`openvm_ecc_guest::msm`. The `sw_declare!` expansion implements the full group
law in Rust — identity on either side, `P = Q` via `double`, `P = -Q` to identity
— and only delegates the non-degenerate cases to the `add_ne`/`double`
intrinsics. The naming (`sw_add_ne_extern_func`) is the giveaway.

SP1 (riscv64, `sys_bigint`) costs 4,378,867,074 cycles for the same work: ~1.95×
*more* than the rv32 OpenVM build, and ~4.87× more than the rv64 one. Treat both
ratios as indicative only — an SP1 cycle and an OpenVM instruction are not the
same unit, and there is no SP1 equivalent of the trace-cell count, which is the
figure that actually tracks proving cost. The comparison worth trusting is
rv32-vs-rv64 *within* OpenVM, where both metrics are available and agree.

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

### OpenVM 2.0 is riscv32, 2.1 is riscv64

2.0.1: `RUSTC_TARGET = riscv32im-risc0-zkvm-elf`, `target_os = "zkvm"`, config
sections `[app_vm_config.rv32i]` / `rv32m`.

2.1 (`v2.1.0-preview`): `riscv64im-unknown-openvm-elf`, `target_os = "openvm"`,
sections `rv64i` / `rv64m`. The target is a **custom** one from the
`openvm-org/rust` fork, not an upstream rustc target — get it with
`cargo openvm toolchain install`, which downloads a prebuilt toolchain (no rustc
build). Everything else (`modular`, `ecc`, `keccak`, `io`) keeps its name, and
`moduli_declare!` / `sw_declare!` / `IntMod` / `from_xy` are unchanged, so the
port is mechanical.

Measured on the mainnet fixture, chips enabled: rv32 2,230,978,700 instr /
85,934,147,775 cells → rv64 898,656,552 / 32,057,167,004, i.e. **×2.48 and
×2.68**. The worry that wider rv64 columns would eat the instruction saving did
not materialise — the cell gain is the larger of the two. Unaccelerated, the same
work is 31.8B (rv32) vs 9.13B (rv64), so rv64 alone is worth ×3.49 in software.

### The rv64 rename silently deletes every accelerated path

This is the worst failure mode in this project so far, because **nothing fails**.
Moving to 2.1 flips `target_os` from `zkvm` to `openvm`, which invalidates two
separate layers at once:

  * `#[cfg(all(target_os = "zkvm", feature = "openvm"))]` on the accelerated code
  * `[target.'cfg(target_os = "zkvm")'.dependencies]`, without which the openvm
    guest crates are not even linked

With both stale, the guest builds clean, runs clean, and produces the **correct
digest** — on the arkworks software path, ~10× slower. Only a cycle measurement
reveals it. Both layers now accept
`any(target_os = "zkvm", target_os = "openvm")`, and a `compile_error!` guard in
`mina-curves`, `poly-commitment` and `pickles-verifier` fails the build when
`openvm` is on for a RISC-V target with an unrecognised `target_os`. Host builds
are unaffected — they legitimately use the software path.

Corollary for any future target change: a correct digest proves the *math*, not
that the chips ran. Always confirm against a known instruction count.

### `--mode meter` needs `app.pk` — and a stale one panics obscurely

Run `cargo openvm keygen --app-only` first, and again after any `openvm.toml`
change **or any OpenVM version change**. `openvm/` is generated (`app.pk`,
`app.vk`, the transpiled vmexe) and gitignored.

An `app.pk` left over from a different OpenVM version fails as
`Memory access out of bounds: start=144 size=8 memory_size=128` from
`memory/online/memmap.rs` — an rv64 ELF executed against an rv32 memory config.
The message names neither the key nor the version, and the CLI is stripped so the
backtrace is empty. `rm -rf openvm/app.pk openvm/app.vk` and re-keygen.

## GPU proving (CUDA)

Nothing in this repo changes for GPU. The guest ELF is byte-identical: `cuda` is
a feature of the **host prover**, and it swaps each extension's CPU trace
generator for its CUDA one. Every extension this guest uses has a GPU backend —
`algebra` (the modular chip), `ecc` (Pallas/Vesta), `keccak256`, `riscv` — so no
chip silently falls back to the CPU path.

    ./scripts/gpu-setup.sh     # once per machine
    make prove                 # keygen if stale, then prove app

`scripts/gpu-setup.sh` installs rustup, `cargo-openvm` **built with
`--features cuda`**, and the riscv64 guest toolchain. That install compiles the
CUDA kernels, so budget 20–40 min; everything after it is fast.

### Measured, RTX 5090 (32 GB), mainnet fixture

| what | time |
|---|---|
| `prove app` | **5 min 01** |
| `prove evm`, halo2 on CPU | 8 min 54 |
| **`prove evm`, `halo2-gpu`** | **4 min 59** |
| `verify evm` | 1.7 s |
| `setup --evm` (once per machine) | 2 min 42 |

Read the third row twice: **the full Ethereum-verifiable proof costs the same as
the app proof alone.** Aggregation, root and halo2 are effectively free once
everything is on the GPU — but only then. With halo2 on CPU the same chain is
×1.8 slower, and that gap is *larger* than the app proof itself, so
`--features halo2-gpu` is not a micro-optimisation here.

The EVM proof is 3.9 KB and verifies for 336,146 gas.

For scale: the SP1 port, same fixture, same input bytes, same GPU, is 32 min 01
for a core proof and 40 min 39 for Groth16 (with gnark on GPU via ICICLE). That
is ×8.2 on the on-chain path, and the whole of it comes from the guest — 440 M
instructions against 4.38 G cycles — not from the prover.

### What the machine needs

- An NVIDIA driver (`nvidia-smi`) **and** the CUDA toolkit (`nvcc`). On vast.ai
  that means picking a **`-devel`** image: the `-runtime` images carry the driver
  but no toolkit, and the install then fails minutes into the kernel build.
- Toolkit 12.9, 13.0 or 13.1. OpenVM's CI runs 12.9, so treat it as the target.
- One GPU. The CLI is single-GPU only — renting a 4×GPU box buys nothing.

### Feature map

| feature | STARK proving | halo2 (EVM verifier) |
|---|---|---|
| `cuda` | GPU | CPU |
| `halo2-gpu` | GPU | GPU |

`halo2-gpu` implies `cuda` and only matters for `prove evm`, which is by far the
most memory-hungry step (≥25 GB of GPU memory; use a 32 GB+ card). `prove app`
and `prove stark` need much less.

### Knobs when it OOMs on the device

- `SEGMENT_MAX_MEMORY=…` (passed through by `scripts/prove.sh`) — smaller
  segments, more of them.
- `VPMM_PAGE_SIZE` / `VPMM_VA_SIZE` / `VPMM_PAGES` — the CUDA backend's virtual
  memory pool (`crates/cuda-common/src/memory_manager/vm_pool.rs`).
- `CUDA_ARCH=90` etc. at install time if auto-detection picks the wrong SM.

### The verification protocol still applies

A GPU proof is not evidence that the *guest* ran the accelerated paths — that is
a compile-time property of the guest, checked the same way as on CPU
(`strings` for `rayon`, then the digest). Run `make check` before trusting any
GPU timing; `make golden` records the reference line on a known-good build.

`make prove` re-runs keygen whenever `app.pk` is older than `openvm.toml` or than
the `cargo-openvm` binary, which is the cheap guard against the version-mismatch
panic described above.

### `setup --evm --download` is broken on this tag

It fetches `s3://openvm-public-artifacts-us-east-1/v{CARGO_PKG_VERSION}/halo2.pk`,
and `v2.1.0-preview` **left `CARGO_PKG_VERSION` at 2.0.0** — so a 2.1 build
downloads the 2.0.0 halo2 key and verifier and pairs them with a root key it
generated itself. `prove evm` then dies at
`snark-verifier-sdk/src/halo2.rs: SNARK proof failed to verify`, after five
minutes, naming neither artifact.

Generate them instead — it is only 2 min 42, and needs **solc 0.8.19 exactly**
(the verifier's pragma is pinned; 0.8.28 fails with "Source file requires
different compiler version" *after* the key is built):

    curl -sL -o /usr/local/bin/solc \
      https://github.com/ethereum/solidity/releases/download/v0.8.19/solc-static-linux
    chmod +x /usr/local/bin/solc
    cargo openvm setup --evm --force      # no --download
    cargo openvm keygen
    cargo openvm prove evm --input input.json
    cargo openvm verify evm

The contracts land in `~/.openvm/halo2/src/v2.0-base/`. A copy of what this
produced, plus the EVM proof and the run logs, is in `artifacts/evm-run/`.

### Building the guest where you cannot prove it

The prebuilt OpenVM rustc needs GLIBC 2.39 / GLIBCXX 3.4.32 — it is built on
Ubuntu 24.04, and the fork ships one tarball per host triple with no
older-glibc variant. On a 22.04 box the guest **cannot be built**, while proving
works fine (it is a plain CPU/GPU binary). The `.vmexe` is portable bytecode, so:

    make vmexe                                   # on macOS or any 24.04+ box
    scp openvm/release/*.vmexe box:~/
    make prove EXE=~/o1-openvm-verifier.vmexe    # on the GPU box

Also: rustup's fallback for a *linked* toolchain missing `cargo` is nightly's
cargo, specifically. Without a nightly installed, `cargo openvm build` fails with
`'cargo' is not installed for the custom toolchain 'openvm-1.94.1'`.
`scripts/gpu-setup.sh` installs nightly for this reason alone.

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

### Guest input *is* already validated — do not "fix" wire.rs

I claimed for a while that `wire.rs`'s `Vesta::new_unchecked` left the arkworks
path unvalidated, and wrote that into commit `1269196`. It is wrong; the record is
here so nobody acts on it.

`wire.rs` is `cfg(feature = "std")`, host-only: it parses OCaml fixtures to
*assemble* an input. The guest reads postcard, and every curve point in
`UniversalInput` is annotated `#[serde_as(as = "SerdeAs")]`, whose
`deserialize` calls `T::deserialize_compressed` — which in ark-serialize 0.5 is
`deserialize_with_mode(.., Compress::Yes, Validate::Yes)`. That validates both
the curve equation and prime-order subgroup membership.

So both paths validate, just at deserialization rather than at JSON parsing. The
`from_xy` check in the chip path is a redundant second check. Keep it anyway: at
+1.67% it is local and does not depend on reasoning at a distance about what a
serialization layer happens to do.

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

### Measure the git build, not the path build

Local `path` deps and git deps do not produce identical instruction counts: the
canonical-storage change measured 724,385,778 through local paths and
724,387,584 from the pushed branches. The 1,806-instruction gap is the source
paths embedded in panic-location strings, not a code difference — but it means
a number taken during fast iteration will not reproduce from a clean checkout.
Re-measure after switching the deps back to git, and record that one.

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
