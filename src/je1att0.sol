// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "lib/ABDKMathQuad.sol";

interface IPriceOracle {
    function operator() external view returns (address);
    function getPrice(address token) external view returns (uint256);
    function setPrice(address token, uint256 price) external;
}

contract DreamAcademyLending {
    using ABDKMathQuad for bytes16;

    struct LoanAccount {
        uint256 depositedETH;
        uint256 depositedUSDC;
        uint256 borrowedUSDC;
        uint256 lastDepositBlock;
        uint256 lastBorrowedBlock;
        uint256 limitLeft;
        uint256 liquidableLeft;
        bool liquidable;
        uint256 interest;
        uint256 borrowedUSDCinterest;
    }

    mapping(address => LoanAccount) private accounts;

    IPriceOracle public upsideOracle;
    ERC20 public usdc;

    address[] public accountAddr;

    uint256 LTV = 50;
    uint256 THRESHOLD = 75;
    uint256 public constant INTEREST = 1;

    constructor(IPriceOracle _priceOracle, address _usdcAddress) {
        upsideOracle = _priceOracle;
        usdc = ERC20(_usdcAddress);
    }

    function initializeLendingProtocol(address _usdcAddress) public payable {
        deposit(_usdcAddress, msg.value);
        deposit(address(0x0), msg.value);
    }

    function deposit(address _tokenAddress, uint256 _amount) public payable {
        if (_tokenAddress != address(0x0)) {
            if (accounts[msg.sender].depositedUSDC == 0) {
                accountAddr.push(msg.sender);
            }
            accounts[msg.sender].lastDepositBlock = block.number;
            accounts[msg.sender].depositedUSDC += _amount;
            usdc.transferFrom(msg.sender, address(this), _amount);
        } else {
            require(msg.value > 0, "Empty TxValue");
            require(msg.value == _amount, "Insufficient Value");
            if (accounts[msg.sender].depositedETH == 0) {
                accountAddr.push(msg.sender);
            }
            accounts[msg.sender].lastDepositBlock = block.number;
            accounts[msg.sender].depositedETH += msg.value;
            payable(address(this)).transfer(msg.value);
        }
    }

    function borrow(address _tokenAddress, uint256 _amount) public payable {
        uint256 ETHprice = upsideOracle.getPrice(address(0x0));
        uint256 USDCprice = upsideOracle.getPrice(address(usdc));
        LoanAccount memory borrowerAccount = updatedAccount(msg.sender);

        require(usdc.balanceOf(address(this)) > 0, "Insufficient USDC supply");
        require(borrowerAccount.limitLeft >= _amount, "Insufficient collateral");
        borrowerAccount.borrowedUSDC += _amount;

        if (borrowerAccount.borrowedUSDC >= 100 ether) {
            borrowerAccount.liquidableLeft = borrowerAccount.borrowedUSDC * 25 / 100;
        } else {
            borrowerAccount.liquidableLeft = borrowerAccount.borrowedUSDC;
        }
        borrowerAccount.lastBorrowedBlock = block.number;
        usdc.transfer(msg.sender, _amount);
        accounts[msg.sender] = borrowerAccount;
    }

    function updatedAccount(address _userAddress) public returns (LoanAccount memory account) {
        uint256 ETHprice = upsideOracle.getPrice(address(0x0));
        uint256 USDCprice = upsideOracle.getPrice(address(usdc));
        account = accounts[_userAddress];
        // 하루에 86400/12 블록. 1블록은 12초 = 12/86400일
        if (account.borrowedUSDC > 0) {
            uint256 block_elapsed = block.number - account.lastBorrowedBlock;

            if (block_elapsed > 0) {
                if (block_elapsed < 86400) {
                    account.borrowedUSDCinterest += calExponentialInterestByBlock(account.borrowedUSDC, block_elapsed);
                } else {
                    uint256 day_elapsed = block_elapsed * 12 / 86400;
                    account.borrowedUSDCinterest += calExponentialInterest(account.borrowedUSDC, day_elapsed);
                }
            }
        }

        if (
            (((account.depositedETH / 10 ** 18) * ETHprice) / USDCprice) * 1e18 * LTV / 100
                >= account.borrowedUSDC + account.borrowedUSDCinterest
        ) {
            account.limitLeft = (((account.depositedETH / 10 ** 18) * ETHprice) / USDCprice) * 1e18 * LTV / 100
                - (account.borrowedUSDC + account.borrowedUSDCinterest);
        } else {
            account.limitLeft = 0;
            account.liquidable = true;
        }
    }

    function calExponentialInterestByBlock(uint256 _total_borrowed_usdc, uint256 _block_elapsed)
        public
        returns (uint256)
    {
        uint256 principal = _total_borrowed_usdc / 1e18;
        uint256 baseRate = 100000013888888888888; // 1.00000013888888888888888을 고정 소수점 1e20 스케일로 표현
        uint256 scale = 1e20;

        uint256 compoundFactor = scale;
        for (uint256 i = 0; i < _block_elapsed; i++) {
            compoundFactor = (compoundFactor * baseRate) / scale;
        }

        uint256 result = (principal * compoundFactor) / scale;

        return result;
    }

    function repay(address _tokenAddress, uint256 _amount) public payable {
        LoanAccount memory account = updatedAccount(msg.sender);
        account.borrowedUSDC -= _amount;
        accounts[msg.sender] = account;

        usdc.transferFrom(msg.sender, address(this), _amount);
    }

    function withdraw(address _tokenAddress, uint256 _amount) public payable {
        uint256 ETHprice = upsideOracle.getPrice(address(0x0));
        uint256 USDCprice = upsideOracle.getPrice(address(usdc));
        LoanAccount memory account = updatedAccount(msg.sender);
        if (_tokenAddress == address(0x0)) {
            account.depositedETH -= _amount;
            if (account.borrowedUSDC > 0) {
                require(checkThreshold(account), "Undercollateralized $SEAGOLD loan");
            }
            payable(msg.sender).transfer(_amount);
        } else {
            usdc.transfer(msg.sender, _amount);
        }
        accounts[msg.sender] = account;
    }

    function checkThreshold(LoanAccount memory _account) public returns (bool) {
        uint256 ETHprice = upsideOracle.getPrice(address(0x0));
        uint256 USDCprice = upsideOracle.getPrice(address(usdc));

        return USDCprice * (_account.borrowedUSDC + _account.borrowedUSDCinterest * 1e18) * 100
            < ETHprice * _account.depositedETH * THRESHOLD;
    }

    function getAccruedSupplyAmount(address _tokenAddress) public returns (uint256) {
        distributeInterest();
        return accounts[msg.sender].depositedUSDC + accounts[msg.sender].interest;
    }

    function calTotalInterest() public returns (uint256) {
        uint256 total_borrowed_usdc;
        uint256 day_elapsed;
        for (uint256 i = 0; i < accountAddr.length; i++) {
            address borrowed_account = accountAddr[i];
            if (accounts[borrowed_account].borrowedUSDC > 0) {
                total_borrowed_usdc += accounts[borrowed_account].borrowedUSDC;

                day_elapsed = (block.number - accounts[borrowed_account].lastBorrowedBlock) * 12 / 86400;
            }
        }
        uint256 totalInterest = calExponentialInterest(total_borrowed_usdc, day_elapsed);
        return totalInterest;
    }

    function calExponentialInterest(uint256 _total_borrowed_usdc, uint256 _day_elapsed) public returns (uint256) {
        uint256 principal = _total_borrowed_usdc / 1e18;
        uint256 rate = 1001000 * 1e12; // 1.001을 1000000으로 스케일링한 값
        uint256 n = _day_elapsed;
        uint256 scale = 1e18; // 고정 소수점 연산을 위한 스케일링 값

        uint256 compoundFactor = scale;
        for (uint256 i = 0; i < n; i++) {
            compoundFactor = (compoundFactor * rate) / scale;
        }

        uint256 result = (principal * (compoundFactor - scale));
        return result;
    }

    function distributeInterest() public {
        uint256 interestAccrued = calTotalInterest();

        uint256 interestDistributed;
        for (uint256 i = 0; i < accountAddr.length; i++) {
            address distributed_account = accountAddr[i];
            interestDistributed += accounts[distributed_account].interest;
        }

        uint256 interest_left = interestAccrued - interestDistributed;

        uint256 total_deposited_usdc;
        for (uint256 i = 0; i < accountAddr.length; i++) {
            address deposited_account = accountAddr[i];
            total_deposited_usdc += accounts[deposited_account].depositedUSDC;
        }

        for (uint256 i = 0; i < accountAddr.length; i++) {
            address interest_account = accountAddr[i];
            if (accounts[interest_account].depositedUSDC > 1) {
                accounts[interest_account].interest +=
                    interest_left * (accounts[interest_account].depositedUSDC * 1e18 / total_deposited_usdc) / 1e18;
            }
        }
    }

    function liquidate(address _userAddress, address _tokenAddress, uint256 _amount) public payable {
        LoanAccount memory account = updatedAccount(_userAddress);
        uint256 ETHprice = upsideOracle.getPrice(address(0x0));
        require(account.liquidable == true && account.limitLeft == 0, "Loan is not undercollateralized");
        require(account.liquidableLeft >= _amount, "Exceed amount to liquidate");

        uint256 liquidate_amount = (_amount / ETHprice) * 10 ** 18;
        account.depositedETH -= liquidate_amount;
        account.liquidableLeft -= _amount;

        payable(msg.sender).transfer(liquidate_amount);
        accounts[_userAddress] = account;
    }

    receive() external payable {}
}
