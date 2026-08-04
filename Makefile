# o1-openvm — build, execute, prove.
#
# GPU proving lives here too: `cuda` is a property of the cargo-openvm binary,
# not of this repo's code, so every target below is identical on CPU and GPU.
# `make setup` is what makes the difference — see CLAUDE.md, "GPU proving".

INPUT       ?= input.json
PROOF       ?= o1-openvm-verifier.app.proof
GOLDEN      ?= expected-output.txt

# A shell opened before `make setup` never re-reads its rc file, so cargo is not
# on its PATH. Cheaper than telling everyone to source ~/.cargo/env.
export PATH := $(HOME)/.cargo/bin:$(PATH)

.PHONY: help setup keygen build vmexe run meter segment prove prove-stark \
        golden check tamper-acc tamper-stmt tamper clean-keys

help:
	@echo "setup        bootstrap a Linux+NVIDIA box (vast.ai) for GPU proving"
	@echo "keygen       regenerate openvm/app.pk if stale"
	@echo "build        build the guest ELF"
	@echo "vmexe        build + transpile only, for copying to a prover box"
	@echo "run          execute the guest on \$$INPUT (no proof)"
	@echo "meter        execute + report instructions and trace cells"
	@echo "segment      execute + report the segment count (proving shape)"
	@echo "prove        generate the app proof (GPU if cargo-openvm has cuda)"
	@echo "prove-stark  generate the aggregated STARK proof"
	@echo "golden       record the current execution output as \$$GOLDEN"
	@echo "check        re-run and diff the execution output against \$$GOLDEN"
	@echo "tamper       both rejection tests: they must panic, revealing nothing"
	@echo "clean-keys   drop app.pk/app.vk (after any openvm.toml or version change)"

setup:
	./scripts/gpu-setup.sh

keygen:
	./scripts/keygen.sh

build:
	cargo openvm build

# Build + transpile only, then name the artifact to copy to a prover box.
# The OpenVM rustc is built on Ubuntu 24.04 and the fork ships one tarball per
# host triple, so it will not run on an older glibc (22.04 = 2.35, the toolchain
# wants 2.39). Proving has no such constraint: build here, prove there.
#   make vmexe && scp openvm/release/*.vmexe box:~/
#   ssh box 'cd o1-openvm && make prove EXE=~/o1-openvm-verifier.vmexe'
vmexe: build
	@ls -lh openvm/release/*.vmexe

run:
	cargo openvm run --input $(INPUT)

# --mode meter needs app.pk; a stale one panics obscurely, hence the dependency.
meter: keygen
	cargo openvm run --mode meter --input $(INPUT)

segment: keygen
	cargo openvm run --mode segment --input $(INPUT)

prove:  # EXE=... to prove a vmexe built elsewhere
	EXE="$(EXE)" ./scripts/prove.sh $(INPUT)

prove-stark: keygen
	cargo openvm prove stark --input $(INPUT)

# Step 3 of the verification protocol. The revealed digest validates the
# Montgomery/canonical conversions, the Fp/Fq crossing, the moduli ordering and
# poly-commitment's TypeId dispatch — all failure modes that still produce a
# clean run. Compare the whole output line rather than parsing it.
golden:
	@cargo openvm run --input $(INPUT) | grep '^Execution output:' > $(GOLDEN)
	@echo "recorded: $$(cat $(GOLDEN))"

check:
	@test -f $(GOLDEN) || { echo "no $(GOLDEN) — run 'make golden' on a known-good build"; exit 1; }
	@cargo openvm run --input $(INPUT) | grep '^Execution output:' > .out.tmp
	@diff -u $(GOLDEN) .out.tmp && echo "digest OK" || { echo "DIGEST MISMATCH"; rm -f .out.tmp; exit 1; }
	@rm -f .out.tmp

# A revealed digest here — even a different one — is an unsound acceptance, so
# the test is "no Execution output at all", not "a different output".
tamper-acc:
	@echo "== tamper=accumulator (Vesta chip, stage 2) must panic"
	@! cargo openvm run --input input-bad-acc.json 2>&1 | tee .tamper.tmp | grep -q '^Execution output:' \
	  || { echo "UNSOUND: guest accepted a tampered accumulator"; rm -f .tamper.tmp; exit 1; }
	@rm -f .tamper.tmp; echo "rejected, nothing revealed"

tamper-stmt:
	@echo "== tamper=statement (Pallas chip, via the wrap kimchi check) must panic"
	@! cargo openvm run --input input-bad-stmt.json 2>&1 | tee .tamper.tmp | grep -q '^Execution output:' \
	  || { echo "UNSOUND: guest accepted a tampered statement"; rm -f .tamper.tmp; exit 1; }
	@rm -f .tamper.tmp; echo "rejected, nothing revealed"

tamper: tamper-acc tamper-stmt

clean-keys:
	rm -rf openvm/app.pk openvm/app.vk
