// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "forge-std/Test.sol";

interface IPriceOracle {
    function getPrice(address token) external view returns (uint256);
}

contract UpsideAcademyLending {
    IPriceOracle public price_oracle;

    event LogEvent(uint256 message);

    address public usdc;

    struct ACCOUNT {
        uint256 ETHDepositAmount;
        uint256 USDCDepositAmount;
        uint256 BorrowAmount;
        uint256 DepositInterest;
        uint256 BorrowInterest;
        uint256 UpdatedBlock;
    }

    uint256 public LT = 75;
    uint256 public LTV = 50;
    uint256 public INTEREST_RATE = 1e15;
    uint256 public INTEREST_RATE_PER_BLOCK = 1000000138822311089;
    uint256 public WAD = 1e18;
    uint256 public BLOCK_PER_DAY = 7200;
    uint256 public TotalDepositUSDC;
    uint256 public TotalBorrowUSDC;
    uint256 public UpdateBlock;

    address[] public lender;
    address[] public borrower;

    mapping(address => ACCOUNT) public account;
    mapping(address => bool) public userInit;

    constructor(IPriceOracle upsideOracle, address token) {
        price_oracle = upsideOracle;
        usdc = token;
    }

    modifier onlyUser() {
        require(userInit[msg.sender], "not user");
        _;
    }

    modifier accrueInterest(address target) {
        if (UpdateBlock < block.number) {
            uint256 i;
            uint256 distance = block.number - UpdateBlock;
            uint256 distancePerDay = distance / BLOCK_PER_DAY;
            uint256 leftDistance = distance % BLOCK_PER_DAY;
            uint256 interestAccrued = TotalBorrowUSDC;
            if (distancePerDay > 0) {
                for (uint256 i = 0; i < distancePerDay; i++) {
                    interestAccrued = (interestAccrued * (1e18 + INTEREST_RATE)) / 1e18;
                }
            }
            if (leftDistance > 0) {
                for (uint256 i = 0; i < leftDistance; i++) {
                    interestAccrued = (interestAccrued * INTEREST_RATE_PER_BLOCK) / 1e18;
                }
            }
            uint256 interest = interestAccrued - TotalBorrowUSDC;
            uint256 j = 0;
            while (j < borrower.length) {
                if (account[borrower[j]].UpdatedBlock < block.number) {
                    target = borrower[j];
                    ACCOUNT memory user = account[target];
                    user.BorrowInterest += interest * (user.BorrowAmount + user.BorrowInterest) / TotalBorrowUSDC;
                    user.UpdatedBlock = block.number;
                    account[target] = user;
                }
                j++;
            }
            TotalBorrowUSDC += interest;
            uint256 k = 0;
            while (k < lender.length) {
                if (account[lender[k]].UpdatedBlock < block.number) {
                    target = lender[k];
                    ACCOUNT memory user = account[target];
                    user.DepositInterest +=
                        interest * (user.USDCDepositAmount + user.DepositInterest) / TotalDepositUSDC;
                    user.UpdatedBlock = block.number;
                    account[target] = user;
                }
                k++;
            }
            UpdateBlock = block.number;
        }
        _;
    }

    function initializeLendingProtocol(address token) external payable {
        ERC20(token).transferFrom(msg.sender, address(this), msg.value);
    }

    function deposit(address token, uint256 amount) external payable accrueInterest(msg.sender) {
        if (!userInit[msg.sender]) {
            userInit[msg.sender] = true;
            account[msg.sender].UpdatedBlock = block.number;
        }
        if (token == usdc) {
            require(0 < amount, "amount check");
            account[msg.sender].USDCDepositAmount += amount;
            TotalDepositUSDC += amount;
            ERC20(token).transferFrom(msg.sender, address(this), amount);
            lender.push(msg.sender);
        } else {
            require(0 < msg.value && amount <= msg.value, "amount check");
            account[msg.sender].ETHDepositAmount += amount;
        }
    }

    function borrow(address token, uint256 amount) external onlyUser accrueInterest(msg.sender) {
        require(TotalDepositUSDC >= amount, "check amount");
        (uint256 ethPrice, uint256 usdcPrice) = tokenPrice();
        uint256 max_borrow = calc_max_borrow(ethPrice);
        uint256 possible_borrow =
            max_borrow - ((account[msg.sender].BorrowAmount + account[msg.sender].BorrowInterest) * usdcPrice / 1 ether);
        require(amount <= possible_borrow, "amount check");

        borrower.push(msg.sender);
        TotalBorrowUSDC += amount;
        account[msg.sender].BorrowAmount += amount;
        ERC20(token).transfer(msg.sender, amount);
    }

    function withdraw(address token, uint256 amount) external onlyUser accrueInterest(msg.sender) {
        if (token == address(0x00)) {
            require(account[msg.sender].ETHDepositAmount >= amount, "check amount");
            uint256 total_debt = account[msg.sender].BorrowAmount + account[msg.sender].BorrowInterest;
            if (0 < total_debt) {
                (uint256 ethPrice, uint256 usdcPrice) = tokenPrice();
                uint256 remain_ETH_value = (account[msg.sender].ETHDepositAmount - amount) * ethPrice / 1 ether;
                uint256 borrow_USDC_value = total_debt * usdcPrice / 1 ether;
                require(borrow_USDC_value * 100 <= remain_ETH_value * LT, "check amount");
            }

            account[msg.sender].ETHDepositAmount -= amount;
            payable(msg.sender).transfer(amount);
        } else {
            require(
                account[msg.sender].USDCDepositAmount + account[msg.sender].DepositInterest >= amount, "check amount"
            );
            account[msg.sender].USDCDepositAmount += account[msg.sender].DepositInterest;
            account[msg.sender].DepositInterest = 0;
            account[msg.sender].USDCDepositAmount -= amount;
            ERC20(token).transfer(msg.sender, amount);
        }
    }

    function repay(address token, uint256 amount) external onlyUser accrueInterest(msg.sender) {
        uint256 total_debt = account[msg.sender].BorrowAmount;
        require(total_debt >= amount, "check amount");
        account[msg.sender].BorrowAmount -= amount;
        TotalBorrowUSDC -= amount;
        ERC20(token).transferFrom(msg.sender, address(this), amount);
    }

    function liquidate(address target, address token, uint256 amount) external accrueInterest(target) {
        (uint256 ethPrice, uint256 usdcPrice) = tokenPrice();

        uint256 totalDebt = account[target].BorrowAmount + account[target].BorrowInterest;
        require(totalDebt > 0, "No debt to liquidate");

        uint256 collateralvalueETH = (account[target].ETHDepositAmount * ethPrice) / 1 ether;
        uint256 totalDebtValue = account[target].BorrowAmount * usdcPrice / 1 ether;
        require(totalDebtValue * 100 >= collateralvalueETH * LT, "Loan healthy");

        uint256 maxLiquidation;
        if (totalDebt <= 100 ether) {
            maxLiquidation = totalDebt;
        } else {
            maxLiquidation = totalDebt / 4;
        }
        require(amount <= maxLiquidation, "Exceeds max liquidation amount");

        require(account[target].BorrowAmount > amount, "amount check plz");

        uint256 collateralToSeize = (amount * usdcPrice) / ethPrice;
        require(collateralToSeize <= account[target].ETHDepositAmount, "collateral check");

        account[target].BorrowAmount -= amount;
        account[target].ETHDepositAmount -= collateralToSeize;

        IERC20(usdc).transferFrom(msg.sender, address(this), amount);
        payable(msg.sender).transfer(collateralToSeize);
    }

    function getAccruedSupplyAmount(address token) external accrueInterest(msg.sender) returns (uint256) {
        return account[msg.sender].USDCDepositAmount + account[msg.sender].DepositInterest;
    }

    function tokenPrice() internal returns (uint256, uint256) {
        uint256 ethPrice = price_oracle.getPrice(address(0x0));
        uint256 usdcPrice = price_oracle.getPrice(usdc);
        return (ethPrice, usdcPrice);
    }

    function calc_max_borrow(uint256 price) internal returns (uint256) {
        uint256 collateralValue = account[msg.sender].ETHDepositAmount * price / 1 ether;
        return collateralValue * LTV / 100;
    }
}
