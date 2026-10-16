# Run from the HW2 project root: source scripts/env.sh
export PATH="$PWD/.tools:$PATH"
if [ -x "$PWD/.tools/solc" ]; then
    export FOUNDRY_SOLC_VERSION="$PWD/.tools/solc"
fi
