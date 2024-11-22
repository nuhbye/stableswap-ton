import { toNano, Cell, Address, OpenedContract } from '@ton/core';
import { NetworkProvider } from '@ton/blueprint';
import { SampleJetton } from '../wrappers/SampleJetton';

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
    await mintJettonTokens(provider, TEST_ADDRESS, 10000n);
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
