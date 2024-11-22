import { Blockchain, printTransactionFees, SandboxContract, TreasuryContract } from '@ton/sandbox';
import { toNano, Cell, Address, beginCell, Contract, Builder } from '@ton/core';
import {
    IntBalances,
    StableSwapPool,
    storeAddLiquidityRequest,
    storeOperationType,
    storeRemoveLiquidityRequest,
    storeSwapTokenRequest,
    SwapTokenRequest,
    RemoveLiquidityRequest,
} from '../wrappers/StableSwapPool';
import { SampleJetton } from '../wrappers/SampleJetton';
import { JettonDefaultWallet } from '../wrappers/JettonDefaultWallet';
import { RemoveLiquidityResult, StableSwapPoolWallet } from '../wrappers/StableSwapPoolWallet';
import '@ton/test-utils';
import { assert } from 'node:console';

const ADD_LIQUIDITY_GAS = toNano('0.2');
const REMOVE_LIQUIDITY_GAS = toNano('0.2');
const SWAP_GAS = toNano('0.2');

const TOKEN_INDEX_DAI = 0n;
const TOKEN_INDEX_USDC = 1n;
const TOKEN_INDEX_USDT = 2n;

function delay(ms: number) {
    return new Promise((resolve) => setTimeout(resolve, ms));
}

function toMicro(amount: bigint) {
    return amount * 1000000n;
}

function toEther(amount: bigint) {
    return amount * 1000000000000000000n;
}

async function getUserJettonWallet(blockchain: Blockchain, userAddress: Address, jettonMasterAddress: Address) {
    return blockchain.openContract(await JettonDefaultWallet.fromInit(jettonMasterAddress, userAddress));
}

async function getBalance(jettonWallet: SandboxContract<JettonDefaultWallet>) {
    return (await jettonWallet.getGetWalletData()).balance;
}

async function deployJettonMaster(
    blockchain: Blockchain,
    deployer: SandboxContract<TreasuryContract>,
    amount: bigint,
    jetton_name: string,
): Promise<SandboxContract<SampleJetton>> {
    const jettonMaster = blockchain.openContract(
        await SampleJetton.fromInit(deployer.address, Cell.EMPTY, amount, jetton_name),
    );

    const jettonDeployResult = await jettonMaster.send(
        deployer.getSender(),
        {
            value: toNano('0.05'),
        },
        {
            $$type: 'Deploy',
            queryId: 0n,
        },
    );

    expect(jettonDeployResult.transactions).toHaveTransaction({
        from: deployer.address,
        to: jettonMaster.address,
        deploy: true,
        success: true,
    });

    return jettonMaster;
}

async function mintJettons(
    blockchain: Blockchain,
    jettonMaster: SandboxContract<SampleJetton>,
    user: SandboxContract<TreasuryContract>,
    deployer: SandboxContract<TreasuryContract>,
    amount: bigint,
) {
    const mintResult = await jettonMaster.send(
        deployer.getSender(),
        {
            value: toNano('0.05'),
        },
        {
            $$type: 'Mint',
            amount: amount,
            receiver: user.address,
        },
    );

    expect(mintResult.transactions).toHaveTransaction({
        from: deployer.address,
        to: jettonMaster.address,
        success: true,
    });

    const userJettonWallet = await getUserJettonWallet(blockchain, user.address, jettonMaster.address);
    const walletData = await userJettonWallet.getGetWalletData();
    expect(walletData.balance).toEqual(amount);
}

async function setJettonWalletAddresses(
    blockchain: Blockchain,
    deployer: SandboxContract<TreasuryContract>,
    stableSwap: SandboxContract<StableSwapPool>,
    jettonMasterDai: SandboxContract<SampleJetton>,
    jettonMasterUsdc: SandboxContract<SampleJetton>,
    jettonMasterUsdt: SandboxContract<SampleJetton>,
) {
    const jettonWalletDai = await getUserJettonWallet(blockchain, stableSwap.address, jettonMasterDai.address);
    const jettonWalletUsdc = await getUserJettonWallet(blockchain, stableSwap.address, jettonMasterUsdc.address);
    const jettonWalletUsdt = await getUserJettonWallet(blockchain, stableSwap.address, jettonMasterUsdt.address);

    const setJettonWalletAddressesResult = await stableSwap.send(
        deployer.getSender(),
        {
            value: toNano('0.05'),
        },
        {
            $$type: 'SetJettonWalletAddresses',
            tokenJettonWallets: {
                $$type: 'TokenJettonWallets',
                token1: jettonWalletDai.address,
                token2: jettonWalletUsdc.address,
                token3: jettonWalletUsdt.address,
            },
        },
    );

    expect(setJettonWalletAddressesResult.transactions).toHaveTransaction({
        from: deployer.address,
        to: stableSwap.address,
        success: true,
    });

    return { jettonWalletDai, jettonWalletUsdc, jettonWalletUsdt };
}

