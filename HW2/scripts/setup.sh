#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh

command -v node >/dev/null || { echo "Install Node.js 24 first." >&2; exit 1; }
command -v pnpm >/dev/null || { echo "Install pnpm 11.25.0 first." >&2; exit 1; }

FOUNDRY_VERSION=1.4.4
SOLC_VERSION=0.8.30
FORGE_STD_VERSION=1.9.7
task_os=$(uname -s)
task_arch=$(uname -m)
case "$task_os:$task_arch" in
    Darwin:arm64)
        task_platform=darwin_arm64
        task_foundry_sha=fcd2295fec449467985866057a148723d8ad625e4f9d86b3aaacc4f0948e5cfe
        task_solc_platform=macosx-amd64
        ;;
    Darwin:x86_64)
        task_platform=darwin_amd64
        task_foundry_sha=2ce82b3fcacf4d440593a9f1161b0e6bd208af3bee71784c162ee9c600c9273a
        task_solc_platform=macosx-amd64
        ;;
    Linux:x86_64)
        task_platform=linux_amd64
        task_foundry_sha=22ba110a40e4de7791b007b08284e7b038c6bd4ce141b7ac34b5accec04f71a4
        task_solc_platform=linux-amd64
        ;;
    *) echo "This setup script supports macOS and Linux x86_64." >&2; exit 1 ;;
esac

mkdir -p .tools
task_tmp=$(mktemp -d)
trap 'rm -rf "$task_tmp"' EXIT

verify_sha256() {
    node -e '
        const fs = require("node:fs");
        const crypto = require("node:crypto");
        const actual = crypto.createHash("sha256").update(fs.readFileSync(process.argv[1])).digest("hex");
        if (actual !== process.argv[2].replace(/^0x/, "")) throw new Error("SHA-256 mismatch: " + process.argv[1]);
    ' "$1" "$2"
}

if [ ! -x .tools/forge ] || [ ! -x .tools/cast ] || [ ! -x .tools/anvil ] \
    || ! .tools/forge --version | head -1 | grep -Fq "1.4.4"; then
    curl -fsSL --retry 3 \
        "https://github.com/foundry-rs/foundry/releases/download/v$FOUNDRY_VERSION/foundry_v${FOUNDRY_VERSION}_${task_platform}.tar.gz" \
        -o "$task_tmp/foundry.tar.gz"
    verify_sha256 "$task_tmp/foundry.tar.gz" "$task_foundry_sha"
    tar -xzf "$task_tmp/foundry.tar.gz" -C .tools forge cast anvil
fi

if [ ! -x .tools/solc ] || ! .tools/solc --version | grep -Fq "0.8.30+commit.73712a01"; then
    curl -fsSL --retry 3 \
        "https://raw.githubusercontent.com/ethereum/solc-bin/gh-pages/$task_solc_platform/list.json" \
        -o "$task_tmp/solc-list.json"
    task_solc_file=$(node -e '
        const d = require(process.argv[1]);
        process.stdout.write(d.releases[process.argv[2]]);
    ' "$task_tmp/solc-list.json" "$SOLC_VERSION")
    task_solc_sha=$(node -e '
        const d = require(process.argv[1]);
        process.stdout.write(d.builds.find(b => b.path === process.argv[2]).sha256);
    ' "$task_tmp/solc-list.json" "$task_solc_file")
    curl -fsSL --retry 3 \
        "https://raw.githubusercontent.com/ethereum/solc-bin/gh-pages/$task_solc_platform/$task_solc_file" \
        -o "$task_tmp/solc"
    verify_sha256 "$task_tmp/solc" "$task_solc_sha"
    mv "$task_tmp/solc" .tools/solc
    chmod +x .tools/solc
fi

if [ ! -f lib/forge-std/src/Test.sol ]; then
    curl -fsSL --retry 3 \
        "https://codeload.github.com/foundry-rs/forge-std/tar.gz/refs/tags/v$FORGE_STD_VERSION" \
        -o "$task_tmp/forge-std.tar.gz"
    verify_sha256 "$task_tmp/forge-std.tar.gz" \
        45157353ab49eab01d294565866731e599b32401757229689ee459aa26b7ee94
    mkdir -p lib/forge-std
    tar -xzf "$task_tmp/forge-std.tar.gz" --strip-components=1 -C lib/forge-std
fi

pnpm install --frozen-lockfile
source scripts/env.sh
forge --version
solc --version
echo "Ready. Run: source scripts/env.sh"
