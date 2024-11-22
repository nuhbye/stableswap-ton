// Events
message LiquidityAddedEvent{
    sender: Address;
    amounts: IntBalances;
    fees: IntBalances;
    invariant: Int as uint256;
    tokenSupply: Int as coins;
}

message SwapTokenEvent{
    sender: Address;
    soldTokenIndex: Int as uint4;
    tokensSold: Int as coins;
    boughtTokenIndex: Int as uint4;
    tokensBought: Int as coins;
}

message RemoveLiquidityEvent{
    sender: Address;
    amounts: IntBalances;
    fees: IntBalances;
    tokenSupply: Int as coins;
}

message RemoveLiquidityOneCoinEvent {
    sender: Address;
    amount: Int as coins;
    tokenSupply: Int as coins;
}

message RemoveLiquidityImbalanceEvent {
    sender: Address;
    amounts: IntBalances;
    fees: IntBalances;
    invariant: Int as uint256;
    tokenSupply: Int as coins;
    tokenBurned: Int as coins;
}

message RampAEvent {
    oldA: Int as uint256;
    newA: Int as uint256;
    initialTime: Int as uint32;
    futureTime: Int as uint32;
}

message StopRampAEvent {
    A: Int as uint256;
    t: Int as uint256;
}
// Messages

message(0x0000003) OperationType {
    type: Int as uint4;
    payload: Slice as remaining;
}

message(0x0000004) SwapTokenRequest {
    queryId: Int as uint32;
    // amount and token in index can be removed
    amount: Int as coins;
    tokenInIndex: Int as uint4;
    tokenOutIndex: Int as uint4;
    minTokenOutAmount: Int as coins;
}

message(0x0000005) AddLiquidityRequest {
    queryId: Int as uint32;
    tokenIndex: Int as uint4;
    tokenBalances: IntBalances;
    minMintAmount: Int as coins;
}

message(0x0000006) AddLiquidityRequestInternal {
    queryId: Int as uint32;
    sender: Address;
    tokenIndex: Int as uint4;
    tokenBalances: IntBalances;
    minMintAmount: Int as coins;
}

message(0x0000007) LiquidityAdded {
    query_id: Int as uint32;
    sender: Address;
    tokenBalances: IntBalances;
    minMintAmount: Int as coins;
}

message(0x0000008) RemoveLiquidityRequest {
    type: Int as uint8;
    minTokenOutBalances: IntBalances;
    // For single token out
    singleTokenOutIndex: Int as uint4;
    minTokenOutAmount: Int as coins;
}

message SetJettonWalletAddresses {
    tokenJettonWallets: TokenJettonWallets;
}

// jetton transfer messages
message(0xf8a7ea5) TokenTransfer {
    query_id: Int as uint64;
    amount: Int as coins;
    destination: Address;
    response_destination: Address;
    custom_payload: Cell?;
    forward_ton_amount: Int as coins;
    forward_payload: Slice as remaining; // Comment Text message when Transfer the jetton
}

message(0x7362d09c) TokenTransferNotification {
    query_id: Int as uint64;
    amount: Int as coins;
    sender: Address;
    forward_payload: Slice as remaining;
}

message(0xd53276db) TokenExcesses {
    query_id: Int as uint64;
}

message(0x595f07bc) TokenBurn {
    query_id: Int as uint64;
    amount: Int as coins;
    response_destination: Address;
    custom_payload: Slice as remaining;
}

message(0x7bdd97de) TokenBurnNotification {
    query_id: Int as uint64;
    amount: Int as coins;
    sender: Address;
    response_destination: Address?;
    custom_payload: Slice as remaining;
}


message(0x0000101) Transfer {
    amount: Int as coins;
    to: Address;
}

message(0x0000102) InternalAddTokens {
    amount: Int as coins;
    origin: Address;
}

message RampA {
    futureA: Int as uint256;
    futureTime: Int as uint32;
}

message StopRampA {

}

// Data structures
struct IntBalances {
    token1: Int as coins;
    token2: Int as coins;
    token3: Int as coins;
}

struct TokenJettonWallets {
    token1: Address;
    token2: Address;
    token3: Address;
}


struct Metadata {
    symbol: String;
    totalSupply: Int;
}

struct SwapTokenCalculateResult {
    dx: Int as coins;
    dy: Int as coins;
    dyAdminFee: Int as coins;
    fee: Int as coins;
    oldBalances: IntBalances;
}

struct CalcLiquidityAddedResult {
    newBalances: IntBalances;
    lpMintAmount: Int as coins;
    fees: IntBalances;
    invariant: Int as uint256;
}

struct RemoveLiquidityResult {
    amounts: IntBalances;
    fees: IntBalances;
}

struct RemoveTokenOneCoinResult {
    dy: Int as coins;
    dyFee: Int as coins;
}

struct CalcRemoveLiquidityImbalanceResult {
    fees: IntBalances;
    invariant: Int as uint256;
    tokenBurned: Int as coins;
}