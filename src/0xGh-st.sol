// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface IPriceOracle {
    function getPrice(address token) external view returns (uint256);
}

contract DreamAcademyLending is ERC20 {
    IPriceOracle public priceOracle;
    address public USDC;

    struct Account {
        uint256 collateral;
        uint256 balance;
        uint256 debt;
        uint256 blockNum;
        uint256 reserves;
    }

    struct Update {
        uint256 interestRate;
        uint256 cacheInterestRate;
        address[] actors;
    }

    Update public update;
    mapping(address => Account) public accounts;

    uint256 public immutable BLOCKS_PER_DAY = 7200; // 7200 blocks per day
    uint256 public immutable INTEREST_RATE = 1e15; // 24-hour interest rate of 0.1% compounded
    uint256 public immutable LTV = 50; // 50% LTV
    uint256 public immutable LIQUIDATION_THRESHOLD = 75;
    uint256 public immutable decimal = 10 ** 18;

    event Deposit(address indexed user, uint256 amount);
    event Borrow(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);
    event Repay(address indexed user, uint256 amount);
    event Liquidate(address indexed user, uint256 amount);

    constructor(IPriceOracle _priceOracle, address _usdc) ERC20("DreamAcademyLending", "DAL") {
        priceOracle = _priceOracle;
        USDC = _usdc;
    }

    function initializeLendingProtocol(address _usdc) external payable {
        require(msg.value > 0, "initializeLendingProtocol: Failed");
        ERC20(_usdc).transferFrom(msg.sender, address(this), 1);
    }

    function deposit(address _tokenAddress, uint256 _amount) external payable {
        require(_amount > 0, "deposit: Failed");

        if (_tokenAddress == address(0)) {
            require(msg.value >= _amount, "deposit: Failed");
            accounts[msg.sender].collateral += _amount;
        } else {
            _updateProtocol(USDC);
            accounts[msg.sender].balance += _amount;
            update.actors.push(msg.sender);
            ERC20(USDC).transferFrom(msg.sender, address(this), _amount);
        }

        emit Deposit(msg.sender, _amount);
    }

    function borrow(address _tokenAddress, uint256 _amount) external {
        require(_tokenAddress == USDC, "borrow: Failed");
        uint256 _ethCollateral = accounts[msg.sender].collateral;
        uint256 _maxBorrow = _getMaxBorrowAmount(_ethCollateral);
        require(_amount <= _maxBorrow, "borrow: Failed");
        uint256 _maxBorrowAddress = _getMaxBorrowCurrentDebtCheck(msg.sender);
        require(_amount <= _maxBorrowAddress, "borrow: Failed");

        (uint256 _ethPrice, uint256 _usdcPrice) = _getCurrentPrices();
        require(
            (_ethPrice * accounts[msg.sender].collateral / 2) >= (_usdcPrice * (accounts[msg.sender].debt + _amount)),
            "borrow: Failed"
        );
        ERC20(USDC).transfer(msg.sender, _amount);
        accounts[msg.sender].debt += _amount;
        accounts[msg.sender].blockNum = block.number;
        update.actors.push(msg.sender);
        emit Borrow(msg.sender, _amount);
    }

    function repay(address _tokenAddress, uint256 _amount) external {
        require(_tokenAddress == USDC, "repay: Failed");
        require(_amount > 0, "repay: Failed");

        uint256 _interest = _calcInterest(msg.sender);
        accounts[msg.sender].debt += _interest;
        require(accounts[msg.sender].debt >= _amount, "repay: Failed");
        accounts[msg.sender].debt -= _amount;
        ERC20(USDC).transferFrom(msg.sender, address(this), _amount);
        emit Repay(msg.sender, _amount);
    }

    function liquidate(address _user, address _tokenAddress, uint256 _amount) external {
        require(_amount > 0, "liquidate: Failed");
        require(msg.sender != _user, "liquidate: Failed");
        require(_tokenAddress == USDC, "liquidate: Failed");
        require(!_isHealthy(_user), "liquidate: Failed");

        (uint256 _ethPrice, uint256 _usdcPrice) = _getCurrentPrices();
        require(
            (_ethPrice * accounts[_user].collateral * LIQUIDATION_THRESHOLD / 100) < (accounts[_user].debt * _usdcPrice),
            "liquidate: Failed"
        );
        require(accounts[_user].debt * 25 / 100 >= _amount, "liquidate: Failed");

        uint256 _ethAmountToTransfer = _amount * accounts[_user].collateral / accounts[_user].debt;
        accounts[_user].debt -= _amount;
        ERC20(USDC).transferFrom(msg.sender, address(this), _amount);
        payable(msg.sender).transfer(_ethAmountToTransfer);
        emit Liquidate(_user, _amount);
    }

    function withdraw(address _tokenAddress, uint256 _amount) external {
        require(_amount > 0, "withdraw: Failed");
        require(accounts[msg.sender].balance > 0 || accounts[msg.sender].collateral > 0, "withdraw: Failed");

        uint256 _interest = _calcInterest(msg.sender);

        if (_tokenAddress == address(0)) {
            require(accounts[msg.sender].collateral >= _amount, "withdraw: Failed");

            if (accounts[msg.sender].debt == 0) {
                accounts[msg.sender].collateral -= _amount;
                payable(msg.sender).transfer(_amount);
            } else {
                (uint256 _ethPrice, uint256 _usdcPrice) = _getCurrentPrices();
                uint256 _newCollateral = accounts[msg.sender].collateral - _amount;

                require(_newCollateral <= accounts[msg.sender].collateral, "withdraw: Failed");

                require(
                    _ethPrice * _newCollateral * LIQUIDATION_THRESHOLD / 100 >= accounts[msg.sender].debt * _usdcPrice,
                    "withdraw: Failed"
                );

                accounts[msg.sender].collateral = _newCollateral;
                payable(msg.sender).transfer(_amount);
            }
        } else {
            uint256 _accruedSupply = getAccruedSupplyAmount(USDC);

            require(accounts[msg.sender].balance + _accruedSupply >= _amount, "withdraw: Failed");

            accounts[msg.sender].balance -= _amount;
            ERC20(USDC).transfer(msg.sender, _amount);
        }

        emit Withdraw(msg.sender, _amount);
    }

    function getAccruedSupplyAmount(address _usdc) public returns (uint256) {
        _updateProtocol(address(0));
        uint256 _usdcBalance = ERC20(_usdc).balanceOf(address(this));
        uint256 _userBalance = accounts[msg.sender].balance;
        uint256 _reserves = accounts[msg.sender].reserves;

        uint256 _accruedInterest = 0;
        if (_usdcBalance > 0 && update.interestRate > update.cacheInterestRate) {
            _accruedInterest = ((update.interestRate - update.cacheInterestRate) * _userBalance) / _usdcBalance;
        }

        uint256 _accruedSupply = _userBalance + _reserves + _accruedInterest;

        require(_accruedSupply >= _userBalance && _accruedSupply >= _reserves, "getAccruedSupplyAmount: Failed");

        return _accruedSupply;
    }

    function _updateProtocol(address _usdc) internal {
        uint256 _actorsLen = update.actors.length;
        uint256 _interestRate = update.interestRate;

        if (_usdc != address(0)) {
            uint256 _totalUsdcBalance = ERC20(_usdc).balanceOf(address(this));
            uint256 _cacheInterestRate = _interestRate;
            for (uint256 _i = 0; _i < _actorsLen; _i++) {
                address _addr = update.actors[_i];
                uint256 _reserves = (_interestRate * accounts[_addr].balance) / _totalUsdcBalance;
                accounts[_addr].reserves = _reserves;
            }
            update.cacheInterestRate = _cacheInterestRate;
        } else {
            for (uint256 _i = 0; _i < _actorsLen; _i++) {
                address _user = update.actors[_i];
                _interestRate += _calcInterest(_user);
            }
        }
        update.interestRate = _interestRate;
    }

    function _getCurrentPrices() internal view returns (uint256 _ethPrice, uint256 _usdcPrice) {
        _ethPrice = priceOracle.getPrice(address(0));
        _usdcPrice = priceOracle.getPrice(USDC);
    }

    function _getMaxBorrowAmount(uint256 _collateral) internal view returns (uint256) {
        uint256 _collateralValueInUsdc = _collateral * priceOracle.getPrice(address(0)) / 1e18;
        return (_collateralValueInUsdc * LTV) / 100;
    }

    function _getMaxBorrowCurrentDebtCheck(address _user) internal view returns (uint256) {
        uint256 _ethCollateral = accounts[_user].collateral;
        uint256 _collateralValueInUsdc = _ethCollateral * priceOracle.getPrice(address(0)) / 1e18;
        uint256 _maxBorrowAmount = (_collateralValueInUsdc * LTV) / 100;
        uint256 _currentDebt = accounts[_user].debt;

        return _maxBorrowAmount > _currentDebt ? _maxBorrowAmount - _currentDebt : 0;
    }

    function _isHealthy(address _user) internal view returns (bool) {
        uint256 _currentDebt = accounts[_user].debt;
        uint256 _ethCollateral = accounts[_user].collateral;
        uint256 _maxBorrowAmount = _getMaxBorrowAmount(_ethCollateral);

        return _currentDebt <= _maxBorrowAmount;
    }

    function _getInterest(uint256 _p, uint256 _r, uint256 _n) internal pure returns (uint256) {
        uint256 _rate = _r + decimal;
        uint256 _compounded = _p;
        for (uint256 _i = 0; _i < _n; _i++) {
            _compounded = (_compounded * _rate) / decimal;
        }
        return _compounded;
    }

    function _calcInterest(address _user) internal returns (uint256) {
        uint256 _distance = block.number - accounts[_user].blockNum;
        uint256 _blockPerDay = _distance / BLOCKS_PER_DAY;
        uint256 _blockPerDayLast = _distance % BLOCKS_PER_DAY;
        uint256 _currentDebt = accounts[_user].debt;
        uint256 _compoundInterestDebt = _getInterest(_currentDebt, INTEREST_RATE, _blockPerDay);
        if (_blockPerDayLast != 0) {
            _compoundInterestDebt += (_getInterest(_compoundInterestDebt, INTEREST_RATE, 1) - _compoundInterestDebt)
                * _blockPerDayLast / BLOCKS_PER_DAY;
        }
        uint256 _compound = _compoundInterestDebt > _currentDebt ? _compoundInterestDebt - _currentDebt : 0;
        accounts[_user].debt = _compoundInterestDebt;
        accounts[_user].blockNum = block.number;
        return _compound;
    }

    receive() external payable {}
}
