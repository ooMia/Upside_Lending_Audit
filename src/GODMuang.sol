// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IPriceOracle {
    function getPrice(address token) external view returns (uint256);
    function setPrice(address token, uint256 price) external;
}
//

contract DreamAcademyLending {
    event teest(address, uint256);

    IPriceOracle oracle;
    address token;

    // mapping(address => uint256) userDepositEther;
    // uint256 totalDepositEther;

    mapping(address => mapping(address => uint256)) userDepositToken;
    mapping(address => uint256) totalDepositToken;

    mapping(address => mapping(address => uint256)) private userBorrowed;

    mapping(address => uint256) lastBlockUpdate;
    uint256 interestRatePerBlock;

    constructor(IPriceOracle _oracle, address _token) {
        oracle = _oracle;
        token = _token;
        interestRatePerBlock = 5;
    }

    function initializeLendingProtocol(address _token) external payable {
        require(_token != address(0), "NO_ZERO_ADDRESS_FOR_TOKEN");
        token = _token;
        IERC20(token).transferFrom(msg.sender, address(this), msg.value);
    }
    //입금

    function deposit(address _token, uint256 _amount) external payable {
        updateDebt(msg.sender, token);
        // ether를 deposit
        if (_token == address(0)) {
            require(_amount == msg.value, "DEPOSIT_AMOUNT_MISMATCH");
        } else {
            // token deposit
            require(IERC20(_token).balanceOf(msg.sender) >= _amount, "INSUFFICIENT_ALLOWANCE");
            IERC20(_token).transferFrom(msg.sender, address(this), _amount);
        }
        userDepositToken[msg.sender][_token] += _amount;
        totalDepositToken[_token] += _amount;
    }

    //need sufficient gas limit after much time has passed
    function updateDebt(address _user, address _token) private {
        // 담보가 빌리는돈의 2배가 되어야함. 1블록만에 1000에서 999로
        // 1초에 1/12원만큼 이자가 붙으니까
        // 2000에 1블록당 1원의 이자고,
        // 1블록당(12초당) 0.05% 이자율이네.
        // 이제 블록당당 복리로 생각해봐야되는디

        uint256 blockGap = block.number - lastBlockUpdate[_user];
        // emit teest(msg.sender, borrowTemp);
        for (uint256 i = 0; i < blockGap; i++) {
            userBorrowed[_user][_token] += (userBorrowed[_user][_token] * interestRatePerBlock) / 10000 / 1e3;

            // emit teest(msg.sender, userBorrowed[_user][_token]);
        }

        lastBlockUpdate[_user] = block.number;
    }

    function calcUserTotalBorrowedPrice(address _user) private returns (uint256) {
        uint256 userEtherBorrowedPrice = userBorrowed[_user][address(0)] * oracle.getPrice(address(0)); // ether
        uint256 userTokenBorrowedPPrice = userBorrowed[_user][token] * oracle.getPrice(address(token));

        return userEtherBorrowedPrice + userTokenBorrowedPPrice;
    }

    function calcUserTotalDepositPrice(address _user) private returns (uint256) {
        uint256 userEtherDepositPrice = userDepositToken[_user][address(0)] * oracle.getPrice(address(0));
        uint256 userTokenDepositPrice = userDepositToken[_user][token] * oracle.getPrice(address(token));

        return userEtherDepositPrice + userTokenDepositPrice;
    }

    // _token을 _amount만큼 빌려줘라!
    function borrow(address _token, uint256 _amount) external {
        require(_amount != 0, "no 0");
        updateDebt(msg.sender, token);

        require(totalDepositToken[_token] >= _amount, "INSUFFICIENT_CURRENT_BALANCE");

        uint256 userTotalDepositPrice = calcUserTotalDepositPrice(msg.sender);
        uint256 userTryingBorrowPrice = oracle.getPrice(_token) * _amount;
        uint256 userTotalBorrowedPrice = calcUserTotalBorrowedPrice(msg.sender); // total debt

        require(
            userTotalDepositPrice >= (userTryingBorrowPrice + userTotalBorrowedPrice) * 2, "INSUFFICIENT_COLLATERAL"
        );

        userBorrowed[msg.sender][_token] += _amount;
        totalDepositToken[_token] -= _amount;

        if (_token == address(0)) {
            payable(msg.sender).transfer(_amount);
        } else {
            IERC20(_token).transfer(msg.sender, _amount);
        }
    }

    // 갚음
    function repay(address _token, uint256 _amount) external {
        updateDebt(msg.sender, token);
        require(_amount <= userBorrowed[msg.sender][_token], "you dont have to pay this much hehe..");
        require(IERC20(_token).balanceOf(msg.sender) >= _amount, "INSUFFICIENT_TOKEN_TO_REPAY");

        IERC20(_token).transferFrom(msg.sender, address(this), _amount);
        userBorrowed[msg.sender][_token] -= _amount;
        totalDepositToken[_token] += _amount;
    }

    function withdraw(address _token, uint256 _amount) external {
        updateDebt(msg.sender, token);

        uint256 userTotalDepositPrice = calcUserTotalDepositPrice(msg.sender);
        uint256 userTryingWithdrawPrice = oracle.getPrice(_token) * _amount;
        uint256 userBorrowedToken1 = (userBorrowed[msg.sender][token] * oracle.getPrice(token)); // if more token add more

        require(
            (userTotalDepositPrice - userTryingWithdrawPrice) * 3 / 4 >= userBorrowedToken1,
            "INSUFFICIENT_COLLTERAL_TO_WITHDRAW"
        ); // 75%이상

        if (_token == address(0)) {
            require(address(this).balance >= _amount, "INSUFFICIENT_BALANCE");
            userDepositToken[msg.sender][_token] -= _amount;
            payable(msg.sender).transfer(_amount);
        } else {
            require(IERC20(_token).balanceOf(address(this)) >= _amount, "INSUFFICIENT_VAULT_BALANCE");
            userDepositToken[msg.sender][_token] -= _amount;
            IERC20(_token).transfer(msg.sender, _amount);
        }
    }

    // 나중에
    // 누적이자 계산.
    // not implemented :(((
    // :{ turtle
    // (:[)
    // (:D)
    function getAccruedSupplyAmount(address _token) external returns (uint256) {
        // updateDebt(token);

        return userBorrowed[msg.sender][token];
    }

    // give token back.
    function liquidate(address _userLiquidated, address _token, uint256 _amount) external {
        updateDebt(msg.sender, _token);
        uint256 userTotalDepositPrice = calcUserTotalDepositPrice(_userLiquidated);
        uint256 userTotalBorrowedPrice = calcUserTotalBorrowedPrice(_userLiquidated);

        // LTV
        require(userTotalBorrowedPrice >= userTotalDepositPrice * 3 / 4, "HEALTHY_LOAN");

        // only .25 of debt
        require(_amount <= userBorrowed[_userLiquidated][_token] / 4, "Repay amount exceeds borrowed amount");
        uint256 collateralToSeize = (_amount * oracle.getPrice(token)) / oracle.getPrice(address(0));

        // get borrowed token back.
        userBorrowed[_userLiquidated][_token] -= _amount;
        IERC20(_token).transferFrom(_userLiquidated, address(this), _amount);

        // give msg.sender liquidated money
        require(userDepositToken[_userLiquidated][address(0)] >= collateralToSeize, "INSUFFICIENT_COLLATERAL_TO_SEIZE");
        userDepositToken[_userLiquidated][address(0)] -= collateralToSeize;
        payable(msg.sender).transfer(collateralToSeize);
    }
}