const DAI_INDEX = 0n;
const USDC_INDEX = 1n;
const USDT_INDEX = 2n;

describe('StableSwap', () => {
    const TOKEN_TO_MINT_MICRO = toMicro(10000n);
    const TOKEN_TO_MINT_ETHER = toEther(10000n);

    let blockchain: Blockchain;
    let deployer: SandboxContract<TreasuryContract>;
    let user1: SandboxContract<TreasuryContract>;
    let user2: SandboxContract<TreasuryContract>;
    let stableSwap: SandboxContract<StableSwapPool>;

    let jettonMasterUsdt: SandboxContract<SampleJetton>;
    let jettonMasterUsdc: SandboxContract<SampleJetton>;
    let jettonMasterDai: SandboxContract<SampleJetton>;

    let user1JettonWalletUsdt: SandboxContract<JettonDefaultWallet>;
    let user1JettonWalletUsdc: SandboxContract<JettonDefaultWallet>;
    let user1JettonWalletDai: SandboxContract<JettonDefaultWallet>;
    let user1LPTokenWallet: SandboxContract<StableSwapPoolWallet>;

    let user2JettonWalletUsdt: SandboxContract<JettonDefaultWallet>;
    let user2JettonWalletUsdc: SandboxContract<JettonDefaultWallet>;
    let user2JettonWalletDai: SandboxContract<JettonDefaultWallet>;

    let stableSwapJettonWalletDai: SandboxContract<JettonDefaultWallet>;
    let stableSwapJettonWalletUsdc: SandboxContract<JettonDefaultWallet>;
    let stableSwapJettonWalletUsdt: SandboxContract<JettonDefaultWallet>;

    beforeEach(async () => {
        blockchain = await Blockchain.create();

        deployer = await blockchain.treasury('deployer');
        user1 = await blockchain.treasury('user1');
        user2 = await blockchain.treasury('user2');

        jettonMasterUsdt = await deployJettonMaster(blockchain, deployer, 1000000000n * TOKEN_TO_MINT_MICRO, 'USDT');
        jettonMasterUsdc = await deployJettonMaster(blockchain, deployer, 1000000000n * TOKEN_TO_MINT_MICRO, 'USDC');
        jettonMasterDai = await deployJettonMaster(blockchain, deployer, 1000000000n * TOKEN_TO_MINT_ETHER, 'DAI');

        await mintJettons(blockchain, jettonMasterDai, user1, deployer, TOKEN_TO_MINT_ETHER);
        await mintJettons(blockchain, jettonMasterUsdc, user1, deployer, TOKEN_TO_MINT_MICRO);
        await mintJettons(blockchain, jettonMasterUsdt, user1, deployer, TOKEN_TO_MINT_MICRO);

        await mintJettons(blockchain, jettonMasterDai, user2, deployer, TOKEN_TO_MINT_ETHER);
        await mintJettons(blockchain, jettonMasterUsdc, user2, deployer, TOKEN_TO_MINT_MICRO);
        await mintJettons(blockchain, jettonMasterUsdt, user2, deployer, TOKEN_TO_MINT_MICRO);

        user1JettonWalletUsdt = await getUserJettonWallet(blockchain, user1.address, jettonMasterUsdt.address);
        user1JettonWalletUsdc = await getUserJettonWallet(blockchain, user1.address, jettonMasterUsdc.address);
        user1JettonWalletDai = await getUserJettonWallet(blockchain, user1.address, jettonMasterDai.address);

        user2JettonWalletUsdt = await getUserJettonWallet(blockchain, user2.address, jettonMasterUsdt.address);
        user2JettonWalletUsdc = await getUserJettonWallet(blockchain, user2.address, jettonMasterUsdc.address);
        user2JettonWalletDai = await getUserJettonWallet(blockchain, user2.address, jettonMasterDai.address);

        stableSwap = blockchain.openContract(
            await StableSwapPool.fromInit(deployer.address, 'DAIUSDTUSDC', 85n, 4000000n, 5000000000n),
        );

        const deployResult = await stableSwap.send(
            deployer.getSender(),
            {
                value: toNano('1'),
            },
            {
                $$type: 'Deploy',
                queryId: 0n,
            },
        );

        expect(deployResult.transactions).toHaveTransaction({
            from: deployer.address,
            to: stableSwap.address,
            deploy: true,
            success: true,
        });

        user1LPTokenWallet = blockchain.openContract(
            await StableSwapPoolWallet.fromAddress(await stableSwap.getChildAddress(user1.address)),
        );

        // Send basic amount to run contract
        const sendTonResult = await stableSwap.send(
            deployer.getSender(),
            {
                value: toNano('10'),
            },
            null,
        );

        expect(sendTonResult.transactions).toHaveTransaction({
            from: deployer.address,
            to: stableSwap.address,
            success: true,
        });

        const { jettonWalletDai, jettonWalletUsdc, jettonWalletUsdt } = await setJettonWalletAddresses(
            blockchain,
            deployer,
            stableSwap,
            jettonMasterDai,
            jettonMasterUsdc,
            jettonMasterUsdt,
        );

        stableSwapJettonWalletDai = jettonWalletDai;
        stableSwapJettonWalletUsdc = jettonWalletUsdc;
        stableSwapJettonWalletUsdt = jettonWalletUsdt;
    });

    async function addThreeTokenLiquidity() {
        const LIQUIDITY_AMOUNT = {
            dai: toEther(1000n),
            usdc: toMicro(1500n),
            usdt: toMicro(2000n),
        };

        const tokenBalances: IntBalances = {
            $$type: 'IntBalances',
            token1: LIQUIDITY_AMOUNT.dai,
            token2: LIQUIDITY_AMOUNT.usdc,
            token3: LIQUIDITY_AMOUNT.usdt,
        };

        // Add DAI liquidity
        await addLiquidity(
            blockchain,
            jettonMasterDai,
            user1JettonWalletDai,
            user1,
            stableSwap,
            0n,
            LIQUIDITY_AMOUNT.dai,
            tokenBalances,
        );

        // Add USDT liquidity
        await addLiquidity(
            blockchain,
            jettonMasterUsdc,
            user1JettonWalletUsdc,
            user1,
            stableSwap,
            1n,
            LIQUIDITY_AMOUNT.usdc,
            tokenBalances,
        );

        // Add USDC liquidity
        await addLiquidity(
            blockchain,
            jettonMasterUsdt,
            user1JettonWalletUsdt,
            user1,
            stableSwap,
            2n,
            LIQUIDITY_AMOUNT.usdt,
            tokenBalances,
        );

        return LIQUIDITY_AMOUNT;
    }

    it('add liquidity', async () => {
        const liquidityAdded = await addThreeTokenLiquidity();

        assertWalletBalance(stableSwapJettonWalletUsdt, liquidityAdded.usdt);
        assertWalletBalance(stableSwapJettonWalletUsdc, liquidityAdded.usdc);
        assertWalletBalance(stableSwapJettonWalletDai, liquidityAdded.dai);

        assertWalletBalance(user1JettonWalletUsdt, TOKEN_TO_MINT_MICRO - liquidityAdded.usdt);
        assertWalletBalance(user1JettonWalletUsdc, TOKEN_TO_MINT_MICRO - liquidityAdded.usdc);

        assertLPTokenWalletBalance(blockchain, user1, stableSwap, toEther(4500n), toEther(4497n));

        const liquidityAdded2 = await addThreeTokenLiquidity();

        assertWalletBalance(stableSwapJettonWalletUsdt, liquidityAdded.usdt + liquidityAdded2.usdt);
        assertWalletBalance(stableSwapJettonWalletUsdc, liquidityAdded.usdc + liquidityAdded2.usdc);
        assertWalletBalance(stableSwapJettonWalletDai, liquidityAdded.dai + liquidityAdded2.dai);

        assertLPTokenWalletBalance(blockchain, user1, stableSwap, toEther(9000n), toEther(8995n));
    });

    it('remove liquidity all tokens', async () => {
        await addThreeTokenLiquidity();

        const removeLiquidityRequestObject: RemoveLiquidityRequest = {
            $$type: 'RemoveLiquidityRequest',
            type: 0n,
            minTokenOutBalances: {
                $$type: 'IntBalances',
                token1: toEther(2n),
                token2: toMicro(3n),
                token3: toMicro(4n),
            },
            singleTokenOutIndex: 0n,
            minTokenOutAmount: 0n,
        };

        const user1DaiBalance = await getBalance(user1JettonWalletDai);
        const user1UsdcBalance = await getBalance(user1JettonWalletUsdc);
        const user1UsdtBalance = await getBalance(user1JettonWalletUsdt);

        const walletAddress = await stableSwap.getChildAddress(user1.address);
        const wallet = blockchain.openContract(await StableSwapPoolWallet.fromAddress(walletAddress));
        const lpTokenBurnAmount = toEther(1000n);

        const removeLiquidityCalcResult: RemoveLiquidityResult = await stableSwap.getCalcRemoveLiquidity(
            removeLiquidityRequestObject.minTokenOutBalances.token1,
            removeLiquidityRequestObject.minTokenOutBalances.token2,
            removeLiquidityRequestObject.minTokenOutBalances.token3,
            lpTokenBurnAmount,
        );

        const removeLiquidityResult = await wallet.send(
            user1.getSender(),
            {
                value: REMOVE_LIQUIDITY_GAS,
            },
            {
                $$type: 'TokenBurn',
                query_id: 1n,
                amount: lpTokenBurnAmount,
                response_destination: user1.address,
                custom_payload: beginCell()
                    .store(storeRemoveLiquidityRequest(removeLiquidityRequestObject))
                    .endCell()
                    .asSlice(),
            },
        );

        printTransactionFees(removeLiquidityResult.transactions);
        expect(removeLiquidityResult.transactions).toHaveTransaction({
            from: wallet.address,
            to: stableSwap.address,
            success: true,
        });

        // assertWalletBalance(blockchain, stableSwap.address, jettonMasterUsdt, toMicro(0n));
        // assertWalletBalance(blockchain, stableSwap.address, jettonMasterUsdc, toMicro(0n));

        assertWalletBalance(user1JettonWalletDai, user1DaiBalance + removeLiquidityCalcResult.amounts.token1);
        assertWalletBalance(user1JettonWalletUsdc, user1UsdcBalance + removeLiquidityCalcResult.amounts.token2);
        assertWalletBalance(user1JettonWalletUsdt, user1UsdtBalance + removeLiquidityCalcResult.amounts.token3);
    });

    it('single token remove liquidity', async () => {
        const liquidityAdded = await addThreeTokenLiquidity();

        const walletAddress = await stableSwap.getChildAddress(user1.address);
        const wallet = blockchain.openContract(await StableSwapPoolWallet.fromAddress(walletAddress));
        const lpTokenBurnAmount = toEther(1000n);

        const userUSDTBalanceBeforeSwap = await getBalance(user1JettonWalletUsdt);
        const tokenOutIndex = USDT_INDEX;

        const calcWithdrawOneCoinResult = await stableSwap.getCalcWithdrawOneCoin(lpTokenBurnAmount, tokenOutIndex);

        const removeLiquidityResult = await wallet.send(
            user1.getSender(),
            {
                value: REMOVE_LIQUIDITY_GAS,
            },
            {
                $$type: 'TokenBurn',
                query_id: 1n,
                amount: lpTokenBurnAmount,
                response_destination: user1.address,
                custom_payload: beginCell()
                    .store(
                        storeRemoveLiquidityRequest({
                            $$type: 'RemoveLiquidityRequest',
                            type: 1n,
                            minTokenOutBalances: {
                                $$type: 'IntBalances',
                                token1: 0n,
                                token2: 0n,
                                token3: 0n,
                            },
                            singleTokenOutIndex: tokenOutIndex,
                            minTokenOutAmount: 0n,
                        }),
                    )
                    .endCell()
                    .asSlice(),
            },
        );

        printTransactionFees(removeLiquidityResult.transactions);
        expect(removeLiquidityResult.transactions).toHaveTransaction({
            from: wallet.address,
            to: stableSwap.address,
            success: true,
        });

        const userUSDTBalanceAfterSwap = await getBalance(user1JettonWalletUsdt);

        assertWalletBalance(
            stableSwapJettonWalletUsdt,
            liquidityAdded.usdt - (userUSDTBalanceAfterSwap - userUSDTBalanceBeforeSwap),
        );

        // No change in other balances
        assertWalletBalance(stableSwapJettonWalletUsdc, liquidityAdded.usdc);
        assertWalletBalance(stableSwapJettonWalletDai, liquidityAdded.dai);

        assertWalletBalance(user1JettonWalletUsdt, userUSDTBalanceBeforeSwap + calcWithdrawOneCoinResult.dy);
        assert(userUSDTBalanceAfterSwap - userUSDTBalanceBeforeSwap >= toMicro(1001n));
        assert(userUSDTBalanceAfterSwap - userUSDTBalanceBeforeSwap <= toMicro(1002n));
    });

    it('imbalance token remove liquidity', async () => {
        await addThreeTokenLiquidity();

        const walletAddress = await stableSwap.getChildAddress(user1.address);
        const wallet = blockchain.openContract(await StableSwapPoolWallet.fromAddress(walletAddress));
        const maxLpTokenBurnAmount = toEther(1000n);
        const userUsdtBalance = await getBalance(user1JettonWalletUsdt);
        const lpTokenBalance = await user1LPTokenWallet.getBalance();

        const tokenOutBalances: IntBalances = {
            $$type: 'IntBalances',
            token1: 0n,
            token2: toMicro(400n),
            token3: toMicro(400n),
        };

        const calcResult = await stableSwap.getCalcRemoveLiquidityImbalance(
            tokenOutBalances.token1,
            tokenOutBalances.token2,
            tokenOutBalances.token3,
            maxLpTokenBurnAmount,
        );

        const removeLiquidityResult = await wallet.send(
            user1.getSender(),
            {
                value: REMOVE_LIQUIDITY_GAS,
            },
            {
                $$type: 'TokenBurn',
                query_id: 1n,
                amount: maxLpTokenBurnAmount,
                response_destination: user1.address,
                custom_payload: beginCell()
                    .store(
                        storeRemoveLiquidityRequest({
                            $$type: 'RemoveLiquidityRequest',
                            type: 2n,
                            minTokenOutBalances: tokenOutBalances,
                            singleTokenOutIndex: 0n,
                            minTokenOutAmount: 0n,
                        }),
                    )
                    .endCell()
                    .asSlice(),
            },
        );

        printTransactionFees(removeLiquidityResult.transactions);
        expect(removeLiquidityResult.transactions).toHaveTransaction({
            from: wallet.address,
            to: stableSwap.address,
            success: true,
        });

        assertWalletBalance(user1JettonWalletUsdt, userUsdtBalance + tokenOutBalances.token3);
        assertLPTokenWalletExact(blockchain, user1, stableSwap, lpTokenBalance - calcResult.tokenBurned);

        assertWalletBalance(user1JettonWalletUsdt, userUsdtBalance + tokenOutBalances.token3);
    });

    it('swap tokens', async () => {
        await addThreeTokenLiquidity();

        const swapAmount = toMicro(100n);
        const swapResult = await swapTokens(
            user2,
            swapAmount,
            TOKEN_INDEX_USDC,
            TOKEN_INDEX_USDT,
            blockchain,
            stableSwap,
            user2JettonWalletUsdc,
            jettonMasterUsdc,
        );

        expect(swapResult.transactions).toHaveTransaction({
            from: stableSwapJettonWalletUsdt.address,
            to: user2JettonWalletUsdt.address,
            success: true,
        });

        assertWalletBalanceRange(
            user2JettonWalletUsdt,
            TOKEN_TO_MINT_MICRO + swapAmount + toMicro(1n),
            TOKEN_TO_MINT_MICRO + swapAmount,
        );
    });

    it('multiple swaps', async () => {
        await addThreeTokenLiquidity();

        let usdtBalance = await getBalance(user2JettonWalletUsdt);

        const swapAmount = toMicro(100n);
        const swapResult = await swapTokens(
            user2,
            swapAmount,
            TOKEN_INDEX_USDC,
            TOKEN_INDEX_USDT,
            blockchain,
            stableSwap,
            user2JettonWalletUsdc,
            jettonMasterUsdc,
        );

        expect(swapResult.transactions).toHaveTransaction({
            from: stableSwapJettonWalletUsdt.address,
            to: user2JettonWalletUsdt.address,
            success: true,
        });

        assertWalletBalanceRange(
            user2JettonWalletUsdt,
            usdtBalance + swapAmount + toMicro(1n),
            usdtBalance + swapAmount,
        );

        usdtBalance = await getBalance(user2JettonWalletUsdt);

        const swapResult1 = await swapTokens(
            user2,
            swapAmount,
            TOKEN_INDEX_USDC,
            TOKEN_INDEX_USDT,
            blockchain,
            stableSwap,
            user2JettonWalletUsdc,
            jettonMasterUsdc,
        );

        expect(swapResult1.transactions).toHaveTransaction({
            from: stableSwapJettonWalletUsdt.address,
            to: user2JettonWalletUsdt.address,
            success: true,
        });

        assertWalletBalanceRange(
            user2JettonWalletUsdt,
            usdtBalance + swapAmount + toMicro(1n),
            usdtBalance + swapAmount,
        );
    });

    it('calculate swap token', async () => {
        await addThreeTokenLiquidity();

        let usdtBalance = await getBalance(user2JettonWalletUsdt);

        const swapAmount = toMicro(100n);
        const swapTokenReq: SwapTokenRequest = {
            $$type: 'SwapTokenRequest',
            queryId: 0n,
            amount: swapAmount,
            tokenInIndex: TOKEN_INDEX_USDC,
            tokenOutIndex: TOKEN_INDEX_USDT,
            minTokenOutAmount: swapAmount,
        };

        const calcSwapResult = await stableSwap.getCalcSwapTokens(
            swapAmount,
            TOKEN_INDEX_USDC,
            TOKEN_INDEX_USDT,
            swapAmount,
        );

        const swapResult = await swapTokens(
            user2,
            swapAmount,
            TOKEN_INDEX_USDC,
            TOKEN_INDEX_USDT,
            blockchain,
            stableSwap,
            user2JettonWalletUsdc,
            jettonMasterUsdc,
            swapTokenReq,
        );

        expect(swapResult.transactions).toHaveTransaction({
            from: stableSwapJettonWalletUsdt.address,
            to: user2JettonWalletUsdt.address,
            success: true,
        });

        assertWalletBalance(user2JettonWalletUsdt, usdtBalance + calcSwapResult.dy);
    });
});

