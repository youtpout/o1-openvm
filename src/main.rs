//! OpenVM guest: universal pickles verification.
//!
//! Port of the SP1 guest (`o1js-to-zkvm/crates/o1-verifier`) onto OpenVM, so the
//! two zkVMs can be compared on identical work. The verifier core is shared
//! verbatim -- this file only handles I/O and the entrypoint.
//!
//! ```text
//! stdin  : postcard(UniversalInput { vk_bytes, statement, proof })
//! reveal : keccak256(abi.encode(bytes32 vkHash, bytes32[] statement))
//! panic  : if the proof does not verify
//! ```
//!
//! OpenVM's user public output is exactly 32 bytes, so unlike the SP1 port --
//! which commits variable-length public values -- the attestation has to be
//! folded into one digest. A caller supplies the preimage and the consumer
//! recomputes the digest, which is also cheaper on-chain: 32 bytes of public
//! output instead of the whole statement.
//!
//! Panicking rather than revealing a validity flag is deliberate: a proof then
//! exists only for accepted inputs, so a consumer cannot forget to check a
//! boolean.
//!
//! # Status
//!
//! This is the **baseline**: no Pasta-specific acceleration. `parallel` is off
//! (see Cargo.toml), which is the one thing that must be right in any zkVM
//! build. OpenVM's modular-arithmetic and Weierstrass extensions accept
//! arbitrary moduli and curves, so Pallas/Vesta chips are possible -- but they
//! act on OpenVM's own types, while kimchi works on arkworks types throughout.
//! Bridging the two is the next piece of work, and where the ~95% of cycles
//! spent on Pasta curve arithmetic can actually be attacked.

extern crate alloc;

use ark_ff::{BigInteger, PrimeField};
use openvm::io::{read_vec, reveal_bytes32};
use openvm_keccak256::keccak256;
use pickles_verifier::serialize::decode_constants_blob;
use pickles_verifier::types::{StepField, UniversalInput};
use pickles_verifier::verify_universal;

// Emits the `moduli_init!` that pairs with mina-curves' `moduli_declare!`,
// generated from openvm.toml's `supported_moduli`. Without it the guest traps on
// the first modular operation.
openvm::init!();

/// 8-byte aligned wrapper around `include_bytes!`. The blob's pod sections are
/// `bytemuck::cast_slice`d, which needs 8-byte alignment; raw `include_bytes!`
/// data is 1-byte aligned.
#[repr(C, align(8))]
struct Aligned<T: ?Sized>(T);

static CONSTANTS_BYTES: &Aligned<[u8]> =
    &Aligned(*include_bytes!(concat!(env!("OUT_DIR"), "/constants.bin")));

/// Canonical big-endian 32-byte encoding. Both Pasta moduli are below 2^255, so
/// every element fits and the encoding is injective.
fn field_to_be_bytes(x: &StepField) -> [u8; 32] {
    let mut be = [0u8; 32];
    let bytes = x.into_bigint().to_bytes_be();
    be[32 - bytes.len()..].copy_from_slice(&bytes);
    be
}

/// `abi.encode(bytes32 vkHash, bytes32[] statement)`: a 32-byte head holding
/// `vkHash`, a 32-byte offset to the array, then its length and elements.
fn abi_encode(a: &pickles_verifier::types::Attestation) -> alloc::vec::Vec<u8> {
    let mut out = alloc::vec::Vec::with_capacity(96 + 32 * a.statement.len());
    out.extend_from_slice(&field_to_be_bytes(&a.vk_hash));
    let mut offset = [0u8; 32];
    offset[24..].copy_from_slice(&64u64.to_be_bytes()); // two head words
    out.extend_from_slice(&offset);
    let mut len = [0u8; 32];
    len[24..].copy_from_slice(&(a.statement.len() as u64).to_be_bytes());
    out.extend_from_slice(&len);
    for f in &a.statement {
        out.extend_from_slice(&field_to_be_bytes(f));
    }
    out
}

fn main() {
    let constants = decode_constants_blob(&CONSTANTS_BYTES.0);

    let input_bytes = read_vec();
    let input: UniversalInput =
        postcard::from_bytes(&input_bytes).expect("decode UniversalInput");

    let attestation = verify_universal(&constants, input).expect("pickles verification failed");

    // Fold the attestation into one digest. The layout is Solidity's
    // `abi.encode(bytes32, bytes32[])`, so a consumer recomputes it straight
    // from calldata with `keccak256(abi.encode(...))`.
    //
    // The statement's length is inside the encoding, which matters: Mina's
    // Poseidon zero-pads its final block, so for some circuits a prover can
    // present `[s]` as `[s, 0]`. Committing the length lets a consumer pin the
    // arity its circuit declares and reject the padded variant.
    reveal_bytes32(keccak256(&abi_encode(&attestation)));
}
