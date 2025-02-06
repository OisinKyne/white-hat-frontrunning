#!/usr/bin/env bash

############################################
# Skills are what matters. Not cheap talk. #
############################################

# @license GNU Affero General Public License v3.0 only
# @author pcaversaccio

# Enable strict error handling:
# -E: Inherit `ERR` traps in functions and subshells.
# -e: Exit immediately if a command exits with a non-zero status.
# -u: Treat unset variables as an error and exit.
# -o pipefail: Return the exit status of the first failed command in a pipeline.
set -Eeuo pipefail

# Enable debug mode if the environment variable `DEBUG` is set to `true`.
if [[ "${DEBUG:-false}" == "true" ]]; then
    # Print each command before executing it.
    set -x
fi

# Load environment variables from `.env` file.
if [[ -f .env ]]; then
    set -a
    . ./.env
    set +a
else
    echo ".env file not found"
    exit 1
fi

# Utility function to check if a variable is set without exposing its value.
check_var() {
    if [[ -z "${!1}" ]]; then
        echo "Error: $1 is not set in the .env file"
        exit 1
    else
        echo "$1 is set"
    fi
}

vars=(
    PROVIDER_URL
    RELAY_URL
    VICTIM_PK
    GAS_PK
    FLASHBOTS_SIGNATURE_PK
    TOKEN_CONTRACT
    WSTETH_ADDRESS
    OBOLLIDOSPLIT_ADDRESS
    SPLITPROXY_ADDRESS
    SPLITPROXY_ACCOUNTS
    SPLITPROXY_AMOUNTS
    SAFE_ADDRESS
)

# Check if the required environment variables are set.
for var in "${vars[@]}"; do
    check_var "$var"
done

echo "Private keys and RPC URLs loaded successfully!"

# Utility function to derive a wallet address.
derive_wallet() {
    local pk="$1"
    cast wallet address --private-key "$pk"
}

# Derive the wallets.
VICTIM_WALLET=$(derive_wallet "$VICTIM_PK")
GAS_WALLET=$(derive_wallet "$GAS_PK")
FLASHBOTS_WALLET=$(derive_wallet "$FLASHBOTS_SIGNATURE_PK")

# Utility function to create the Flashbots signature (https://docs.flashbots.net/flashbots-auction/advanced/rpc-endpoint#authentication).
create_flashbots_signature() {
    local payload="$1"
    local private_key="$2"
    local payload_keccak=$(cast keccak "$payload")
    local payload_hashed=$(cast hash-message "$payload_keccak")
    local signature=$(cast wallet sign "$payload_hashed" --private-key "$private_key" --no-hash | tr -d '\n')
    echo "$signature"
}

# Utility function to build a transaction.
build_transaction() {
    local from_pk="$1"
    local to_address="$2"
    local value="$3"
    local nonce="$4"
    local gas_limit="$5"
    local gas_price="$6"
    local data="${7:-}"

    # Note that `--gas-price` is the maximum fee per gas for EIP-1559
    # transactions. See here: https://book.getfoundry.sh/reference/cli/cast/mktx.
    cast mktx --private-key "$from_pk" \
        --rpc-url "$PROVIDER_URL" \
        "$to_address" $( [[ -n "$data" ]] && echo -n "$data" ) \
        --value "$value" \
        --nonce "$nonce" \
        --gas-price "$gas_price" \
        --gas-limit "$gas_limit"
}

# Utility function to create the bundle.
create_bundle() {
    local BLOCK_NUMBER="$1"
    shift

    local txs=()
    # Loop through all the remaining arguments (transaction hashes).
    for tx in "$@"; do
        txs+=("\"$tx\"")
    done

    # Join the transaction hashes into a comma-separated string.
    # Note that `IFS` stands for "Internal Field Separator". It is
    # a special variable in Bash that determines how Bash recognises
    # word boundaries. By setting `IFS=,` we instruct Bash to use a
    # comma as a separator for words in the subsequent command.
    local txs_string=$(IFS=,; echo -n "${txs[*]}")

    # Create the bundle JSON.
    BUNDLE_JSON="{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_sendBundle\",\"params\":[{\"txs\":[$txs_string],\"blockNumber\":\"$(cast to-hex "$BLOCK_NUMBER")\",\"minTimestamp\":0}]}"
    echo -n "$BUNDLE_JSON"
}

