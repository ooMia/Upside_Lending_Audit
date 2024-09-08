// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface IPriceOracle {
    function getPrice(address token) external view returns (uint256);
    function setPrice(address token, uint256 price) external;
}

contract DreamAcademyLending {
    IPriceOracle dreamOracle;
    address usdc;
    uint256 lastBlock;

    uint256 totalDeposit;
    address[] depositList;

    uint256 totalDebt;
    address[] debtList;

    mapping(address => mapping(address => uint256)) balances;
    mapping(address => mapping(address => uint256)) debts;

    uint256 constant DayInterestsRate = 1000000138819500300;
    uint256 constant BlockInterestsRate = 1001000000000000000;

    constructor(IPriceOracle _oracle, address token) {
        dreamOracle = _oracle;
        usdc = token;

        lastBlock = block.number;
    }

    function initializeLendingProtocol(address token) external payable {
        require(token != address(0), "Invalid token address");
        require(msg.value > 0, "Must send Ether to initialize");

        if (token != address(0)) {
            ERC20(token).transferFrom(msg.sender, address(this), msg.value);
            balances[address(this)][token] += msg.value;
        }
    }

    function deposit(address token, uint256 amount) external payable {
        if (token == address(0)) {
            require(msg.value == amount, "Ether amount mismatch");
            balances[msg.sender][token] += amount;
        } else {
            require(msg.value == 0, "No Ether should be sent");
            ERC20(token).transferFrom(msg.sender, address(this), amount);
            balances[msg.sender][token] += amount;

            totalDeposit += amount;
            depositList.push(msg.sender);
        }
    }

    function borrow(address token, uint256 amount) external {
        require(token != address(0), "Invalid token address");
        require(amount > 0, "Amount must be greater than zero");
        _updateLoanValue(token); // 이자율 반영
        debtList.push(msg.sender); // 빌린자 리스트 반영

        uint256 collateralValue = _calculateCollateralValue(msg.sender);
        uint256 requiredCollateralValue = (amount + debts[msg.sender][token]) * dreamOracle.getPrice(token) * 2;
        require(collateralValue >= requiredCollateralValue, "Insufficient collateral");

        require(ERC20(token).balanceOf(address(this)) >= amount, "Insufficient liquidity");
        ERC20(token).transfer(msg.sender, amount);
        debts[msg.sender][token] += amount;

        totalDebt += amount;
    }

    function repay(address token, uint256 amount) external {
        require(token != address(0), "Invalid token address");
        require(amount > 0, "Amount must be greater than zero");
        _updateLoanValue(token); // 이자율 반영

        uint256 debt = debts[msg.sender][token];
        require(debt > 0, "No outstanding debt");
        require(amount <= debt, "Repayment amount exceeds debt");

        ERC20(token).transferFrom(msg.sender, address(this), amount);
        debts[msg.sender][token] -= amount;

        totalDebt -= amount;
    }

    function liquidate(address borrower, address token, uint256 amount) external {
        require(borrower != address(0), "Invalid borrower address");
        require(token != address(0), "Invalid token address");
        require(amount > 0, "Repayment amount must be greater than zero");
        _updateLoanValue(token); // 이자율 반영

        uint256 debt = debts[borrower][token];
        require(debt > 0, "No outstanding debt");

        uint256 collateralValue = _calculateCollateralValue(borrower);
        uint256 debtValue = debt * dreamOracle.getPrice(token);
        uint256 liquidationThreshold = (collateralValue * 3) / 4;

        require(debtValue > liquidationThreshold, "Loan is not eligible for liquidation");
        require(amount <= (debt / 4), "Repayment amount exceeds debt");

        ERC20(token).transferFrom(msg.sender, address(this), amount);
        debts[borrower][token] -= amount;

        totalDebt -= amount;
    }

    function withdraw(address token, uint256 amount) external {
        require(amount > 0, "Amount must be greater than zero");
        if (token == address(0)) {
            require(balances[msg.sender][token] >= amount, "Insufficient balance");
            _updateLoanValue(usdc); // 이자율 반영

            uint256 WithdrawablecollateralValue =
                _calculateCollateralValue(msg.sender) - debts[msg.sender][usdc] * dreamOracle.getPrice(usdc) * 4 / 3;
            uint256 WithdrawValue = amount * dreamOracle.getPrice(token);

            require(WithdrawValue <= WithdrawablecollateralValue, "Collateral would be insufficient after withdrawal");

            balances[msg.sender][token] -= amount;
            payable(msg.sender).transfer(amount);
        } else {
            require(balances[msg.sender][token] >= amount, "Insufficient balance");
            _updateLoanValue(token); // 이자율 반영

            uint256 WithdrawablecollateralValue =
                _calculateCollateralValue(msg.sender) - debts[msg.sender][usdc] * dreamOracle.getPrice(usdc) * 4 / 3;
            uint256 WithdrawValue = amount * dreamOracle.getPrice(token);

            require(WithdrawValue <= WithdrawablecollateralValue, "Collateral would be insufficient after withdrawal");

            balances[msg.sender][token] -= amount;
            ERC20(token).transfer(msg.sender, amount);

            totalDeposit -= amount;
        }
    }

    function getAccruedSupplyAmount(address token) public returns (uint256) {
        uint256 interests = _updateLoanValue(token);
        for (uint256 i = 0; i < depositList.length; i++) {
            balances[depositList[i]][token] += interests * balances[depositList[i]][token] / totalDeposit;
        }
        return balances[msg.sender][token];
    }

    function _updateLoanValue(address token) internal returns (uint256 interests) {
        uint256 blocksElapsed = block.number - lastBlock;
        uint256 day = blocksElapsed % 7200;
        uint256 blocks = blocksElapsed / 7200;
        uint256 beforeDebt = totalDebt;

        for (uint256 i = 0; i < day; i++) {
            totalDebt *= DayInterestsRate;
            totalDebt /= 1 ether;
        }
        for (uint256 i = 0; i < blocks; i++) {
            totalDebt *= BlockInterestsRate;
            totalDebt /= 1 ether;
        }

        interests = totalDebt - beforeDebt;
        lastBlock = block.number;

        for (uint256 i = 0; i < debtList.length; i++) {
            debts[debtList[i]][token] += interests * debts[debtList[i]][token] / totalDebt;
        }
    }

    // 현재 자산의 법정통화 가치
    function _calculateCollateralValue(address user) internal view returns (uint256) {
        uint256 etherValue = balances[user][address(0)] * dreamOracle.getPrice(address(0));
        uint256 usdcValue = balances[user][usdc] * dreamOracle.getPrice(usdc);

        return etherValue + usdcValue;
    }
}
