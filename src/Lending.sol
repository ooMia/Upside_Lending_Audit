// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Address} from "@openzeppelin/contracts/utils/Address.sol";

import {IPriceOracle} from "./DreamAcademyLending.sol";

import "forge-std/Test.sol";

abstract contract _Lending {
    using Address for address;

    enum Operation {
        DEPOSIT,
        WITHDRAW,
        BORROW,
        REPAY,
        LIQUIDATE
    }

    // 담보가 감소되는 연산 후에는 반드시 LTV < LT 조건이 만족되어야 한다.
    // LTV (Loan to Value) = (대출액 / 담보액) * 100
    // LT (Liquidation Threshold) = 75
    // 담보액 * LT >= 대출액 * 100을 만족한다면, 언제든 인출이 가능하다.
    // 담보액 * LT < 대출액 * 100 일 경우, 청산이 가능하다.
    // 1e18 accuracy given by test case `testBorrowWithInsufficientCollateralFails`
    uint256 internal constant LT = 75;
    uint256 internal constant OC_RATE = 50; // over collateralization rate

    address internal immutable _PAIR;
    IPriceOracle internal immutable _ORACLE;
    address internal constant _ETH = address(0);
    address internal immutable _THIS = address(this);

    constructor(IPriceOracle oracle, address pair) {
        _ORACLE = oracle;
        _PAIR = pair;
    }

    modifier identity(address user, Operation op) {
        // uint256 preUserBalanceValue = getTotalBalanceValueOf(msg.sender);
        // uint256 preThisBalanceValue = getTotalBalanceValueOf(_THIS);
        uint256 preOpLoan = getTotalBorrowedValue(user);
        uint256 preOpCollateral = getTotalCollateralValue(user);
        uint256 preLTV = getLTV(user);

        if (op == Operation.DEPOSIT) {
            // LTV < LT 조건 불필요
        } else if (op == Operation.WITHDRAW) {
            require(isLoanHealthy(user), "identity|WITHDRAW: Loan is unhealthy"); // pessimistic: if needed
        } else if (op == Operation.BORROW) {
            require(isLoanHealthy(user), "identity|BORROW: Loan is unhealthy"); // pessimistic: if needed
        } else if (op == Operation.REPAY) {
            // LTV < LT 조건 불필요
        } else if (op == Operation.LIQUIDATE) {
            // user: borrower
            require(!isLoanHealthy(user), "identity|LIQUIDATE: Loan is healthy");
        }
        _;
        // uint256 postUserBalance = getTotalBalanceValueOf(msg.sender);
        // uint256 postThisBalance = getTotalBalanceValueOf(_THIS);
        uint256 postOpLoan = getTotalBorrowedValue(user);
        uint256 postOpCollateral = getTotalCollateralValue(user);
        uint256 postLTV = getLTV(user);

        if (op == Operation.DEPOSIT) {
            // require(preUserBalanceValue > postUserBalance, "identity|DEPOSIT: Total value of user balance not decreased");
            // require(preThisBalanceValue < postThisBalance, "identity|DEPOSIT: Total value of contract balance not increased");
            console.log("block#%d | user%d | DEPOSIT", block.number, getUserNumber());
            consoleStatus(preLTV, postLTV, preOpLoan, postOpLoan, preOpCollateral, postOpCollateral);

            require(preOpLoan == postOpLoan, "identity|DEPOSIT: Loan changed");
            require(preOpCollateral < postOpCollateral, "identity|DEPOSIT: Collateral not increased");
            require(preLTV == 0 || preLTV > postLTV, "identity|DEPOSIT: LTV not decreased");
        } else if (op == Operation.WITHDRAW) {
            // require(preUserBalanceValue < postUserBalance, "identity|WITHDRAW: Total value of user balance not increased");
            // require(preThisBalanceValue > postThisBalance,"identity|WITHDRAW: Total value of contract balance not decreased");
            console.log("block#%d | user%d | WITHDRAW", block.number, getUserNumber());
            consoleStatus(preLTV, postLTV, preOpLoan, postOpLoan, preOpCollateral, postOpCollateral);

            require(preOpLoan == postOpLoan, "identity|WITHDRAW: Loan changed");
            require(preOpCollateral > postOpCollateral, "identity|WITHDRAW: Collateral not decreased");
            require(preLTV < postLTV || postOpLoan == 0, "identity|WITHDRAW: LTV not increased");
            require(isLoanHealthy(user), "identity|WITHDRAW: Loan become unhealthy"); // optimistic
        } else if (op == Operation.BORROW) {
            // require(preUserBalanceValue < postUserBalance, "identity|BORROW: Total value of user balance not increased");
            // require(preThisBalanceValue > postThisBalance, "identity|BORROW: Total value of contract balance not decreased");
            console.log("block#%d | user%d | BORROW", block.number, getUserNumber());
            consoleStatus(preLTV, postLTV, preOpLoan, postOpLoan, preOpCollateral, postOpCollateral);
            require(postOpLoan * 2 <= postOpCollateral, "identity|BORROW: Over collateralization rate not satisfied");
            require(postLTV <= OC_RATE * 1e18, "identity|BORROW: OC RATE not satisfied");
            require(preOpLoan < postOpLoan, "identity|BORROW: Loan not increased");
            require(preOpCollateral == postOpCollateral, "identity|WITHDRAW: Collateral changed");
            require(preLTV < postLTV, "identity|BORROW: LTV not increased");
            require(isLoanHealthy(user), "identity|BORROW: Loan become unhealthy"); // optimistic
        } else if (op == Operation.REPAY) {
            // LTV < LT 조건 불필요
            // require(preUserBalanceValue > postUserBalance, "identity|REPAY: Total value of user balance not decreased");
            // require(preThisBalanceValue < postThisBalance, "identity|REPAY: Total value of contract balance not increased");
            console.log("block#%d | user%d | REPAY", block.number, getUserNumber());
            consoleStatus(preLTV, postLTV, preOpLoan, postOpLoan, preOpCollateral, postOpCollateral);

            require(preOpLoan > postOpLoan, "identity|REPAY: Loan not decreased");
            require(preOpCollateral == postOpCollateral, "identity|REPAY: Collateral changed");
            require(preLTV == 0 || preLTV > postLTV, "identity|REPAY: LTV not decreased");
        } else if (op == Operation.LIQUIDATE) {
            // LTV < LT 조건 불필요
            // user: msg.sender, balanceType: value
            // require(preUserBalanceValue >= postUserBalance, "identity|LIQUIDATE: Total value of user balance increased");
            // require(preThisBalanceValue <= postThisBalance, "identity|LIQUIDATE: Total value of contract balance decreased");
            console.log("block#%d | user%d | LIQUIDATE", block.number, getUserNumber());
            consoleStatus(preLTV, postLTV, preOpLoan, postOpLoan, preOpCollateral, postOpCollateral);

            require(preOpLoan > postOpLoan, "identity|LIQUIDATE: Loan not decreased");
            require(preOpCollateral > postOpCollateral, "identity|LIQUIDATE: Collateral not decreased");
            require(preLTV > postLTV || preLTV == 0, "identity|LIQUIDATE: LTV not decreased");
        }
    }

    /// @dev ERC20 토큰과 이더리움의 잔고를 합산하여 반환하는 함수
    /// IERC20(_PAIR).balanceOf(user) + user.balance
    function getTotalBalanceOf(address user) internal view returns (uint256 res) {
        res = abi.decode(
            _PAIR.functionStaticCall(abi.encodeWithSelector(IERC20(_PAIR).balanceOf.selector, user)), (uint256)
        );
        res += user.balance;
    }

    function getTotalBalanceValueOf(address user) internal view returns (uint256 res) {
        res = getPrice(_PAIR)
            * abi.decode(
                _PAIR.functionStaticCall(abi.encodeWithSelector(IERC20(_PAIR).balanceOf.selector, user)), (uint256)
            );
        res += getPrice(_ETH) * user.balance;
    }

    function getPrice(address token) internal view returns (uint256) {
        return abi.decode(
            address(_ORACLE).functionStaticCall(abi.encodeWithSelector(_ORACLE.getPrice.selector, token)), (uint256)
        );
    }

    function getLTV(address user) internal view returns (uint256 res) {
        return getLTV1e18(user);
    }

    function getLTV1e18(address user) internal view returns (uint256 res) {
        res = getTotalCollateralValue(user);
        return res > 0 ? (getTotalBorrowedValue(user) * 100 * 1e18) / res : 0;
    }

    function getLTV1e27(address user) internal view returns (uint256 res) {
        res = getTotalCollateralValue(user);
        return res > 0 ? (getTotalBorrowedValue(user) * 100 * 1e27) / res : 0;
    }

    // 유저의 대출액을 조회하는 함수
    // 1. deposit 함수를 통해 예금을 예치한 경우, 대출액은 변하지 않아야 한다.
    // 2. withdraw 함수를 통해 예금을 인출한 경우, 대출액은 변하지 않아야 한다.
    // 3. borrow 함수를 통해 대출을 받은 경우, 대출액이 증가되어야 한다.
    // 4. repay 함수를 통해 대출을 상환한 경우, 대출액이 감소되어야 한다.
    // 5. liquidate 함수를 통해 청산된 경우, 대출액이 감소되어야 한다.
    function getTotalBorrowedValue(address user) internal view virtual returns (uint256);

    // 유저의 담보액을 조회하는 함수
    // 1. deposit 함수를 통해 예금을 예치한 경우, 담보액이 증가되어야 한다.
    // 2. withdraw 함수를 통해 예금을 인출한 경우, 담보액이 감소되어야 한다.
    // 3. borrow 함수를 통해 대출을 받은 경우, 담보액이 감소되어야 한다.
    // 4. repay 함수를 통해 대출을 상환한 경우, 담보액이 증가되어야 한다.
    // 5. liquidate 함수를 통해 청산된 경우, 담보액이 감소되어야 한다.
    function getTotalCollateralValue(address user) internal view virtual returns (uint256);

    /// @dev LTV < LT 조건을 만족하는지 확인하는 함수
    function isLoanHealthy(address user) internal view returns (bool) {
        return getLTV(user) < LT * 1e18;
    }

    function transferFrom(address from, address to, uint256 amount) internal {
        transferFrom(from, to, amount, _PAIR);
    }

    function transferFrom(address from, address to, uint256 amount, address pair) internal {
        require(amount > 0, "transferFrom: amount is zero");
        pair.functionCall(abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, amount));
    }

    function transfer(address to, uint256 amount) internal {
        transfer(to, amount, _PAIR);
    }

    function transfer(address to, uint256 amount, address pair) internal {
        require(amount > 0, "transfer: amount is zero");
        pair.functionCall(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
    }

    function transferETH(address to, uint256 amount) internal {
        require(amount > 0, "transferETH: amount is zero");
        // to.functionCallWithValue("", amount);
        (bool res,) = to.call{value: amount}("");
        require(res, "transferETH: transfer failed");
    }

    function getUserNumber() internal view returns (uint256) {
        return uint256(uint160(msg.sender) - uint160(address(0x1336)));
    }

    function consoleStatus(
        uint256 preLTV,
        uint256 postLTV,
        uint256 preOpLoan,
        uint256 postOpLoan,
        uint256 preOpCollateral,
        uint256 postOpCollateral
    ) internal view {
        uint256 decimal = 1e18;
        uint256 decimal2 = 1e36;
        console.log("\tpreLTV: %d %d", preLTV / decimal, preLTV % decimal);
        console.log("\tpostLTV: %d %d", postLTV / decimal, postLTV % decimal);
        console.log("\tpreOpLoan: %d %d", preOpLoan / decimal2, preOpLoan % decimal2);
        console.log("\tpostOpLoan: %d %d", postOpLoan / decimal2, postOpLoan % decimal2);
        console.log("\tpreOpCollateral: %d %d", preOpCollateral / decimal2, preOpCollateral % decimal2);
        console.log("\tpostOpCollateral: %d %d", postOpCollateral / decimal2, postOpCollateral % decimal2);
    }
}