async function swapTokens(
    user: SandboxContract<TreasuryContract>,
    swapAmount: bigint,
    tokenInIndex: bigint,
    tokenOutIndex: bigint,
    blockchain: Blockchain,
    stableSwap: SandboxContract<StableSwapPool>,
    toTokenUserJettonWallet: SandboxContract<JettonDefaultWallet>,
    toTokenJettonMaster: SandboxContract<SampleJetton>,
    swapTokenRequestObject?: SwapTokenRequest,
) {
    if (!swapTokenRequestObject) {
        swapTokenRequestObject = {
            $$type: 'SwapTokenRequest',
            queryId: 0n,
            amount: swapAmount,
            tokenInIndex: tokenInIndex,
            tokenOutIndex: tokenOutIndex,
            minTokenOutAmount: swapAmount,
        };
    }

    const swapTokenRequest = storeOperationType({
        $$type: 'OperationType',
        type: 0n,
        payload: beginCell().store(storeSwapTokenRequest(swapTokenRequestObject)).endCell().asSlice(),
    });

    const result = await transferJetton(
        blockchain,
        toTokenJettonMaster,
        toTokenUserJettonWallet,
        user,
        swapAmount,
        stableSwap.address,
        beginCell().store(swapTokenRequest).endCell(),
        SWAP_GAS,
    );

    return result;
}

