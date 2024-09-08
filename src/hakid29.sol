// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

// Loan To Value = 50%
// Liqiodation Threshold = 75%

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "forge-std/Test.sol";

interface IPriceOracle {
    function getPrice(address token) external view returns (uint256);
}

contract UpsideAcademyLending {
    struct User {
        uint256 etherDeposit;
        uint256 usdcDeposit;
        uint256 usdcBorrow;
        uint256 lastUpdate;
        uint256 updatedTotalDebt;
    }

    User[] Users;
    uint256 userCount;
    IPriceOracle public priceOracle;
    address public usdc;
    uint256 public totalUSDCDeposits;
    uint256 public totalDebt;

    mapping(address => uint256) matchUserId;

    uint256 public constant blockInterest = 100000013881950033; // (1.001의 7200제곱근) * 10^17
    uint256 public constant dayInterest = 100100000000000000; // 100.1 * 10^17

    constructor(IPriceOracle _priceOracle, address _usdc) {
        priceOracle = _priceOracle;
        usdc = _usdc;
    }

    function initializeLendingProtocol(address token) external payable {
        require(msg.value > 0, "Must send ether to initialize");
        ERC20(usdc).transferFrom(msg.sender, address(this), msg.value);
    }

    function updateBorrow(User memory user_, uint256 index) internal {
        // totaldebt update
        if (user_.usdcBorrow != 0 && block.number != user_.lastUpdate) {
            uint256 usdcBorrow_ = user_.usdcBorrow;
            uint256 afterblock = block.number - user_.lastUpdate;

            uint256 day = afterblock / 7200; // 1 day = 7200 block
            uint256 withinday = afterblock % 7200;

            // for optimization
            uint256 dayInterest_ = dayInterest;
            uint256 blockInterest_ = blockInterest;

            assembly {
                for { let i := 0 } lt(i, day) { i := add(i, 1) } {
                    usdcBorrow_ := div(mul(usdcBorrow_, dayInterest_), 100000000000000000)
                }

                for { let j := 0 } lt(j, withinday) { j := add(j, 1) } {
                    usdcBorrow_ := div(mul(usdcBorrow_, blockInterest_), 100000000000000000)
                }
            }

            // update
            totalDebt += (usdcBorrow_ - user_.usdcBorrow);
            user_.usdcBorrow = usdcBorrow_;
        }
        user_.lastUpdate = block.number;
        Users[index] = user_;
    }

    function updateDeposit(User memory user_, uint256 index) internal {
        if (user_.usdcDeposit != 0) {
            user_.usdcDeposit =
                user_.usdcDeposit + (totalDebt - user_.updatedTotalDebt) * user_.usdcDeposit / totalUSDCDeposits;
            user_.updatedTotalDebt = totalDebt;
            Users[index] = user_;
        }
    }

    function updateAll() internal {
        uint256 oldTotalDebt = totalDebt;
        for (uint256 i = 0; i < Users.length; i++) {
            User memory user_ = Users[i];
            updateBorrow(user_, i);
        }
        // if totalDebt changed, we should update deposit of each user
        if (oldTotalDebt != totalDebt) {
            for (uint256 i = 0; i < Users.length; i++) {
                User memory user_ = Users[i];
                updateDeposit(user_, i);
            }
        }
    }

    function deposit(address token, uint256 amount) external payable {
        // no need to update in deposit
        User memory user_;
        if (matchUserId[msg.sender] != 0) {
            user_ = Users[matchUserId[msg.sender] - 1];
        } else {
            // initialize user
            matchUserId[msg.sender] = userCount + 1;
            user_.updatedTotalDebt = totalDebt;
            user_.lastUpdate = block.number;
            Users.push(user_);
            userCount++;
        }

        require(amount > 0, "Amount must be greater than 0");
        if (token == address(0)) {
            // Ether deposit
            require(msg.value == amount, "Sent ether must equal amount");
            user_.etherDeposit += msg.value;
            Users[matchUserId[msg.sender] - 1] = user_;
        } else if (token == usdc) {
            // USDC deposit
            ERC20(usdc).transferFrom(msg.sender, address(this), amount);
            user_.usdcDeposit += amount;
            totalUSDCDeposits += amount;
            Users[matchUserId[msg.sender] - 1] = user_;
        } else {
            revert("Unsupported token");
        }
    }

    function borrow(address token, uint256 amount) external {
        require(token == usdc, "Only USDC can be borrowed");
        require(matchUserId[msg.sender] != 0, "Do other thing first");

        updateAll();
        User memory user_ = Users[matchUserId[msg.sender] - 1];

        uint256 collateralValueInUSDC = (user_.etherDeposit * priceOracle.getPrice(address(0x00))) / 1 ether;
        uint256 maxBorrow = (collateralValueInUSDC * 50) / 100; // loan to value

        require(user_.usdcBorrow + amount <= maxBorrow, "Insufficient collateral");
        require(amount <= totalUSDCDeposits, "Insufficient liquidity");

        ERC20(usdc).transfer(msg.sender, amount);
        user_.usdcBorrow += amount;
        Users[matchUserId[msg.sender] - 1] = user_;
    }

    function repay(address token, uint256 amount) external {
        require(token == usdc, "Only USDC can be repaid");
        require(matchUserId[msg.sender] != 0, "Do other thing first");

        updateAll();

        ERC20(usdc).transferFrom(msg.sender, address(this), amount);
        Users[matchUserId[msg.sender] - 1].usdcBorrow -= amount;
    }

    function withdraw(address token, uint256 amount) external {
        require(matchUserId[msg.sender] != 0, "Do other thing first");

        updateAll();
        User memory user_ = Users[matchUserId[msg.sender] - 1];

        if (token == address(0)) {
            // Ether withdrawal
            uint256 collateralValueInUSDC = (user_.etherDeposit * priceOracle.getPrice(address(0))) / 1 ether;
            uint256 borrowedAmount = user_.usdcBorrow;
            require(
                (collateralValueInUSDC - ((priceOracle.getPrice(address(0)) * amount) / 1 ether)) * 75 / 100
                    >= borrowedAmount,
                "Collateral is locked"
            );

            payable(msg.sender).transfer(amount);
            user_.etherDeposit -= amount;
            Users[matchUserId[msg.sender] - 1] = user_;
        } else if (token == usdc) {
            // USDC withdrawal
            require(user_.usdcDeposit >= amount, "Insufficient balance");

            ERC20(usdc).transfer(msg.sender, amount);
            totalUSDCDeposits -= amount;
            user_.usdcDeposit -= amount;
            Users[matchUserId[msg.sender] - 1] = user_;
        } else {
            revert("Unsupported token");
        }
    }

    function liquidate(address borrower, address token, uint256 amount) external {
        require(token == usdc, "Only USDC can be used for liquidation");

        updateAll();
        User memory user_ = Users[matchUserId[borrower] - 1];

        uint256 collateralValueInUSDC = (user_.etherDeposit * priceOracle.getPrice(address(0))) / 1 ether;
        uint256 borrowedAmount = user_.usdcBorrow;
        uint256 amount_ = amount * 1e18 / priceOracle.getPrice(address(usdc));

        require(collateralValueInUSDC < (borrowedAmount * 100) / 75, "Loan is not eligible for liquidation");
        require(
            (amount_ == borrowedAmount && borrowedAmount < 100 ether) || (amount_ <= borrowedAmount * 1 / 4),
            "Invalid amount"
        );

        ERC20(usdc).transferFrom(msg.sender, address(this), amount);
        user_.usdcBorrow -= amount_;
        user_.etherDeposit -= (amount_ * 1 ether) / priceOracle.getPrice(address(0));
        Users[matchUserId[borrower] - 1] = user_;

        payable(msg.sender).transfer((amount_ * 1 ether) / priceOracle.getPrice(address(0)));
    }

    function getAccruedSupplyAmount(address token) external returns (uint256) {
        require(token == usdc, "Invalid token");
        if (matchUserId[msg.sender] == 0) {
            return 0;
        }

        updateAll();
        User memory user_ = Users[matchUserId[msg.sender] - 1];
        return Users[matchUserId[msg.sender] - 1].usdcDeposit;
    }
}