# Utility function to send the bundle.
send_bundle() {
    local bundle_json="$1"

    # Prepare the common headers.
    local headers=(
        -H "Content-Type: application/json"
    )

    # Check if `RELAY_URL` contains `flashbots.net`. Flashbots relays require
    # a specific signature header for authentication. Other relays may not
    # accept or require this header, so we only include it for Flashbots.
    if [[ "$RELAY_URL" == *"flashbots.net"* ]]; then
        local flashbots_signature=$(create_flashbots_signature "$bundle_json" "$FLASHBOTS_SIGNATURE_PK")
        headers+=(-H "X-Flashbots-Signature: $FLASHBOTS_WALLET:$flashbots_signature")
    fi

    # Send the request with the appropriate headers.
    curl -X POST "${headers[@]}" \
         -d "$(echo -n "$bundle_json")" "$RELAY_URL"
}

#####################################
# CUSTOMISE ACCORDING TO YOUR NEEDS #
#####################################

# This program relies on Anvil mainnet forking, to calculate balances for the bundle. 
#

echo "Program start: "

# Retrieve and adjust the gas price by 20%.
GAS_PRICE=$(cast gas-price --rpc-url "$PROVIDER_URL")
GAS_PRICE=$(( (GAS_PRICE * 120) / 100 ))

# Set the gas limits for the different transfers.
TRANSFER_ETH=21000
TRANSFER_TOKEN_GAS=80000
DISTRIBUTE_OLS_GAS=262000
DISTRIBUTE_SPLITMAIN_GAS=250000
WITHDRAW_SPLITMAIN_GAS=200000

# Calculate the gas cost to fill and convert to ether.
GAS_TO_FILL=$(( GAS_PRICE * TRANSFER_TOKEN_GAS ))
echo "GAS TO FILL: $(cast to-unit $GAS_TO_FILL ether)"

# Get the next block number.
BLOCK_NUMBER=$(( $(cast block-number --rpc-url "$PROVIDER_URL") + 1 ))

# Retrieve the account nonces for the gas and victim wallet.
GAS_NONCE_1=$(cast nonce "$GAS_WALLET" --rpc-url "$PROVIDER_URL")
GAS_NONCE_2=$(( $GAS_NONCE_1+1))
GAS_NONCE_3=$(( $GAS_NONCE_2+1))
GAS_NONCE_4=$(( $GAS_NONCE_3+1))
GAS_NONCE_5=$(( $GAS_NONCE_4+1))
VICTIM_NONCE=$(cast nonce "$VICTIM_WALLET" --rpc-url "$PROVIDER_URL")

echo "First Gas Nonce: $GAS_NONCE_1. Last gas nonce: $GAS_NONCE_5"
echo "Vitim Nonce: $VICTIM_NONCE"


# Build the transactions.

# 1. ObolLidoSplit.distribute()
# 2. SplitMain.distributeERC20()
# 3. SplitMain.withdraw()
# 4. gas_wallet transfer eth -> victim
# 5. wstEth.transfer(clean_address)


#1. Distributing the stEth (wrapping it and pushing to splitter)
PAYLOAD=$(cast calldata "distribute()")
TX1=$(build_transaction "$GAS_PK" "$OBOLLIDOSPLIT_ADDRESS" 0 "$GAS_NONCE_1" "$DISTRIBUTE_OLS_GAS" "$GAS_PRICE" "$PAYLOAD")


#2. Distributing the wstEth for withdraw
PAYLOAD=$(cast calldata "distributeERC20(address,address,address[],uint32[],uint32,address)" "$SPLITPROXY_ADDRESS" "$WSTETH_ADDRESS" "$SPLITPROXY_ACCOUNTS" "$SPLITPROXY_AMOUNTS" "0" "0x0000000000000000000000000000000000000000")
TX2=$(build_transaction "$GAS_PK" "$SPLITMAIN_ADDRESS" 0 "$GAS_NONCE_2" "$DISTRIBUTE_SPLITMAIN_GAS" "$GAS_PRICE" "$PAYLOAD")


#3. Withdrawing wstEth from splitmain to victim address

# Calculate wstEth to withdraw by simulating tx1 and tx2
cast publish -vvvv --rpc-url $PROVIDER_URL $TX1
cast publish -vvvv --rpc-url $PROVIDER_URL $TX2
# Now read Victim's wstEth balance from SplitMain
WSTETH_TO_WITHDRAW=$(cast to-dec $(cast call $SPLITMAIN_ADDRESS "getERC20Balance(address,address)" "$VICTIM_WALLET" "$WSTETH_ADDRESS" --rpc-url $PROVIDER_URL))
echo ""
echo "There is $WSTETH_TO_WITHDRAW worth of wstETH withdrawable from SplitMain."
echo ""

