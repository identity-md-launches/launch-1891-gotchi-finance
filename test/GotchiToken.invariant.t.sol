// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {GotchiToken} from "../src/GotchiToken.sol";

/// @dev Keeps an independent ledger while exercising balances, allowances and failed operations.
contract GotchiHandler is Test {
    GotchiToken public immutable token;
    address[4] public actors;
    mapping(address => uint256) public modelBalance;
    mapping(address => mapping(address => uint256)) public modelAllowance;

    constructor(GotchiToken token_, address[4] memory actors_) {
        token = token_;
        actors = actors_;
        modelBalance[actors_[0]] = 1_000_000_000 * 10 ** 18;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 amount = bound(amountSeed, 0, modelBalance[from]);
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        modelBalance[from] -= amount;
        modelBalance[to] += amount;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amountSeed, bool infinite) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        uint256 amount = infinite ? type(uint256).max : bound(amountSeed, 0, 1_000_000_000 * 10 ** 18);
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        modelAllowance[owner][spender] = amount;
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amountSeed) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 approved = modelAllowance[owner][spender];
        uint256 limit = approved < modelBalance[owner] ? approved : modelBalance[owner];
        uint256 amount = bound(amountSeed, 0, limit);
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount));
        if (approved != type(uint256).max) modelAllowance[owner][spender] -= amount;
        modelBalance[owner] -= amount;
        modelBalance[to] += amount;
    }

    function insufficientBalance(uint256 fromSeed, uint256 excessSeed) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[(fromSeed % actors.length + 1) % actors.length];
        uint256 balance = modelBalance[from];
        uint256 amount = balance + bound(excessSeed, 1, 1_000_000_000 * 10 ** 18);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, balance, amount));
        vm.prank(from);
        token.transfer(to, amount);
    }

    function insufficientAllowance(uint256 ownerSeed, uint256 spenderSeed) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        uint256 approved = modelAllowance[owner][spender];
        if (approved == type(uint256).max) return;
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, approved, approved + 1)
        );
        vm.prank(spender);
        token.transferFrom(owner, spender, approved + 1);
    }
}

contract GotchiTokenInvariantTest is StdInvariant, Test {
    uint256 private constant SUPPLY = 1_000_000_000 * 10 ** 18;
    GotchiToken private token;
    GotchiHandler private handler;
    address[4] private actors;

    function setUp() public {
        token = new GotchiToken();
        actors = [makeAddr("actor-0"), makeAddr("actor-1"), makeAddr("actor-2"), makeAddr("actor-3")];
        handler = new GotchiHandler(token, actors);
        token.transfer(actors[0], SUPPLY);

        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = GotchiHandler.transfer.selector;
        selectors[1] = GotchiHandler.approve.selector;
        selectors[2] = GotchiHandler.transferFrom.selector;
        selectors[3] = GotchiHandler.insufficientBalance.selector;
        selectors[4] = GotchiHandler.insufficientAllowance.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_supplyAndBalancesAgreeWithIndependentLedger() public view {
        uint256 sum;
        for (uint256 i; i < actors.length; ++i) {
            uint256 balance = token.balanceOf(actors[i]);
            assertEq(balance, handler.modelBalance(actors[i]));
            sum += balance;
        }
        assertEq(sum, SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function invariant_allowancesAgreeWithIndependentLedger() public view {
        for (uint256 i; i < actors.length; ++i) {
            for (uint256 j; j < actors.length; ++j) {
                assertEq(token.allowance(actors[i], actors[j]), handler.modelAllowance(actors[i], actors[j]));
            }
        }
    }

    function invariant_noSupplyLeaksOutsideHolders() public view {
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.balanceOf(address(handler)), 0);
    }
}
