import { toNano, Cell, Address, OpenedContract } from '@ton/core';
import { StableSwapPool } from '../wrappers/StableSwapPool';
import { NetworkProvider } from '@ton/blueprint';
import { SampleJetton } from '../wrappers/SampleJetton';
import { JettonDefaultWallet } from '../wrappers/JettonDefaultWallet';

function toMicro(amount: bigint) {
    return amount * 1000000n;
}

function toEther(amount: bigint) {
    return amount * 1000000000000000000n;
}

const SS_DAI_MASTER_WALLET = Address.parse('EQBsqCSTOsmwIBoKsaLNnlUuACOUXiXdyNi6bSZyDLwFBn-Y');
const SS_USDC_MASTER_WALLET = Address.parse('EQBU2Nv3O8v2iErjKw9nczox6QR1XkGDORw6Z8FwrOoWwpJ0');
const SS_USDT_MASTER_WALLET = Address.parse('EQD0TafFMo5vDphXmtFZjFamiXNSSL50IF9VaNmo3HCPaxSl');

const STABLE_SWAP_ADDRESS = Address.parse('EQDVEQwxMe918773p40Hie026ci_egz2osbDrgozs33Hm9Px');

const TEST_ADDRESS = Address.parse('0QC1VdK9NlxVMHUlAoUiOc3Vum31h-hqCfMh51grbWU3tAki');

export async function run(provider: NetworkProvider) {
    await deployAllJettonMaster(provider);
    await delay(5000);
    await deployStableSwap(provider);
    await delay(5000);
    await updateJettonWallets(provider);

    // run methods on `stableSwap`
    // await sendTokens(provider);
    // const stableSwap = await provider.open(await StableSwapPool.fromAddress(STABLE_SWAP_ADDRESS));
    // console.log(await stableSwap.getCalcSwapTokens(toMicro(1n), 1n, 2n, 0n));
    // console.log(await stableSwap.getCalcLiquidityAdded(toEther(100n), toMicro(100n), toMicro(100n)));
    // console.log(await stableSwap.getCalcRemoveLiquidity(toEther(1n), toMicro(1n), toMicro(1n), toEther(10n)));
    // console.log(await stableSwap.getCalcRemoveLiquidityImbalance(toEther(10n), toMicro(1n), toMicro(1n), toEther(10n)));
    // console.log(await stableSwap.getCalcWithdrawOneCoin(toEther(10n), 1n));
}

async function deployAllJettonMaster(provider: NetworkProvider) {
    const jettonMasterDAI = await deployJettonMaster(provider, 'DAI', toEther(1000000n));
    const jettonMasterUSDC = await deployJettonMaster(provider, 'USDC', toMicro(1000000n));
    const jettonMasterUSDT = await deployJettonMaster(provider, 'USDT', toMicro(1000000n));
}

async function deployStableSwap(provider: NetworkProvider) {
    console.log('Deploying StableSwap...');
    const stableSwap = await provider.open(
        await StableSwapPool.fromInit(provider.sender().address!!, 'USDTUSDCDAI', 85n, 4000000n, 5000000000n),
    );
    await stableSwap.send(
        provider.sender(),
        {
            value: toNano('0.05'),
        },
        {
            $$type: 'Deploy',
            queryId: 0n,
        },
    );

    await provider.waitForDeploy(stableSwap.address);
}

async function sendTokens(provider: NetworkProvider) {
    const stableSwap = await provider.open(StableSwapPool.fromAddress(STABLE_SWAP_ADDRESS));

    await stableSwap.send(
        provider.sender(),
        {
            value: toNano('2'),
        },
        null,
    );
}

async function updateJettonWallets(provider: NetworkProvider) {
    console.log('Updating Jetton Wallets...');
    const stableSwap = await provider.open(StableSwapPool.fromAddress(STABLE_SWAP_ADDRESS));

    const poolJettonWalletDAI = await JettonDefaultWallet.fromInit(SS_DAI_MASTER_WALLET, stableSwap.address);
    const poolJettonWalletUSDC = await JettonDefaultWallet.fromInit(SS_USDC_MASTER_WALLET, stableSwap.address);
    const poolJettonWalletUSDT = await JettonDefaultWallet.fromInit(SS_USDT_MASTER_WALLET, stableSwap.address);

    await stableSwap.send(
        provider.sender(),
        {
            value: toNano('0.05'),
        },
        {
            $$type: 'SetJettonWalletAddresses',
            tokenJettonWallets: {
                $$type: 'TokenJettonWallets',
                token1: poolJettonWalletDAI.address,
                token2: poolJettonWalletUSDC.address,
                token3: poolJettonWalletUSDT.address,
            },
        },
    );
}

async function deployJettonMaster(provider: NetworkProvider, name: string, amount: bigint) {
    console.log('Deploying Jetton Master...');
    const jettonMaster = await provider.open(
        await SampleJetton.fromInit(provider.sender().address!!, Cell.EMPTY, 1000n * amount, name),
    );

    await jettonMaster.send(
        provider.sender(),
        {
            value: toNano('.5'),
        },
        {
            $$type: 'Deploy',
            queryId: 0n,
        },
    );

    await provider.waitForDeploy(jettonMaster.address);

    return jettonMaster;
}

function delay(ms: number) {
    return new Promise((resolve) => setTimeout(resolve, ms));
}

async function mintJettonTokens(provider: NetworkProvider, user: Address, amount: bigint) {
    const jettonMasterDAI = await provider.open(SampleJetton.fromAddress(SS_DAI_MASTER_WALLET));
    const jettonMasterUSDC = await provider.open(SampleJetton.fromAddress(SS_USDC_MASTER_WALLET));
    const jettonMasterUSDT = await provider.open(SampleJetton.fromAddress(SS_USDT_MASTER_WALLET));

    await mintTokens(provider, jettonMasterDAI, user, toEther(amount));
    await delay(15000);
    await mintTokens(provider, jettonMasterUSDC, user, toMicro(amount));
    await delay(15000);
    await mintTokens(provider, jettonMasterUSDT, user, toMicro(amount));
}

async function mintTokens(
    provider: NetworkProvider,
    jettonMaster: OpenedContract<SampleJetton>,
    receiver: Address,
    amount: bigint,
) {
    await jettonMaster.send(
        provider.sender(),
        {
            value: toNano('0.05'),
        },
        {
            $$type: 'Mint',
            amount: amount,
            receiver: receiver,
        },
    );
}
