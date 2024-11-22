import "@stdlib/deploy";
import "@stdlib/ownable";


// TODO: Handle multiple request sent at once
@interface("org.ton.jetton.wallet")
contract StableSwapPoolWallet {
    parent: Address;
    owner: Address;         // every child holds the balance of a different owner
    balance: Int as coins;  // this is the balance of lp tokens the owner

    // Store token balances for the incoming request
    tokenBalances: IntBalances;

    queryId: Int as uint32;
    minMintAmount: Int as coins;
    init(parent: Address, owner: Address) {
        self.parent = parent;
        self.owner = owner;
        self.balance = 0;

        self.queryId = 0;
        self.minMintAmount = 0;
        self.tokenBalances = IntBalances{token1: 0, token2: 0, token3: 0};
    }

    // sent by users to initiate a new transfer
    receive(msg: Transfer) {
        require(sender() == self.owner, "Access denied");
        require(self.balance >= msg.amount, "Insufficient balance");
        
        self.balance = self.balance - msg.amount;
        let init: StateInit = initOf StableSwapPoolWallet(self.parent, msg.to);

        send(SendParameters{
            to: contractAddress(init),
            body: InternalAddTokens{amount: msg.amount, origin: self.owner}.toCell(),
            value: ton("0.03"),             // pay for the deployment and leave some TON in the child for storage
            mode: SendIgnoreErrors,
            code: init.code,                // deploy the child if needed
            data: init.data
        });

        self.reply("transferred".asComment());
    }

    // internal message sent by one child to another to update balances
    receive(msg: InternalAddTokens) {
        if (msg.origin == self.parent) { // tokens originate in a mint
            require(sender() == self.parent, "Parent only");
        } else { // tokens originate in a Transfer
            require(sender() == contractAddress(initOf StableSwapPoolWallet(self.parent, msg.origin)), "Sibling only");
        }

        self.balance = self.balance + msg.amount;

        send(SendParameters{
            to: self.owner,
            value: 0,
            mode: SendRemainingValue + SendIgnoreErrors,
            body: "Liquidity Received".asComment()
        });
    }

    receive(msg: TokenBurn) {
        dump("Received token burn");
        require(sender() == self.owner, "Invalid sender");  // Check sender

        self.balance = self.balance - msg.amount; // Update balance
        require(self.balance >= 0, "Invalid balance");

        // Burn tokens
        send(SendParameters{  
            to: self.parent,
            value: 0,
            mode: SendRemainingValue,
            body: TokenBurnNotification{
                query_id: msg.query_id,
                amount: msg.amount,
                sender: self.owner,
                response_destination: msg.response_destination,
                custom_payload: msg.custom_payload
            }.toCell()
        });
    }

    bounced(src: bounced<InternalAddTokens>) {
        self.balance = self.balance + src.amount;
    }

    bounced(src: bounced<TokenBurnNotification>) {
        self.balance = self.balance + src.amount;
    }

    get fun balance(): Int {
        return self.balance;
    }

    get fun tokenBalances(): IntBalances {
        return self.tokenBalances;
    }

    receive(addLiquidityRequest: AddLiquidityRequestInternal) {
        dump("Received add liquidity request");
        require(sender() == self.parent, "Access denied");

        self.onLiquidityAddedMessageReceived(addLiquidityRequest);
    }

    fun onLiquidityAddedMessageReceived(msg: AddLiquidityRequestInternal) {
        if (self.queryId == 0) {
            self.queryId = msg.queryId;
            self.minMintAmount = msg.minMintAmount;
        }

        // Keep track of all balances sent by user
        // In case the user sends multiple requests at once, we can refund this back to user
        self.tokenBalances = setIntBalance(self.tokenBalances, msg.tokenIndex, 
                                            getIntBalance(msg.tokenBalances, msg.tokenIndex));

        if (self.tokenBalances.token1 >= msg.tokenBalances.token1 && 
            self.tokenBalances.token2 >= msg.tokenBalances.token2 && 
            self.tokenBalances.token3 >= msg.tokenBalances.token3) {
            
            send(SendParameters{
                to: self.parent,
                value: 0,
                mode: SendRemainingValue,
                body: LiquidityAdded{
                    query_id: self.queryId,
                    sender: msg.sender,
                    tokenBalances: IntBalances{
                        token1: msg.tokenBalances.token1,
                        token2: msg.tokenBalances.token2,
                        token3: msg.tokenBalances.token3
                    },
                    minMintAmount: self.minMintAmount
                }.toCell()
            });

            self.queryId = 0;
            self.minMintAmount = 0;
            
            // Update pending balances after forwarding the request
            self.tokenBalances = IntBalances{
                token1: self.tokenBalances.token1 - msg.tokenBalances.token1,
                token2: self.tokenBalances.token2 - msg.tokenBalances.token2,
                token3: self.tokenBalances.token3 - msg.tokenBalances.token3
            };

        } else {
            send(SendParameters{
                to: msg.sender,
                value: 0,
                mode: SendRemainingValue,
                body: "Liquidity Recieved for Token".asComment()
            });
        }
    }

    // TODO add function to remove failed add liquidity attempts
 }
 