
fun getIntBalance(intBalances: IntBalances, index: Int): Int {
    if (index == 0) {
        return intBalances.token1;
    } else if (index == 1) {
        return intBalances.token2;
    } else if (index == 2) {
        return intBalances.token3;
    } else {
        require(false, "Invalid token index");
        return 0;
    }
}

fun setIntBalance(intBalances: IntBalances, index: Int, amount: Int): IntBalances {
    let newIntBalances: IntBalances = IntBalances{
        token1: intBalances.token1,
        token2: intBalances.token2,
        token3: intBalances.token3
    };

    if (index == 0) {
        newIntBalances.token1 = amount;
    } else if (index == 1) {
        newIntBalances.token2 = amount;
    } else if (index == 2) {
        newIntBalances.token3 = amount;
    } else {
        require(false, "Invalid token index");
    }

    return newIntBalances;
}