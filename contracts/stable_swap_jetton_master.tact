import "@stdlib/ownable";
import "@stdlib/deploy";
import "./messages.tact";


trait JettonMaster with Ownable {
    symbol: String;
    totalSupply: Int;
    mintable: Bool;
    owner: Address;

    fun mint(amount: Int, to: Address, sendMode: Int, gasValue: Int) {
        let init: StateInit = initOf StableSwapPoolWallet(myAddress(), to);
        send(SendParameters{
            to: contractAddress(init),
            body: InternalAddTokens{amount: amount, origin: myAddress()}.toCell(),
            value: gasValue,
            mode: sendMode,
            code: init.code,                // deploy the child if needed
            data: init.data
        });

        self.totalSupply = self.totalSupply + amount;
    }

    bounced(src: bounced<InternalAddTokens>) {
        self.totalSupply = self.totalSupply - src.amount;
    }

    get fun metadata(): Metadata {
        return Metadata{symbol: self.symbol, totalSupply: self.totalSupply};
    }

    get fun childAddress(owner: Address): Address {
        return contractAddress(initOf StableSwapPoolWallet(myAddress(), owner));
    }
}