# Prep TX3 with that amount
PAYLOAD=$(cast calldata "withdraw(address,uint256,address[])" "$VICTIM_WALLET" "0" "[$WSTETH_ADDRESS]")
TX3=$(build_transaction "$GAS_PK" "$SPLITMAIN_ADDRESS" 0 "$GAS_NONCE_3" "$WITHDRAW_SPLITMAIN_GAS" "$GAS_PRICE" "$PAYLOAD")

# Now simulate this tx to confirm withdrawable wstEth balance
cast publish -vvvv --rpc-url $PROVIDER_URL $TX3

TOKEN_AMOUNT=$(cast to-dec $(cast call $WSTETH_ADDRESS "balanceOf(address)" "$VICTIM_WALLET" --rpc-url $PROVIDER_URL))
echo ""
echo "Transferring $TOKEN_AMOUNT worth of wstETH out of compromised wallet. Should be identical or higher than prior number."
echo ""

# 4. Transfer of ETH to the victim wallet.
TX4=$(build_transaction "$GAS_PK" "$VICTIM_WALLET" "$GAS_TO_FILL" "$GAS_NONCE_4" "$TRANSFER_ETH" "$GAS_PRICE")

# 5. Transfer the wstEth from the victim wallet
PAYLOAD=$(cast calldata "transfer(address,uint256)" "$SAFE_ADDRESS" "$TOKEN_AMOUNT")
TX5=$(build_transaction "$VICTIM_PK" "$WSTETH_ADDRESS" 0 "$VICTIM_NONCE" "$TRANSFER_TOKEN_GAS" "$GAS_PRICE" "$PAYLOAD")

# Test publish these transactions to anvil

BALANCE=$(cast balance $VICTIM_WALLET --rpc-url $PROVIDER_URL)
echo "Victim before gas eth balance: $BALANCE"

cast publish -vvvv --rpc-url $PROVIDER_URL $TX4

BALANCE=$(cast balance $VICTIM_WALLET --rpc-url $PROVIDER_URL)
echo "Victim after gas eth balance: $BALANCE"

cast publish -vvvv --rpc-url $PROVIDER_URL $TX5

TOKEN_AMOUNT=$(cast to-dec $(cast call $WSTETH_ADDRESS "balanceOf(address)" "$VICTIM_WALLET" --rpc-url $PROVIDER_URL))
echo ""
echo "Only $TOKEN_AMOUNT worth of wstETH remaining in compromised wallet after extraction tx."
echo ""
BALANCE=$(cast balance $VICTIM_WALLET --rpc-url $PROVIDER_URL)
echo "Victim address remaining eth balance: $BALANCE"

TOKEN_AMOUNT=$(cast to-dec $(cast call $WSTETH_ADDRESS "balanceOf(address)" "$SAFE_ADDRESS" --rpc-url $PROVIDER_URL))
echo ""
echo " $TOKEN_AMOUNT worth of wstETH in the clean address."
echo ""


# Test transactions end here



# List transactions
echo ""
echo ""
echo "Transactions: "
echo "TX1: $TX1"
echo "TX2: $TX2"
echo "TX3: $TX3"
echo "TX4: $TX4"
echo "TX5: $TX5"
echo ""
# echo "TX2: $TX2"

# Prepare the bundle JSON.
BUNDLE_JSON=$(create_bundle "$(cast to-hex $BLOCK_NUMBER)" "$TX1" "$TX2" "$TX3" "$TX4" "$TX5")
echo -e "Bundle JSON:\n$BUNDLE_JSON"
# echo "$BUNDLE_JSON" > bundle.json

# Send the bundle.
echo "Skipping bundle send."
echo ""
echo ""
# send_bundle "$BUNDLE_JSON"

# To execute you need to set env vars
# Run an anvil chain with `anvil --fork-url $(MAINNET_RPC_URL)`
# Test the script if you like
# When validated, you uncomment send bundle and it will attempt to
# broadcast to flashbots relay. If it doesn't make it into the exact
# block you may have to run the script again. (Resetting anvil in between if you want the simulations to go how you expect)