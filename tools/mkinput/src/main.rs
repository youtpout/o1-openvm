//! Produce the OpenVM guest's input file from a pickles fixture directory.
//!
//! OpenVM's CLI takes either a hex string or a JSON file of hex strings, each
//! prefixed `0x01` for raw bytes (`0x02` would mean native field elements). We
//! emit the JSON form because a full `UniversalInput` is far too large for a
//! command-line argument.
//!
//! The wire format between host and guest is postcard, chosen over OpenVM's own
//! serde-over-words so the payload is identical to what the SP1 port ships --
//! the two zkVMs then verify byte-for-byte the same input.
//!
//! Usage: mkinput <fixture_dir> <max_proofs_verified> [out.json] [--tamper=MODE]
//!
//! `--tamper` produces a deliberately invalid input so the guest's *rejection*
//! path can be exercised. The host test suite covers rejection on the arkworks
//! path; this is how we cover it on the chip path, where a bug could in
//! principle turn a rejection into an acceptance.
//!
//!   accumulator  replace the IPA accumulator commitment -> stage 2 must fail
//!   statement    bump statement[0] -> the in-guest digest changes, so the wrap
//!                kimchi check must fail. This is the mode that exercises the
//!                Pallas chip in a rejection scenario.

use std::{env, fs, path::Path};

use ark_ec::AffineRepr;
use ark_ff::One;
use pickles_verifier::convert::universal_input_from_fixture;
use pickles_verifier::wire::{parse_app_statement, parse_wrap_proof, parse_wrap_vk, OcamlProof};

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 3 {
        eprintln!("usage: mkinput <fixture_dir> <max_proofs_verified> [out.json]");
        std::process::exit(2);
    }
    let dir = Path::new(&args[1]);
    let mpv: u8 = args[2].parse().expect("max_proofs_verified must be 0, 1 or 2");
    let out = args
        .get(3)
        .map(String::as_str)
        .filter(|a| !a.starts_with("--"))
        .unwrap_or("input.json");
    let tamper = args.iter().find_map(|a| a.strip_prefix("--tamper="));

    let read = |name: &str| {
        let p = dir.join(name);
        fs::read_to_string(&p).unwrap_or_else(|e| panic!("read {}: {e}", p.display()))
    };

    let wrap_vk = parse_wrap_vk(&read("vk.serde.json")).expect("vk.serde.json");
    let wrap_proof = parse_wrap_proof(&read("proof.serde.json")).expect("proof.serde.json");
    let ocaml = OcamlProof::parse(&read("public_input_skeleton.json")).expect("skeleton");
    let statement = parse_app_statement(&read("app_statement.json")).expect("app_statement");

    let input = universal_input_from_fixture(
        ocaml,
        wrap_proof,
        &wrap_vk,
        vec![statement],
        mpv,
        /* step_num_chunks */ 1,
    )
    .expect("assemble UniversalInput");

    let mut input = input;
    match tamper {
        None => {}
        Some("accumulator") => {
            // A valid curve point, but not the one the proof committed to.
            input.proof.challenge_polynomial_commitment =
                mina_curves::pasta::Vesta::generator();
        }
        Some("statement") => {
            input.statement[0] += pickles_verifier::types::StepField::one();
        }
        Some(other) => panic!("unknown --tamper mode `{other}`"),
    }
    if let Some(mode) = tamper {
        eprintln!("WARNING: emitting a deliberately invalid input (--tamper={mode})");
    }

    let bytes = postcard::to_allocvec(&input).expect("postcard encode");
    // 0x01 tells OpenVM to treat the payload as raw bytes, matching read_vec().
    let payload = format!("0x01{}", hex::encode(&bytes));
    let json = serde_json::json!({ "input": [payload] });
    fs::write(out, serde_json::to_vec(&json).expect("json")).expect("write input file");

    println!("{out}: {} bytes of postcard payload", bytes.len());
}
