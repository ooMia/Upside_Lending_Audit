// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

interface IPriceOracle {
    function getPrice(address token) external view returns (uint256);
    function setPrice(address token, uint256 price) external;
}

contract DreamAcademyLending {
    IPriceOracle public upsideOracle;
    IERC20 public usdc;

    uint256 public constant LTV_RATIO = 50; // LTV ratio at 50%
    uint256 public constant LIQUIDATION_THRESHOLD = 75; // Liquidation threshold at 75%
    uint256 public constant INTEREST_RATE_PER_BLOCK = 0.001 * 1e15; // 계산방법을 모르겠다... 대충 넣으니 되는데 왜 되는지 모르겠다.

    mapping(address => uint256) public totalDepositToken; // Total deposit for each token

    struct Account {
        uint256 ETHDepositAmount;
        uint256 USDCDepositAmount;
        uint256 ETHBorrowedAmount;
        uint256 USDCBorrowedAmount;
        uint256 lastBlockUpdate;
    }

    mapping(address => Account) public accounts;

    constructor(IPriceOracle _upsideOracle, address _usdc) {
        upsideOracle = _upsideOracle;
        usdc = IERC20(_usdc);
    }

    function initializeLendingProtocol(address _usdc) external payable {
        require(msg.value > 0, "Must send initial reserve");
        IERC20(_usdc).transferFrom(msg.sender, address(this), msg.value);
    }

    function deposit(address token, uint256 amount) external payable {
        _updateDebt(msg.sender);
        require(amount > 0, "Amount must be greater than 0");

        if (token == address(0)) {
            // ETH deposit
            require(msg.value >= amount, "Incorrect Ether amount sent");
            accounts[msg.sender].ETHDepositAmount += amount;
        } else {
            // USDC deposit
            require(IERC20(token) == usdc, "Invalid token");
            accounts[msg.sender].USDCDepositAmount += amount;
            IERC20(usdc).transferFrom(msg.sender, address(this), amount);
        }

        totalDepositToken[token] += amount;
    }

    function borrow(address token, uint256 amount) external {
        require(amount > 0, "Amount must be greater than 0");
        _updateDebt(msg.sender);

        require(totalDepositToken[token] >= amount, "Insufficient liquidity");

        uint256 userDepositValue = _calculateDepositValue(msg.sender);
        uint256 userBorrowValue = _calculateBorrowValue(msg.sender);
        uint256 borrowValue = upsideOracle.getPrice(token) * amount;

        require(
            userDepositValue >= (borrowValue + userBorrowValue) * 100 / LTV_RATIO, "Insufficient collateral to borrow"
        );

        if (token == address(0)) {
            accounts[msg.sender].ETHBorrowedAmount += amount;
            payable(msg.sender).transfer(amount);
        } else {
            require(IERC20(token) == usdc, "Invalid token");
            accounts[msg.sender].USDCBorrowedAmount += amount;
            IERC20(usdc).transfer(msg.sender, amount);
        }

        totalDepositToken[token] -= amount;
    }

    function repay(address token, uint256 amount) external {
        _updateDebt(msg.sender);
        require(amount > 0, "Amount must be greater than 0");

        if (token == address(0)) {
            require(accounts[msg.sender].ETHBorrowedAmount >= amount, "Repay amount exceeds borrowed");
            accounts[msg.sender].ETHBorrowedAmount -= amount;
        } else {
            require(IERC20(token) == usdc, "Invalid token");
            require(accounts[msg.sender].USDCBorrowedAmount >= amount, "Repay amount exceeds borrowed");
            accounts[msg.sender].USDCBorrowedAmount -= amount;
            IERC20(usdc).transferFrom(msg.sender, address(this), amount);
        }

        totalDepositToken[token] += amount;
    }

    function withdraw(address token, uint256 amount) external {
        require(amount > 0, "Amount must be greater than 0");
        _updateDebt(msg.sender);

        uint256 userDepositValue = _calculateDepositValue(msg.sender);
        uint256 userBorrowValue = _calculateBorrowValue(msg.sender);
        uint256 withdrawValue = upsideOracle.getPrice(token) * amount;

        require(
            (userDepositValue - withdrawValue) * LIQUIDATION_THRESHOLD / 100 >= userBorrowValue,
            "Insufficient collateral to withdraw"
        );

        if (token == address(0)) {
            require(accounts[msg.sender].ETHDepositAmount >= amount, "Insufficient ETH deposit");
            accounts[msg.sender].ETHDepositAmount -= amount;
            payable(msg.sender).transfer(amount);
        } else {
            require(IERC20(token) == usdc, "Invalid token");
            require(accounts[msg.sender].USDCDepositAmount >= amount, "Insufficient USDC deposit");
            accounts[msg.sender].USDCDepositAmount -= amount;
            IERC20(usdc).transfer(msg.sender, amount);
        }

        totalDepositToken[token] -= amount;
    }

    function liquidate(address borrower, address token, uint256 amount) external {
        require(amount > 0, "Amount must be greater than 0");
        _updateDebt(borrower);

        uint256 userBorrowValue = _calculateBorrowValue(borrower);
        uint256 userDepositValue = _calculateDepositValue(borrower);

        require(userBorrowValue * 100 / userDepositValue >= LIQUIDATION_THRESHOLD, "Loan is healthy");

        uint256 maxLiquidation = accounts[borrower].USDCBorrowedAmount / 4;
        require(amount <= maxLiquidation, "Exceeds max liquidation amount");

        uint256 collateralToSize = (amount * upsideOracle.getPrice(address(usdc))) / upsideOracle.getPrice(address(0));

        require(accounts[borrower].ETHDepositAmount >= collateralToSize, "Insufficient collateral to liquidate");

        accounts[borrower].USDCBorrowedAmount -= amount;
        accounts[borrower].ETHDepositAmount -= collateralToSize;

        IERC20(usdc).transferFrom(msg.sender, address(this), amount);
        payable(msg.sender).transfer(collateralToSize);
    }

    function _updateDebt(address user) private {
        uint256 blockGap = block.number - accounts[user].lastBlockUpdate;

        while (blockGap > 0) {
            accounts[user].ETHBorrowedAmount +=
                (accounts[user].ETHBorrowedAmount * INTEREST_RATE_PER_BLOCK * blockGap) / 1e18;
            accounts[user].USDCBorrowedAmount +=
                (accounts[user].USDCBorrowedAmount * INTEREST_RATE_PER_BLOCK * blockGap) / 1e18;
            blockGap--;
        }
        accounts[user].lastBlockUpdate = block.number;
    }

    function _calculateBorrowValue(address user) private view returns (uint256) {
        uint256 etherBorrowedValue = accounts[user].ETHBorrowedAmount * upsideOracle.getPrice(address(0)); // ETH
        uint256 usdcBorrowedValue = accounts[user].USDCBorrowedAmount * upsideOracle.getPrice(address(usdc)); // USDC
        return etherBorrowedValue + usdcBorrowedValue;
    }

    function _calculateDepositValue(address user) private view returns (uint256) {
        uint256 etherDepositValue = accounts[user].ETHDepositAmount * upsideOracle.getPrice(address(0)); // ETH
        uint256 usdcDepositValue = accounts[user].USDCDepositAmount * upsideOracle.getPrice(address(usdc)); // USDC
        return etherDepositValue + usdcDepositValue;
    }

    function getAccruedSupplyAmount(address user) external view returns (uint256) {
        // TODO: Implement this function
    }

    receive() external payable {}
}
