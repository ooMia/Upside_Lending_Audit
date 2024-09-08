// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IPriceOracle {
    function getPrice(address token) external view returns (uint256);
    function setPrice(address token, uint256 price) external;
}

contract UpsideAcademyLending {
    IPriceOracle oracle;
    IERC20 usdc;

    mapping(address => uint256) private accounts;
    mapping(address => uint256) private firstAccount;
    mapping(address => uint256) private tokenAccount;
    mapping(address => uint256) private borrowBlock;

    constructor(IPriceOracle _oracle, address _usdc) {
        oracle = IPriceOracle(_oracle);
        usdc = IERC20(_usdc);
    }

    function initializeLendingProtocol(address _usdc) public payable {
        IERC20(usdc).transferFrom(msg.sender, address(this), msg.value);
    }

    function deposit(address token, uint256 tokenAmount) public payable {
        if (token == address(0x00)) {
            require(msg.value >= tokenAmount, "your ether lower than deposit ether");
            accounts[msg.sender] += tokenAmount;
            firstAccount[msg.sender] += tokenAmount;
        } else {
            uint256 allow = usdc.allowance(msg.sender, address(this));
            require(allow >= tokenAmount, "your token lower than deposit token");
            usdc.transferFrom(msg.sender, address(this), tokenAmount);
            tokenAccount[msg.sender] += tokenAmount;
        }
    }

    function borrow(address token, uint256 tokenAmount) public payable {
        uint256 currentPrice = tokenAmount * oracle.getPrice(token);
        uint256 ltvLimit = (accounts[msg.sender] * oracle.getPrice(address(0x0)))
            - (firstAccount[msg.sender] * oracle.getPrice(address(0x0)) / 2); // LT 50

        require(ltvLimit >= currentPrice, "lower than LTV");
        require(usdc.balanceOf(address(this)) >= tokenAmount, "Lender's usdc amount lack.");

        tokenAccount[msg.sender] += tokenAmount;
        accounts[msg.sender] =
            (accounts[msg.sender] * oracle.getPrice(address(0x0)) - currentPrice) / oracle.getPrice(address(0x0));

        borrowBlock[msg.sender] = block.number;
        usdc.transfer(msg.sender, tokenAmount);
    }

    function repay(address token, uint256 tokenAmount) public payable {
        require(usdc.allowance(msg.sender, address(this)) > tokenAmount, "");
        tokenAccount[msg.sender] -= tokenAmount; // 갚는 토큰이니 사실상 같은 값을 갚는다.

        uint256 returnEth = (tokenAmount * 1 ether) / (oracle.getPrice(address(0x0)));

        if (block.number - borrowBlock[msg.sender] > 0) {
            returnEth = (returnEth * 1999 * (block.number - borrowBlock[msg.sender]))
                / (2000 * (block.number - borrowBlock[msg.sender]));
        }

        accounts[msg.sender] += returnEth; // 여기에 이율 곱해서 돌려받아야함

        IERC20(token).transferFrom(msg.sender, address(this), tokenAmount);
    }

    function withdraw(address token, uint256 tokenAmount) public payable {
        if (block.number - borrowBlock[msg.sender] > 0 && borrowBlock[msg.sender] > 0) {
            for (uint256 i = 0; i < (block.number - borrowBlock[msg.sender]); i++) {
                accounts[msg.sender] = accounts[msg.sender] * 1999 / 2000;
            }
        }

        require(accounts[msg.sender] >= tokenAmount, "your balance lower than etherAmount");

        payable(msg.sender).call{value: tokenAmount}("");
    }

    function getAccruedSupplyAmount(address tokenAddr) public returns (uint256) {
        uint256 price = oracle.getPrice(tokenAddr) * tokenAccount[msg.sender];

        for (uint256 i = 0; i < 7200000; i++) {
            price = price * 1999 / 2000;
        }

        //G.G
    }

    function liquidate(address user, address token, uint256 tokenAmount) public {
        require(tokenAccount[user] > 0, "User must have a loan.");

        uint256 collateralEthValue = firstAccount[user] * oracle.getPrice(address(0x0));
        uint256 debtTokenValue = tokenAmount * oracle.getPrice(token);
        uint256 totalDebtValue = tokenAccount[user] * oracle.getPrice(token);

        require(collateralEthValue * 75 / 100 < totalDebtValue, "Not liquidatable"); // LT = 75%
        require(debtTokenValue <= (totalDebtValue / 4), "Liquidation amount is too high.");

        tokenAccount[user] -= tokenAmount;
        accounts[user] -= debtTokenValue / oracle.getPrice(address(0x0));
        firstAccount[user] -= debtTokenValue / oracle.getPrice(address(0x0));

        require(IERC20(token).transferFrom(msg.sender, address(this), tokenAmount), "Liquidation transfer failed");
    }
}
