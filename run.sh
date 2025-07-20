#!/bin/bash

set -e

# Prompt for API key and number of submissions
read -p "🔐 Enter your API key: " API_KEY
read -p "🔢 How many submissions to generate? " N

if [[ -z "$API_KEY" || -z "$N" ]]; then
  echo "❌ Missing API key or submission count!"
  exit 1
fi

# ========== STEP 0: CHECK & INSTALL RUST ==========
echo "🔎 Checking for Rust..."
if ! command -v cargo &> /dev/null; then
  echo "⚙️  Rust not found. Installing Rust..."
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
  source $HOME/.cargo/env
else
  echo "✅ Rust is already installed."
fi

# ========== STEP 0.1: CHECK & INSTALL CIRCOM 2.x ==========
echo "🔎 Checking for Circom 2.x..."
CIRCOM_VERSION=$(circom --version 2>/dev/null || echo "none")
if [[ "$CIRCOM_VERSION" != 2* ]]; then
  echo "⚙️  Circom 2.x not found or wrong version. Installing Circom 2.1.9..."
  if [ ! -d "circom" ]; then
    git clone https://github.com/iden3/circom.git
  fi
  cd circom
  git fetch --all
  git checkout v2.1.9
  cargo build --release
  sudo cp target/release/circom /usr/local/bin/
  cd ..
else
  echo "✅ Circom 2.x is already installed."
fi

# ========== STEP 0.2: CHECK & INSTALL SNARKJS ==========
echo "🔎 Checking for snarkjs..."
if ! command -v snarkjs &> /dev/null; then
  echo "⚙️  snarkjs not found. Installing snarkjs globally..."
  npm install -g snarkjs
else
  echo "✅ snarkjs is already installed."
fi

# ========== STEP 1: ENV SETUP ==========
echo "✅ Installing dependencies..."
sudo apt update && sudo apt install -y curl git jq
npm install circomlib

# ========== STEP 2: COMPILE CIRCUIT ==========
echo "✅ Compiling circuit..."
mkdir -p circuits/in_range_js keys proofs input witness scripts

cat > circuits/in_range.circom <<EOF
pragma circom 2.0.0;
include "../node_modules/circomlib/circuits/comparators.circom";

template InRange() {
    signal input x;
    signal output in_range;

    component ge = GreaterEqThan(8); // 8 bits, đủ cho số nhỏ
    ge.in[0] <== x;
    ge.in[1] <== 5;

    component le = LessEqThan(8);
    le.in[0] <== x;
    le.in[1] <== 15;

    in_range <== ge.out * le.out;
}

component main = InRange();
EOF

circom circuits/in_range.circom --r1cs --wasm --sym -o circuits/

# ========== STEP 3: PTAU & ZKEY ==========
echo "✅ Preparing powers of tau and zkey..."
snarkjs powersoftau new bn128 12 pot12_0000.ptau -v
snarkjs powersoftau contribute pot12_0000.ptau pot12_0001.ptau --name="zkverify" -v -e="zkverify-testnet"
snarkjs powersoftau prepare phase2 pot12_0001.ptau pot12_final.ptau

snarkjs groth16 setup circuits/in_range.r1cs pot12_final.ptau keys/in_range.zkey
snarkjs zkey export verificationkey keys/in_range.zkey keys/verification_key.json

# ========== STEP 4: CREATE generatePayload.js ==========
echo "✅ Creating generatePayload.js..."

cat > scripts/generatePayload.js <<'EOF'
const fs = require("fs");

const proof = JSON.parse(fs.readFileSync("proofs/proof.json", "utf8"));
const publicSignals = JSON.parse(fs.readFileSync("proofs/public.json", "utf8"));
const vk = JSON.parse(fs.readFileSync("keys/verification_key.json", "utf8"));

const payload = {
  proofType: "groth16",
  vkRegistered: false,
  proofOptions: {
    library: "snarkjs",
    curve: "bn128"
  },
  proofData: {
    proof: {
      pi_a: proof.pi_a.map(String),
      pi_b: proof.pi_b.map(pair => pair.map(String)),
      pi_c: proof.pi_c.map(String)
    },
    publicSignals: publicSignals.map(String),
    vk
  }
};

fs.writeFileSync("payload.json", JSON.stringify(payload, null, 2));
EOF

# ========== STEP 5–7: LOOP PROOFS ==========
echo "✅ Starting loop to create and submit payloads..."

> submit.log

for i in $(seq 1 $N); do
  echo "🔁 [$i/$N] Generating input..."
  X=$(( RANDOM % 20 + 1 ))
  echo "{ \"x\": $X }" > input/input.json

  snarkjs wtns calculate circuits/in_range_js/in_range.wasm input/input.json witness/witness.wtns
  snarkjs groth16 prove keys/in_range.zkey witness/witness.wtns proofs/proof.json proofs/public.json

  node scripts/generatePayload.js

  SUCCESS=false
  ATTEMPT=1

  while [ $SUCCESS = false ] && [ $ATTEMPT -le 5 ]; do
    echo "🚀 Submitting payload #$i (Attempt $ATTEMPT)..."
    RESPONSE=$(curl -s -X POST https://relayer-api.horizenlabs.io/api/v1/submit-proof/$API_KEY \
      -H "Content-Type: application/json" \
      -d @payload.json)

    echo "[$i][$ATTEMPT] $RESPONSE" | tee -a submit.log

    if [[ $RESPONSE == *"Too Many Requests"* ]]; then
      echo "⏳ Too Many Requests. Waiting before retry..."
      RETRY_DELAY=$(( RANDOM % 61 + 60 )) # Wait 100-200s
      echo "⏳ Waiting $RETRY_DELAY seconds before retry..."
      sleep $RETRY_DELAY
      ((ATTEMPT++))
    else
      SUCCESS=true
    fi
  done

  DELAY=$(( RANDOM % 61 + 60 )) # Wait randomly from 120 to 300 seconds (2–5 minutes)
  echo "⏳ Waiting $DELAY seconds before next submission... "
  sleep $DELAY
done

echo "🎉 Done. All results saved in submit.log"

echo -e "\n💡 Note: To avoid duplication, each user should change the circuit (file circuits/sum_greater_than.circom) to their own unique circuit!" 