async function assertLPTokenWalletExact(
    blockchain: Blockchain,
    user: SandboxContract<TreasuryContract>,
    stableSwap: SandboxContract<StableSwapPool>,
    amount: bigint,
) {
    const walletAddress = await stableSwap.getChildAddress(user.address);
    const wallet = blockchain.openContract(await StableSwapPoolWallet.fromAddress(walletAddress));

    expect(await wallet.getBalance()).toEqual(amount);
}

async function assertLPTokenWalletBalance(
    blockchain: Blockchain,
    user: SandboxContract<TreasuryContract>,
    stableSwap: SandboxContract<StableSwapPool>,
    amountLte: bigint,
    amountGte: bigint,
) {
    const walletAddress = await stableSwap.getChildAddress(user.address);
    const wallet = blockchain.openContract(await StableSwapPoolWallet.fromAddress(walletAddress));

    expect(await wallet.getBalance()).toBeGreaterThanOrEqual(amountGte);
    expect(await wallet.getBalance()).toBeLessThanOrEqual(amountLte);
}

async function assertWalletBalance(userWallet: SandboxContract<JettonDefaultWallet>, amount: bigint) {
    const walletData = await userWallet.getGetWalletData();
    expect(walletData.balance).toEqual(amount);
}

async function assertWalletBalanceRange(
    userWallet: SandboxContract<JettonDefaultWallet>,
    amountLte: bigint,
    amountGte: bigint,
) {
    const walletData = await userWallet.getGetWalletData();
    expect(walletData.balance).toBeGreaterThanOrEqual(amountGte);
    expect(walletData.balance).toBeLessThanOrEqual(amountLte);
}

