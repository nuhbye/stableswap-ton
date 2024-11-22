// TODO
// 1. If burn happens and then swap happens from some other user and then remove liquidity happens, 
//    will this impact working? - Have handled it right now by doing supply remove post token transferred

import "@stdlib/deploy";
import "@stdlib/ownable";

import "./messages.tact";
import "./stable_swap_pool_wallet.tact";
import "./stable_swap_jetton_master.tact";

import "./utils.tact";


@interface("org.ton.jetton.master")
contract StableSwapPool with Deployable, Ownable, JettonMaster {
    // === Pool Constants ===
    const nCoins: Int = 3;

    const FeeDenominator: Int = 10000000000;
    const Precision: Int = 1000000000000000000;  // The precision to convert to
    const PrecisionMul: IntBalances = IntBalances{token1: 1, token2: 1000000000000, token3: 1000000000000};    
    const Rates: IntBalances = IntBalances{
        token1: 1000000000000000000, 
        token2: 1000000000000000000000000000000, 
        token3: 1000000000000000000000000000000
    };

    const MaxAdminFee: Int = 10 * 1000000000;
    const MaxFee: Int = 5 * 1000000000;
    const MaxA: Int = 1000000;
    const MaxAChange: Int = 10;

    const AdminActionsDelay: Int = 3 * 86400;
    const MinRampTime: Int = 86400;

    const JettonTransferFee: Int = ton("0.05");

    // Owner of the contract, user for admin operations check
    symbol: String;
    totalSupply: Int;
    mintable: Bool;
    owner: Address;

    // Pool balances
    tokenBalances: IntBalances;

    // jettons wallet address, to process jetton transfers
    tokenJettonWallets: TokenJettonWallets?;

    initialA: Int as uint256;
    futureA: Int as uint256;
    initialATime: Int as uint256;
    futureATime: Int as uint256;

    // Pool fees
    fee: Int as coins;
    adminFee: Int as coins;

    init(owner: Address, symbol: String, A: Int, fee: Int, adminFee: Int) {
        self.owner = owner;
        self.totalSupply = 0;
        self.mintable = true;

        self.fee = fee;
        self.adminFee = adminFee;

        self.initialA = A;
        self.futureA = A;
        self.initialATime = 0;
        self.futureATime = 0;

        self.tokenBalances = IntBalances{token1: 0, token2: 0, token3: 0};

        self.symbol = symbol;
    }

    receive() {}

    // Admin function to set Jetton Wallets
    receive(setJettonWalletAddresses: SetJettonWalletAddresses) {
        dump("Received set jetton wallet addresses");
        self.requireOwner();
        self.tokenJettonWallets = setJettonWalletAddresses.tokenJettonWallets;
    }

    receive(tokenExcesses: TokenExcesses) {
        dump("Token excesses received");
        // No op, just accept the message
    }

    // Jetton transfer notification handler for add liquidity and swap token
    receive(tokenTransferNotification: TokenTransferNotification) {
        dump("Received token transfer notification");
        
        // Load the op code and ignore
        tokenTransferNotification.forward_payload.loadUint(32);

        let type: Int = tokenTransferNotification.forward_payload.loadUint(4);

        if (type == 0) {
            // Swap token
            let swapToken: SwapTokenRequest = SwapTokenRequest.fromSlice(tokenTransferNotification.forward_payload); 
            self.swapToken(swapToken, tokenTransferNotification.sender);
        } else if (type == 1) {
            // Add liquidity
            let addLiquidity: AddLiquidityRequest = AddLiquidityRequest.fromSlice(tokenTransferNotification.forward_payload); 

            require(getIntBalance(addLiquidity.tokenBalances, addLiquidity.tokenIndex) == tokenTransferNotification.amount, "Invalid token amount");
            self.handleAddLiquidityRequest(addLiquidity, tokenTransferNotification.sender);
        } else {
            require(false, "Invalid request type");
        }
    }

    // Redirect to user pool wallet for accumilating token transfers for adding liquidity
    fun handleAddLiquidityRequest(addLiquidityRequest: AddLiquidityRequest, msgSender: Address) {
        dump("Adding liquidity");
        
        let init: StateInit = initOf StableSwapPoolWallet(myAddress(), msgSender);
        send(SendParameters{
            to: self.childAddress(msgSender),
            value: 0,
            mode: SendRemainingValue,
            body: AddLiquidityRequestInternal{
                queryId: addLiquidityRequest.queryId,
                sender: msgSender,
                tokenIndex: addLiquidityRequest.tokenIndex,
                tokenBalances: addLiquidityRequest.tokenBalances,
                minMintAmount: addLiquidityRequest.minMintAmount
            }.toCell(),
            code: init.code,                // deploy the child if needed
            data: init.data
        });
    }

    // Handler for add liquidity request from user pool wallet, post accumulating all token transfers
    receive(liquidityAdded: LiquidityAdded) {
        require(sender() == self.childAddress(liquidityAdded.sender), "Invalid sender");
        
        dump("Received liquidity added");

        let result: CalcLiquidityAddedResult = self.calcLiquidityAdded(liquidityAdded.tokenBalances.token1, 
                                                                       liquidityAdded.tokenBalances.token2, 
                                                                       liquidityAdded.tokenBalances.token3);

        require(result.lpMintAmount >= liquidityAdded.minMintAmount, "Mint amount is less than min mint amount");
    
        // Emit liquidity added event
        emit(LiquidityAddedEvent{
                sender: liquidityAdded.sender,
                amounts: liquidityAdded.tokenBalances,
                fees: result.fees,
                invariant: result.invariant,
                tokenSupply: self.totalSupply
            }.toCell());

        // Mint lp tokens on liquidity added
        self.mint(result.lpMintAmount, liquidityAdded.sender, SendRemainingValue, 0);
    }

    // Calulate token values on add liquidity 
    get fun calcLiquidityAdded(tokenAmount1: Int, tokenAmount2: Int, tokenAmount3: Int): CalcLiquidityAddedResult {
        let addedTokenBalances: IntBalances = IntBalances{
            token1: tokenAmount1, 
            token2: tokenAmount2, 
            token3: tokenAmount3
        };

        let fees: IntBalances = IntBalances{token1: 0, token2: 0, token3: 0};

        let _fee: Int = self.fee * self.nCoins / (4 * (self.nCoins - 1));
        let _adminFee: Int = self.adminFee;

        let amp: Int = self.getA();

        let D0: Int = 0;

        let oldBalances: IntBalances = IntBalances{
            token1: self.tokenBalances.token1, 
            token2: self.tokenBalances.token2, 
            token3: self.tokenBalances.token3
        };

        if (self.totalSupply > 0) {
            D0 = self.getDMem(oldBalances, amp);
        }

        let newBalances: IntBalances = IntBalances{
            token1: oldBalances.token1 + addedTokenBalances.token1,
            token2: oldBalances.token2 + addedTokenBalances.token2,
            token3: oldBalances.token3 + addedTokenBalances.token3
        };

        let D1: Int = self.getDMem(newBalances, amp);

        require(D1 > D0, "D1 is not greater than D0");
        let D2: Int = D1;

        if (self.totalSupply > 0) {
            // Only account for fees if we are not the first to deposit
            let i: Int = 0;
            repeat(self.nCoins) {
                let idealBalance: Int = D1 * getIntBalance(oldBalances, i) / D0;
                let difference: Int = 0;

                if (idealBalance > getIntBalance(newBalances, i)) {
                    difference = idealBalance - getIntBalance(newBalances, i);
                } else {
                    difference = getIntBalance(newBalances, i) - idealBalance;
                }

                fees = setIntBalance(fees, i, _fee * difference / self.FeeDenominator);
                self.tokenBalances = setIntBalance(self.tokenBalances, i, 
                    getIntBalance(newBalances, i) - ((getIntBalance(fees, i) * _adminFee / self.FeeDenominator)));
                newBalances = setIntBalance(newBalances, i, getIntBalance(newBalances, i) - getIntBalance(fees, i));
                
                i = i + 1;
            }

            D2 = self.getDMem(newBalances, amp);
        } else {
            self.tokenBalances = newBalances;
        }

        // Calculate mint amount
        let mintAmount: Int = 0;
        if (self.totalSupply == 0) {
            mintAmount = D1;
        } else {
            mintAmount = self.totalSupply * (D2 - D0) / D0;
        }

        return CalcLiquidityAddedResult{
            newBalances: newBalances,
            lpMintAmount: mintAmount,
            fees: fees,
            invariant: D1
        };
    }

    // Handler for swap token request
    fun swapToken(swapTokenRequest: SwapTokenRequest, msgSender: Address) {
        dump("Swapping token");

        require((swapTokenRequest.tokenInIndex == 0 && sender() == self.tokenJettonWallets!!.token1) ||
                (swapTokenRequest.tokenInIndex == 1 && sender() == self.tokenJettonWallets!!.token2) ||
                (swapTokenRequest.tokenInIndex == 2 && sender() == self.tokenJettonWallets!!.token3), "Invalid request");

        let result: SwapTokenCalculateResult = self.calcSwapTokens(swapTokenRequest.amount, swapTokenRequest.tokenInIndex, 
                                                                  swapTokenRequest.tokenOutIndex, swapTokenRequest.minTokenOutAmount);

        // Update token balances
        self.tokenBalances = setIntBalance(self.tokenBalances, swapTokenRequest.tokenInIndex, 
                                                getIntBalance(result.oldBalances, swapTokenRequest.tokenInIndex) + result.dx);        
        // When rounding errors happen, we undercharge admin fee in favor of LP
        self.tokenBalances = setIntBalance(self.tokenBalances, swapTokenRequest.tokenOutIndex, 
                                                getIntBalance(result.oldBalances, swapTokenRequest.tokenOutIndex) - result.dy - result.dyAdminFee);

        emit(SwapTokenEvent{
            sender: msgSender,
            soldTokenIndex: swapTokenRequest.tokenInIndex,
            tokensSold: result.dx,
            boughtTokenIndex: swapTokenRequest.tokenOutIndex,
            tokensBought: result.dy
        }.toCell());

        self.sendJettons(swapTokenRequest.tokenOutIndex, 65, result.dy, msgSender, SendRemainingValue, null, 0);
    }

    // Calcuate tokens swapped
    get fun calcSwapTokens(dx: Int, tokenInIndex: Int, tokenOutIndex: Int, minTokenOutAmount: Int): SwapTokenCalculateResult {
        let rates: IntBalances = IntBalances{
            token1: self.Rates.token1, 
            token2: self.Rates.token2, 
            token3: self.Rates.token3
        };

        let oldBalances: IntBalances = IntBalances{
            token1: self.tokenBalances.token1, 
            token2: self.tokenBalances.token2, 
            token3: self.tokenBalances.token3
        };

        let xp: IntBalances = self.getXpMem(oldBalances);

        let x: Int = getIntBalance(xp, tokenInIndex) + dx * getIntBalance(rates, tokenInIndex) / self.Precision;
        let y: Int = self.getY(tokenInIndex, tokenOutIndex, x, xp);
        let dy: Int = getIntBalance(xp, tokenOutIndex) - y - 1; // -1 just in case there were some rounding errors
        let dyFee: Int = dy * self.fee / self.FeeDenominator;

        // Convert all to real units
        dy = (dy - dyFee) * self.Precision / getIntBalance(rates, tokenOutIndex);
        require(dy >= minTokenOutAmount, "Exchange resulted in fewer coins than expected");

        let dyAdminFee: Int = dyFee * self.adminFee / self.FeeDenominator;
        dyAdminFee = dyAdminFee * self.Precision / getIntBalance(rates, tokenOutIndex);

        return SwapTokenCalculateResult{
            dx: dx,
            dy: dy,
            dyAdminFee: dyAdminFee,
            fee: dyFee,
            oldBalances: oldBalances
        };
    }

    // Burn notification handler for remove liqudity
    receive(tokenBurnNotification: TokenBurnNotification) {
        dump("Received token burn notification");
        require(sender() == self.childAddress(tokenBurnNotification.sender), "Invalid sender");

        let removeLiquidity: RemoveLiquidityRequest = RemoveLiquidityRequest.fromSlice(tokenBurnNotification.custom_payload);

        if (removeLiquidity.type == 0) {
            self.removeLiquidity(removeLiquidity, tokenBurnNotification.sender, tokenBurnNotification.amount);
        } else if (removeLiquidity.type == 1) {
            self.removeLiquidityOneCoin(removeLiquidity, tokenBurnNotification.sender, tokenBurnNotification.amount);
        } else if (removeLiquidity.type == 2) {
            self.removeLiquidityImbalance(removeLiquidity, tokenBurnNotification.sender, tokenBurnNotification.amount);
        } else {
            require(false, "Invalid request type");
        }
    }

    // Handler for remove liquidity balanced
    fun removeLiquidity(removeLiquidityRequest: RemoveLiquidityRequest, sender: Address, burnedLpTokens: Int) {
        dump("Removing liquidity");

        let result: RemoveLiquidityResult = self.calcRemoveLiquidity(removeLiquidityRequest.minTokenOutBalances.token1, 
                                                                      removeLiquidityRequest.minTokenOutBalances.token2, 
                                                                      removeLiquidityRequest.minTokenOutBalances.token3, 
                                                                      burnedLpTokens);

        let i: Int = 0;
        repeat(self.nCoins - 1) {
            self.sendJettons(i, 64, getIntBalance(result.amounts, i), sender, 0, null, self.JettonTransferFee);

            i = i + 1;
        }

        // Send excess gas with last transfer
        self.sendJettons(2, 64, getIntBalance(result.amounts, i), sender, 0, null, context().value - ((self.nCoins - 1) * self.JettonTransferFee + ton("0.02")));

        // Not doing in Burn, as the internal balances and supply should be updated together to void race condition
        self.totalSupply = self.totalSupply - burnedLpTokens;

        emit(RemoveLiquidityEvent{
            sender: sender,
            amounts: result.amounts,
            fees: result.fees,
            tokenSupply: self.totalSupply
        }.toCell());
    }

    // Calculate tokens value for balanced token removal
    get fun calcRemoveLiquidity(tokenAmount1: Int, tokenAmount2: Int, tokenAmount3: Int, burnedLpTokens: Int): RemoveLiquidityResult {
        let minTokenOutBalances: IntBalances = IntBalances{
            token1: tokenAmount1, 
            token2: tokenAmount2, 
            token3: tokenAmount3
        };
        let amounts: IntBalances = IntBalances{token1: 0, token2: 0, token3: 0};
        // There is no fees right now on remove liquidity, but keeping it open for future use
        let fees: IntBalances = IntBalances{token1: 0, token2: 0, token3: 0};

        let i: Int = 0;
        repeat(self.nCoins) {
            let value: Int = getIntBalance(self.tokenBalances, i) * burnedLpTokens / self.totalSupply;
            require(value >= getIntBalance(minTokenOutBalances, i), "Withdrawal resulted in fewer coins than expected");

            self.tokenBalances = setIntBalance(self.tokenBalances, i, getIntBalance(self.tokenBalances, i) - value);
            amounts = setIntBalance(amounts, i, value);

            i = i + 1;
        }

        return RemoveLiquidityResult{
            amounts: amounts,
            fees: fees
        };
    }

    // Handler for removing one coin liquidity
    fun removeLiquidityOneCoin(removeLiquidityRequest: RemoveLiquidityRequest, sender: Address, burnedLpTokens: Int) {
        dump("Removing liquidity one coin");

        let tokenOutIndex: Int = removeLiquidityRequest.singleTokenOutIndex;

        let dy: Int = 0;
        let removeTokenOneCoinResult: RemoveTokenOneCoinResult = self.calcWithdrawOneCoin(burnedLpTokens, tokenOutIndex);

        require(removeTokenOneCoinResult.dy >= removeLiquidityRequest.minTokenOutAmount, 
                "Exchange resulted in fewer coins than expected");

        let totalFees: Int = removeTokenOneCoinResult.dyFee * self.adminFee / self.FeeDenominator;
        self.tokenBalances = setIntBalance(self.tokenBalances, tokenOutIndex, 
                getIntBalance(self.tokenBalances, tokenOutIndex) - (removeTokenOneCoinResult.dy + totalFees));

        self.totalSupply = self.totalSupply - burnedLpTokens;
        
        // Emit liquidity removed
        emit(RemoveLiquidityOneCoinEvent{
            sender: sender,
            amount: removeTokenOneCoinResult.dy,
            tokenSupply: self.totalSupply
        }.toCell());

        // Transfer jetton back to user
        self.sendJettons(tokenOutIndex, 64, removeTokenOneCoinResult.dy, sender, SendRemainingValue, null, 0);
    }

    // Calculate one coin jetton removal to be transfered back to user for given lp tokens
    get fun calcWithdrawOneCoin(burnedLpTokens: Int, tokenOutIndex: Int): RemoveTokenOneCoinResult {
        let amp: Int = self.getA();
        let fee: Int = self.fee * self.nCoins / (4 * (self.nCoins - 1));
        let precisions: IntBalances = self.PrecisionMul;

        let xp: IntBalances = self.getXp();

        let D0: Int = self.getD(xp, amp);
        let D1: Int = D0 - burnedLpTokens * D0 / self.totalSupply;
        let xpReduced: IntBalances = xp;

        let newY: Int = self.getYD(amp, tokenOutIndex, xp, D1);

        let dy0: Int = (getIntBalance(xp, tokenOutIndex) - newY) / getIntBalance(precisions, tokenOutIndex);
        
        let j: Int = 0;

        repeat(self.nCoins) {
            let dxExpected: Int = 0;
            
            if (tokenOutIndex == j) {
                dxExpected = getIntBalance(xp, j) * D1 / D0  - newY;
            } else {
                dxExpected = getIntBalance(xp, j) - getIntBalance(xp, j) * D1 / D0;
            }

            xpReduced = setIntBalance(xpReduced, j, getIntBalance(xpReduced, j) - fee * dxExpected / self.FeeDenominator);

            j = j + 1;
        }

        let dy: Int = getIntBalance(xpReduced, tokenOutIndex) - self.getYD(amp, tokenOutIndex, xpReduced, D1);

        // Withdraw less to account for rounding errors
        dy = (dy - 1) / getIntBalance(precisions, tokenOutIndex); 

        return RemoveTokenOneCoinResult{
            dy: dy,
            dyFee: dy0 - dy
        };
    }

    // Handler for removing liquidity in imbalance manner
    fun removeLiquidityImbalance(removeLiquidityRequest: RemoveLiquidityRequest, sender: Address, maxBurnAmount: Int) {
        require(self.totalSupply != 0, "Zero total supply");

        let amounts: IntBalances = removeLiquidityRequest.minTokenOutBalances;

        let result: CalcRemoveLiquidityImbalanceResult = self.calcRemoveLiquidityImbalance(
                        amounts.token1, amounts.token2, amounts.token3, maxBurnAmount);

        require(result.tokenBurned <= maxBurnAmount, "Too much slippage");

        // The extra liquidity user transferred will be minted back to the user
        self.totalSupply = self.totalSupply - maxBurnAmount;

        let i: Int = 0;
        let j: Int = 0;
        repeat(self.nCoins) {
            let coinAmount: Int = getIntBalance(amounts, i);
            if (coinAmount != 0) {
                self.sendJettons(i, 64, coinAmount, sender, 0, null, self.JettonTransferFee);
                j += 1;
            }

            i = i + 1;
        }

        // Emit liquidity removed event
        emit(RemoveLiquidityImbalanceEvent{
            sender: sender, 
            amounts: amounts, 
            fees: result.fees, 
            invariant: result.invariant, 
            tokenSupply: self.totalSupply,
            tokenBurned: result.tokenBurned
        }.toCell());

        // Transfer back user extra lp tokens
        if (maxBurnAmount - result.tokenBurned >= 0) {
            self.mint(maxBurnAmount - result.tokenBurned, sender, 0, context().value - (j * self.JettonTransferFee + ton("0.02")));
        }
    }

    // Calculate imbalanced jettons to be transfered back to user and lp tokens burned
    get fun calcRemoveLiquidityImbalance(amountToken1: Int, amountToken2: Int, amountToken3: Int, maxBurnAmount: Int): CalcRemoveLiquidityImbalanceResult { 
        let amounts: IntBalances = IntBalances{
            token1: amountToken1, 
            token2: amountToken2, 
            token3: amountToken3
        };

        let fee: Int = self.fee * self.nCoins / (4 * (self.nCoins - 1));
        let adminFee: Int = self.adminFee;
        let amp: Int = self.getA();

        let oldBalances: IntBalances = IntBalances{
            token1: self.tokenBalances.token1, 
            token2: self.tokenBalances.token2, 
            token3: self.tokenBalances.token3
        };
        
        let newBalances: IntBalances = IntBalances{
            token1: oldBalances.token1, 
            token2: oldBalances.token2, 
            token3: oldBalances.token3
        };

        let D0: Int = self.getDMem(oldBalances, amp);

        let i: Int = 0;
        repeat(self.nCoins) {
            newBalances = setIntBalance(newBalances, i, getIntBalance(newBalances, i) - getIntBalance(amounts, i));

            i = i + 1;
        }

        let D1: Int = self.getDMem(newBalances, amp);
        let fees: IntBalances = IntBalances{token1: 0, token2: 0, token3: 0};

        i = 0;
        repeat(self.nCoins) {
            let idealBalance: Int = D1 * getIntBalance(oldBalances, i) / D0;
            let difference: Int = 0;
            if (idealBalance > getIntBalance(newBalances, i)) {
                difference = idealBalance - getIntBalance(newBalances, i);
            } else {
                difference = getIntBalance(newBalances, i) - idealBalance;
            }

            fees = setIntBalance(fees, i, fee * difference / self.FeeDenominator);
            self.tokenBalances = setIntBalance(self.tokenBalances, i, getIntBalance(newBalances, i) - (getIntBalance(fees, i) * adminFee / self.FeeDenominator));
            newBalances = setIntBalance(newBalances, i, getIntBalance(newBalances, i) - getIntBalance(fees, i));

            i = i + 1;
        }

        let D2: Int = self.getDMem(newBalances, amp);
        let tokenBurnAmount: Int = (D0 - D2) * self.totalSupply / D0;
        require(tokenBurnAmount != 0 , "Zero tokens burned");
        // In case of rounding errors - make it unfavorable for the "attacker"
        tokenBurnAmount = tokenBurnAmount + 1;

        return CalcRemoveLiquidityImbalanceResult{
            fees: fees,
            invariant: D1,
            tokenBurned: tokenBurnAmount
        };
    }
        
    // Tranfer jettons back to user on swap and remove liquidity
    fun sendJettons(tokenIndex: Int, query_id: Int, jetton_amount: Int, 
                    destination: Address, mode: Int, payload: Cell?, value: Int) {

        let jettonWalletAddress: Address? = null;
        if (tokenIndex == 0) {
            jettonWalletAddress = self.tokenJettonWallets!!.token1;
        } else if (tokenIndex == 1) {
            jettonWalletAddress = self.tokenJettonWallets!!.token2;
        } else if (tokenIndex == 2) {
            jettonWalletAddress = self.tokenJettonWallets!!.token3;
        } else {
            require(false, "Invalid jettons to transfer");
        }

        let forwardPayload: Cell? = null;
        if (payload == null) {
            forwardPayload = beginCell().storeUint(0, 1).endCell();
        } else {
            forwardPayload = beginCell().storeUint(1, 1).storeRef(payload!!).endCell();
        }

        send(SendParameters{
            to: jettonWalletAddress!!,
            value: value,
            bounce: false,
            mode: mode,
            body: TokenTransfer {
                query_id: query_id,
                amount: jetton_amount,
                destination: destination,
                response_destination: myAddress(),
                custom_payload: beginCell().storeUint(0, 1).endCell(),
                forward_ton_amount: 1,
                forward_payload: (forwardPayload!!).asSlice()
            }.toCell()
        });
    }

    receive(stopRampA: StopRampA) {
        self.requireOwner();

        let A: Int = self.getA();
        let timeNow: Int = now();

        self.initialA = A;
        self.futureA = A;
        self.initialATime = timeNow;
        self.futureATime = timeNow;

        emit(StopRampAEvent{
            A: A,
            t: timeNow
        }.toCell());
    }

    receive(rampA: RampA) {
        self.requireOwner();
        
        let futureA: Int = rampA.futureA;
        let futureTime: Int = rampA.futureTime;

        let timeNow: Int = now();

        require(timeNow >= self.initialATime + self.MinRampTime, "Ramp has already started");
        require(futureTime >= timeNow + self.MinRampTime, "Future time is before current time");

        let initialA: Int = self.getA();

        require(futureA > 0 && futureA < self.MaxA, "Invalid future A");
        require((futureA >= initialA) && (futureA <= initialA * self.MaxAChange) ||
                (futureA < initialA) && (futureA * self.MaxAChange >= initialA), "Invalid future A");
            
        self.initialA = initialA;
        self.futureA = futureA;
        self.initialATime = timeNow;
        self.futureATime = futureTime;

        emit(RampAEvent{
            oldA: initialA,
            newA: futureA,
            initialTime: timeNow,
            futureTime: futureTime
        }.toCell());
    }

    get fun getVirtualPrice(): Int {
        let D: Int = self.getD(self.getXp(), self.getA());

        return D * self.Precision / self.totalSupply;
    }

    // =============== Implementation from CurveFi ===============
    fun getD(xp: IntBalances, amp: Int): Int {
        let S: Int = 0;

        let i: Int = 0;
        repeat(self.nCoins) {
            S = S + getIntBalance(xp, i);

            i = i + 1;
        }

        if (S == 0) {
            return 0;
        }

        let Dprev: Int = 0;
        let D: Int = S;
        let Ann: Int = amp * self.nCoins;

        i = 0;
        do {
            let DP: Int = D;

            let j: Int = 0;
            repeat(self.nCoins) {
                DP = DP * D / (getIntBalance(xp, j) * self.nCoins);
                j = j + 1;
            }

            Dprev = D;

            D = (Ann * S + DP * self.nCoins) * D / ((Ann - 1) * D + (self.nCoins + 1) * DP);

            i = i + 1;
        } until (i > 255 || (D > Dprev && D - Dprev <= 1) || (D <= Dprev && Dprev - D <= 1));

        return D;
    }

    fun getDMem(tokenBalances: IntBalances, amp: Int): Int {
        return self.getD(self.getXpMem(tokenBalances), amp);
    }

    fun getXpMem(tokenBalances: IntBalances): IntBalances {
        let result: IntBalances = IntBalances{
            token1: self.Rates.token1, 
            token2: self.Rates.token2, 
            token3: self.Rates.token3
        };

        let i: Int = 0;
        repeat(self.nCoins) {
            result = setIntBalance(result, i, (getIntBalance(result, i) * getIntBalance(tokenBalances, i)) / self.Precision);

            i = i + 1;
        }

        return result;
    }
    
    get fun getA(): Int {
        let t1: Int = self.futureATime;
        let A1: Int = self.futureA;

        let timeNow: Int = now();
        if (timeNow < t1) {
            let A0: Int = self.initialA;
            let t0: Int = self.initialATime;

            if (A1 > A0) {
                return A0 + (A1 - A0) * (timeNow - t0) / (t1 - t0);
            } else {
                return A0 - (A0 - A1) * (timeNow - t0) / (t1 - t0);
            }
        } else {
            return A1;
        }
    }

    fun getY(i: Int, j: Int, x: Int, xp: IntBalances): Int {
        require(i != j, "Token index same");
        require(j >= 0 && j < self.nCoins && i >= 0 && i < self.nCoins, "Invalid token index");
        let amp: Int = self.getA();
        let D: Int = self.getD(xp, amp);
        let c: Int = D;
        let S_: Int = 0;
        let Ann: Int = amp * self.nCoins;

        let _x: Int = 0;
        let it: Int = 0;
        repeat(self.nCoins) {
            let flag: Bool = false;

            if (it == i) {
                _x = x;
            } else if (it != j) {
                _x = getIntBalance(xp, it);
            } else {
                flag = true;
            }

            if (!flag) {
                S_ = S_ + _x;
                c = c * D / (_x * self.nCoins);
            }

            it = it + 1;
        }

        c = c * D / (Ann * self.nCoins);
        let b: Int = S_ + D / Ann; // - D
        let yPrev: Int = 0;
        let y: Int = D;

        it = 0;
        do {
            yPrev = y;
            y = (y * y + c) / (2 * y + b - D);

            it = it + 1;
        } until (it > 255 || (y > yPrev && y - yPrev <= 1) || (y <= yPrev && yPrev - y <= 1));

        return y;
    }

    // get_y_d implementation from curve.fi
    fun getYD(amp: Int, i: Int, xp: IntBalances, D: Int): Int {
        require(i >= 0, "Token index below zero");
        require(i < self.nCoins, "Token index above max index");

        let c: Int = D;
        let S: Int = 0;
        let Ann: Int = amp * self.nCoins;
        let x: Int = 0;

        let j: Int = 0;
        repeat(self.nCoins) {
            if (j != i) {
                x = getIntBalance(xp, j);
                S += x;
                c = c * D / (x * self.nCoins);
            }

            j = j + 1;
        }

        c = c * D / (Ann * self.nCoins);
        let b: Int = S + D / Ann;
        let yPrev: Int = 0;
        let y: Int = D;

        j = 0;

        do {
            yPrev = y;
            y = (y * y + c) / (2 * y + b - D);

            j = j + 1;
        } until (j > 255 || (y > yPrev && y - yPrev <= 1) || (y <= yPrev && yPrev - y <= 1));

        return y;
    }

    fun getXp(): IntBalances {
        let result: IntBalances = IntBalances{
            token1: self.Rates.token1, 
            token2: self.Rates.token2, 
            token3: self.Rates.token3
        };

        let i: Int = 0;
        repeat(self.nCoins) {
            result = setIntBalance(result, i, getIntBalance(result, i) * getIntBalance(self.tokenBalances, i) / self.Precision);

            i = i + 1;
        }

        return result;
    }

    // TODO: Add function for transferring failed Jettons, function will receive request from user pool wallet
    // and transfer tokens back to user which are not added to liquidity
}
