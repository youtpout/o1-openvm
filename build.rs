//! Bakes the pickles **protocol constants** into the guest: the two Pasta SRSes
//! plus one wrap Lagrange basis per pickles wrap domain.
//!
//! The Lagrange basis is not an optimisation detail, it is the single most
//! valuable thing in this build. Measured on the SP1 port: with a cold cache
//! kimchi recomputes it via an IFFT over curve points and the guest costs
//! 64.8B cycles; with the basis baked it costs 4.4B. That is x14.8, or 93% of
//! the total. Never ship a guest without it.
//!
//! No verification key is baked: the VK is a runtime input, so one guest binary
//! verifies every pickles circuit.

use std::{env, fs, path::Path};

use mina_curves::pasta::{Pallas, Vesta};
use pickles_verifier::serialize::encode_constants_blob;
use poly_commitment::precomputed_srs::get_srs;

fn main() {
    println!("cargo::rerun-if-changed=build.rs");

    let blob = encode_constants_blob(&get_srs::<Vesta>(), &get_srs::<Pallas>());

    let out_dir = env::var("OUT_DIR").expect("OUT_DIR set by cargo");
    fs::write(Path::new(&out_dir).join("constants.bin"), &blob).expect("write constants.bin");
}
