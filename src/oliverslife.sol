// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface IPriceOracle {
    function getPrice(address token) external view returns (uint256);
}

contract DreamAcademyLending {
    IPriceOracle public oracle;
    ERC20 public usdc;

    uint256 public APY = 3; // I don't know WTF.
    bool public initiator = false;

    mapping(address => uint256) public userETH;
    mapping(address => uint256) public userUSDC;
    mapping(address => uint256) public borrowedUSDC;
    mapping(address => uint256) public recentBlock;

    constructor(IPriceOracle _oracle, address _usdc) {
        oracle = _oracle;
        usdc = ERC20(_usdc);
    }

    function availableAmount(address _addr, uint256 ratio) internal returns (uint256) {
        uint256 ethP = oracle.getPrice(address(0));
        uint256 usdP = oracle.getPrice(address(usdc));
        return (userETH[_addr] * ethP + userUSDC[_addr] * usdP) * ratio / 100 - borrowedUSDC[_addr] * usdP;
    }

    function charge(address _addr) internal {
        if (recentBlock[_addr] == 0) {
            recentBlock[_addr] = block.number;
        } else {
            uint256 interestPerBlock = borrowedUSDC[_addr] * APY * 100 / 365 / 24 / 60 / 5; // 1 block 당 12sec 고정으로 계산하세요.
            uint256 chargeAmount = (block.number - recentBlock[_addr]) * interestPerBlock;
            borrowedUSDC[_addr] += chargeAmount;
            recentBlock[_addr] = block.number;
        }
    }

    function initializeLendingProtocol(address token) external payable {
        require(!initiator && msg.value == 1, "Give Me 1 CUSDC");
        initiator = true;
        usdc.transferFrom(msg.sender, address(this), msg.value);
    }

    function deposit(address token, uint256 amount) external payable {
        if (token == address(0)) {
            require(msg.value == amount, "Insufficient Ether");
            userETH[msg.sender] += msg.value;
        } else {
            require(usdc.balanceOf(msg.sender) >= amount, "Insufficient USDC");
            userUSDC[msg.sender] += amount;
            usdc.transferFrom(msg.sender, address(this), amount);
        }
    }

    function borrow(address token, uint256 amount) external {
        charge(msg.sender);

        require(token == address(usdc), "Not Implemented");
        require(availableAmount(msg.sender, 50) >= amount * oracle.getPrice(address(token)), "Not Enough Collateral");

        borrowedUSDC[msg.sender] += amount;
        usdc.transfer(msg.sender, amount);
    }

    function repay(address token, uint256 amount) external {
        charge(msg.sender);

        require(token == address(usdc), "Not Implemented");
        uint256 borrowed = borrowedUSDC[msg.sender];
        require(usdc.balanceOf(msg.sender) >= amount, "Not Enough USDC");

        if (borrowed >= amount) {
            borrowedUSDC[msg.sender] -= amount;
        } else {
            borrowedUSDC[msg.sender] = 0;
            userUSDC[msg.sender] += amount - borrowed;
        }
    }

    function withdraw(address token, uint256 amount) external {
        charge(msg.sender);

        uint256 available = availableAmount(msg.sender, 100);
        uint256 withdrawalValue = amount * oracle.getPrice(address(token));
        uint256 borrowedValue = borrowedUSDC[msg.sender] * oracle.getPrice(address(usdc));
        require(available >= withdrawalValue, "Insufficient Balance");

        uint256 collateralAfterWithdraw = available + borrowedValue - withdrawalValue;
        require(collateralAfterWithdraw * 75 / 100 >= borrowedValue, "Not Enough Collateral");

        if (token == address(0)) {
            require(userETH[msg.sender] >= amount, "Not Enough ETH");
            payable(msg.sender).transfer(amount);
        } else {
            require(userUSDC[msg.sender] >= amount, "Not Enough USDC");
            usdc.transfer(msg.sender, amount);
        }
    }

    function getAccruedSupplyAmount(address token) external returns (uint256) {}

    function liquidate(address borrower, address token, uint256 amount) external {
        charge(borrower);

        uint256 maxLiquidationAmount =
            borrowedUSDC[borrower] >= 100 ether ? borrowedUSDC[borrower] / 4 : borrowedUSDC[borrower];
        require(
            amount <= maxLiquidationAmount, "can liquidate the whole position when the borrowed amount is less than 100"
        );
        require(amount <= borrowedUSDC[borrower], "Too Much USDC");

        require(token == address(usdc), "Not Implemented");
        uint256 ethCollateral = userETH[borrower] * oracle.getPrice(address(0));
        uint256 borrowed = borrowedUSDC[borrower] * oracle.getPrice(token);

        require(ethCollateral * 75 / 100 < borrowed, "Suficient Collateral");
        borrowedUSDC[borrower] -= amount;
        uint256 liquidatedEthAmount = userETH[borrower] * amount * oracle.getPrice(token) / ethCollateral;
        userETH[borrower] -= liquidatedEthAmount;

        usdc.transferFrom(msg.sender, address(this), amount);
        payable(msg.sender).transfer(liquidatedEthAmount);
    }
}