async function addLiquidity(
    blockchain: Blockchain,
    jettonMaster: SandboxContract<SampleJetton>,
    userJettonWallet: SandboxContract<JettonDefaultWallet>,
    user: SandboxContract<TreasuryContract>,
    stableSwap: SandboxContract<StableSwapPool>,
    tokenIndex: bigint,
    amount: bigint,
    tokenBalances: IntBalances,
) {
    assert(
        (amount == tokenBalances.token1 && tokenIndex == 0n) ||
            (amount == tokenBalances.token2 && tokenIndex == 1n) ||
            (amount == tokenBalances.token3 && tokenIndex == 2n),
        'Invalid token amount',
    );

    const addLiquidityRequest = storeOperationType({
        $$type: 'OperationType',
        type: 1n,
        payload: beginCell()
            .store(
                storeAddLiquidityRequest({
                    $$type: 'AddLiquidityRequest',
                    queryId: 0n,
                    tokenIndex: tokenIndex,
                    tokenBalances: tokenBalances,
                    minMintAmount: 0n,
                }),
            )
            .endCell()
            .asSlice(),
    });

    const liquidityAddedResult = await transferJetton(
        blockchain,
        jettonMaster,
        userJettonWallet,
        user,
        amount,
        stableSwap.address,
        beginCell().store(addLiquidityRequest).endCell(),
        ADD_LIQUIDITY_GAS,
    );

    const userPoolWalletAddress = await stableSwap.getChildAddress(user.address);

    expect(liquidityAddedResult.transactions).toHaveTransaction({
        from: stableSwap.address,
        to: userPoolWalletAddress,
        success: true,
    });
}

async function transferJetton(
    blockchain: Blockchain,
    jettonMaster: SandboxContract<SampleJetton>,
    jettonWallet: SandboxContract<JettonDefaultWallet>,
    user: SandboxContract<TreasuryContract>,
    amount: bigint,
    to: Address,
    forwardPayload: Cell,
    gas: bigint,
) {
    const transferResult = await jettonWallet.send(
        user.getSender(),
        {
            value: gas,
        },
        {
            $$type: 'TokenTransfer',
            query_id: 100n,
            amount: amount,
            destination: to,
            response_destination: user.address,
            custom_payload: Cell.EMPTY,
            forward_ton_amount: toNano('.15'),
            forward_payload: forwardPayload.asSlice(),
        },
    );

    printTransactionFees(transferResult.transactions);

    expect(transferResult.transactions).toHaveTransaction({
        from: (await getUserJettonWallet(blockchain, to, jettonMaster.address)).address,
        to: to,
        success: true,
    });

    return transferResult;
}
