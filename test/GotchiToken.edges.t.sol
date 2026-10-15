// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {GotchiToken} from "../src/GotchiToken.sol";

/// @dev Deploys the token and performs the whole launch distribution inside one creation
/// transaction, the way `launchCustom` does. Deployment and distribution share one call so a
/// token that relied on per-transaction state (transient storage, tx.origin) would be caught.
contract OneTransactionLaunch {
    GotchiToken public immutable token;

    constructor(address distributor, address pool, address requester, uint256 swarmShare, uint256 poolShare) {
        token = new GotchiToken();
        uint256 supply = token.totalSupply();
        require(token.balanceOf(address(this)) == supply, "constructor did not credit the creator");
        require(token.transfer(distributor, swarmShare), "distributor transfer returned false");
        require(token.transfer(pool, poolShare), "pool transfer returned false");
        require(token.transfer(requester, supply - swarmShare - poolShare), "remainder transfer returned false");
    }
}

/// @dev Low-level deployment helpers: creation with ETH attached, and creation with trailing bytes.
contract RawDeployer {
    function createWithValue(bytes memory code) external payable returns (address deployed) {
        uint256 value = msg.value;
        assembly ("memory-safe") {
            deployed := create(value, add(code, 32), mload(code))
        }
    }

    function create(bytes memory code) external returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create(0, add(code, 32), mload(code))
        }
    }
}

/// @notice Edge and failure paths the first suite leaves uncovered: the zero address as a sender or
/// approver, ETH arriving at the token, deployment with value, event discipline on `transferFrom`,
/// exact allowance boundaries, open-address transfers, and independence between deployments.
contract GotchiTokenEdgesTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000 * 10 ** 18;

    GotchiToken private token;
    address private alice;
    address private bob;
    address private spender;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        spender = makeAddr("spender");
        token = new GotchiToken();
    }

    /// @dev Keeps fuzzed addresses usable as both recipients and pranked senders.
    function _usable(address account, string memory fallbackLabel) private returns (address) {
        if (account == address(0) || account == VM_ADDRESS || account == CONSOLE) return makeAddr(fallbackLabel);
        return account;
    }

    // ----------------------------------------------------------------------------------------------
    // The zero address as a participant
    // ----------------------------------------------------------------------------------------------

    function test_transferFromTheZeroAddressRevertsEvenForZeroAmount() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSender.selector, address(0)));
        vm.prank(address(0));
        token.transfer(alice, 0);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferFromTheZeroAddressRevertsBeforeReceiverCheck() public {
        // Sender is validated first, so even a zero recipient reports the sender.
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSender.selector, address(0)));
        vm.prank(address(0));
        token.transfer(address(0), 1);
    }

    function test_approveFromTheZeroAddressReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        vm.prank(address(0));
        token.approve(spender, 1);
        assertEq(token.allowance(address(0), spender), 0);
    }

    function test_delegatedZeroAmountSpendFromTheZeroAddressReverts() public {
        // Allowance of the zero address is 0 and 0 >= 0, so the allowance check passes; the write-back
        // of the unchanged allowance is what refuses the zero owner. Nothing may be pulled from it.
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        vm.prank(spender);
        token.transferFrom(address(0), bob, 0);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_delegatedSpendFromTheZeroAddressRevertsOnAllowance() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(address(0), bob, 1);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_zeroAddressSpenderCannotPullEvenZero() public {
        // approve(address(0), x) is rejected, so the zero spender never has an allowance; a pull of 0
        // still passes the allowance check and then fails to write the allowance back.
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        vm.prank(address(0));
        token.transferFrom(address(this), bob, 0);
        assertEq(token.balanceOf(bob), 0);
    }

    // ----------------------------------------------------------------------------------------------
    // ETH and unknown calls
    // ----------------------------------------------------------------------------------------------

    function test_tokenRejectsPlainEther() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(token).call{value: 1}("");
        assertFalse(ok, "token accepted ether");
        assertEq(address(token).balance, 0);
        assertEq(alice.balance, 1 ether);
    }

    function test_tokenRejectsEtherOnTransfer() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(token).call{value: 1}(abi.encodeCall(IERC20.transfer, (bob, 0)));
        assertFalse(ok, "non-payable transfer accepted ether");
        assertEq(address(token).balance, 0);
    }

    function testFuzz_unknownSelectorReverts(bytes4 selector, bytes calldata args) public {
        vm.assume(
            selector != IERC20.transfer.selector && selector != IERC20.approve.selector
                && selector != IERC20.transferFrom.selector && selector != IERC20.balanceOf.selector
                && selector != IERC20.allowance.selector && selector != IERC20.totalSupply.selector
                && selector != bytes4(keccak256("name()")) && selector != bytes4(keccak256("symbol()"))
                && selector != bytes4(keccak256("decimals()")) && selector != bytes4(keccak256("INITIAL_SUPPLY()"))
        );
        (bool ok,) = address(token).call(abi.encodePacked(selector, args));
        assertFalse(ok, "an unknown selector was accepted");
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_deploymentWithValueFails() public {
        RawDeployer deployer = new RawDeployer();
        vm.deal(address(this), 1 ether);
        address deployed = deployer.createWithValue{value: 1 wei}(type(GotchiToken).creationCode);
        assertEq(deployed, address(0), "a non-payable constructor accepted ether");
    }

    function test_creationCodeTakesNoArgumentsAndDeploysBare() public {
        RawDeployer deployer = new RawDeployer();
        address deployed = deployer.create(type(GotchiToken).creationCode);
        assertTrue(deployed != address(0));
        assertEq(GotchiToken(deployed).balanceOf(address(deployer)), SUPPLY);
        assertEq(GotchiToken(deployed).totalSupply(), SUPPLY);
    }

    // ----------------------------------------------------------------------------------------------
    // One-transaction launch
    // ----------------------------------------------------------------------------------------------

    function test_launchDistributionInsideOneCreationTransaction() public {
        address distributor = makeAddr("distributor");
        address pool = makeAddr("pool-manager");
        address requester = makeAddr("requester");
        uint256 swarmShare = SUPPLY / 10;
        uint256 poolShare = SUPPLY * 8 / 10;
        OneTransactionLaunch launch = new OneTransactionLaunch(distributor, pool, requester, swarmShare, poolShare);
        GotchiToken launched = launch.token();
        assertEq(launched.balanceOf(address(launch)), 0);
        assertEq(launched.balanceOf(distributor), swarmShare);
        assertEq(launched.balanceOf(pool), poolShare);
        assertEq(launched.balanceOf(requester), SUPPLY - swarmShare - poolShare);
        assertEq(launched.balanceOf(address(this)), 0);
        assertEq(launched.totalSupply(), SUPPLY);
    }

    // ----------------------------------------------------------------------------------------------
    // Event discipline
    // ----------------------------------------------------------------------------------------------

    function test_transferEmitsExactlyOneEvent() public {
        vm.recordLogs();
        token.transfer(alice, 5 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].emitter, address(token));
        assertEq(logs[0].topics[0], Transfer.selector);
        assertEq(address(uint160(uint256(logs[0].topics[1]))), address(this));
        assertEq(address(uint160(uint256(logs[0].topics[2]))), alice);
        assertEq(abi.decode(logs[0].data, (uint256)), 5 ether);
    }

    function test_transferFromEmitsOnlyTransferAndNoApproval() public {
        // The vendored OpenZeppelin version lowers the allowance silently; integrators must read
        // `allowance` rather than wait for an Approval event. Pinned here so a change is visible.
        token.approve(spender, 10 ether);
        vm.recordLogs();
        vm.prank(spender);
        token.transferFrom(address(this), bob, 3 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], Transfer.selector);
        assertEq(address(uint160(uint256(logs[0].topics[1]))), address(this));
        assertEq(address(uint160(uint256(logs[0].topics[2]))), bob);
        assertEq(abi.decode(logs[0].data, (uint256)), 3 ether);
        assertEq(token.allowance(address(this), spender), 7 ether);
    }

    function test_failedTransferEmitsNothing() public {
        vm.recordLogs();
        vm.prank(alice);
        (bool ok,) = address(token).call(abi.encodeCall(IERC20.transfer, (bob, 1)));
        assertFalse(ok);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function test_approveEmitsExactlyOneApproval() public {
        vm.recordLogs();
        token.approve(spender, 1);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], Approval.selector);
        assertEq(address(uint160(uint256(logs[0].topics[1]))), address(this));
        assertEq(address(uint160(uint256(logs[0].topics[2]))), spender);
        assertEq(abi.decode(logs[0].data, (uint256)), 1);
    }

    // ----------------------------------------------------------------------------------------------
    // Allowance boundaries
    // ----------------------------------------------------------------------------------------------

    function testFuzz_exactAllowanceAndExactBalanceSucceed(uint256 amount) public {
        amount = bound(amount, 1, SUPPLY);
        token.transfer(alice, amount);
        vm.prank(alice);
        token.approve(spender, amount);
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, amount));
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), amount);
        assertEq(token.allowance(alice, spender), 0);
    }

    function testFuzz_oneWeiShortOfAllowanceFails(uint256 amount) public {
        amount = bound(amount, 1, SUPPLY);
        token.transfer(alice, amount);
        vm.prank(alice);
        token.approve(spender, amount - 1);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, amount - 1, amount)
        );
        vm.prank(spender);
        token.transferFrom(alice, bob, amount);
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.allowance(alice, spender), amount - 1);
    }

    function testFuzz_oneWeiShortOfBalanceFailsWithAllowanceIntact(uint256 amount) public {
        amount = bound(amount, 1, SUPPLY);
        token.transfer(alice, amount - 1);
        vm.prank(alice);
        token.approve(spender, amount);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, amount - 1, amount)
        );
        vm.prank(spender);
        token.transferFrom(alice, bob, amount);
        assertEq(token.balanceOf(alice), amount - 1);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.allowance(alice, spender), amount);
    }

    function testFuzz_infiniteAllowanceSurvivesAnySpend(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        token.approve(spender, type(uint256).max);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), bob, amount));
        assertEq(token.allowance(address(this), spender), type(uint256).max);
        assertEq(token.balanceOf(bob), amount);
        assertEq(token.balanceOf(address(this)), SUPPLY - amount);
    }

    function test_maxMinusOneAllowanceIsFiniteAndConsumed() public {
        token.approve(spender, type(uint256).max - 1);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), bob, 1));
        assertEq(token.allowance(address(this), spender), type(uint256).max - 2);
    }

    function test_infiniteAllowanceStillCannotExceedBalance() public {
        token.transfer(alice, 1 ether);
        vm.prank(alice);
        token.approve(spender, type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 1 ether, 1 ether + 1)
        );
        vm.prank(spender);
        token.transferFrom(alice, bob, 1 ether + 1);
        assertEq(token.allowance(alice, spender), type(uint256).max);
        assertEq(token.balanceOf(alice), 1 ether);
    }

    function test_selfApprovalLetsHolderPullOwnTokensAndIsConsumed() public {
        token.approve(address(this), 2 ether);
        assertTrue(token.transferFrom(address(this), alice, 2 ether));
        assertEq(token.balanceOf(alice), 2 ether);
        assertEq(token.allowance(address(this), address(this)), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(this), 0, 1));
        token.transferFrom(address(this), alice, 1);
    }

    function testFuzz_approvalsOfDistinctPairsAreIndependent(
        address ownerA,
        address spenderA,
        address ownerB,
        address spenderB,
        uint256 amountA,
        uint256 amountB
    ) public {
        ownerA = _usable(ownerA, "owner-a");
        ownerB = _usable(ownerB, "owner-b");
        spenderA = _usable(spenderA, "spender-a");
        spenderB = _usable(spenderB, "spender-b");
        if (ownerA == ownerB && spenderA == spenderB) spenderB = makeAddr("spender-b-distinct");
        vm.prank(ownerA);
        token.approve(spenderA, amountA);
        vm.prank(ownerB);
        token.approve(spenderB, amountB);
        assertEq(token.allowance(ownerA, spenderA), amountA);
        assertEq(token.allowance(ownerB, spenderB), amountB);
        // Allowances are directional: the reverse pair of A is untouched unless B happens to be it.
        bool reverseOfAIsB = ownerB == spenderA && spenderB == ownerA;
        if (ownerA != spenderA && !reverseOfAIsB) assertEq(token.allowance(spenderA, ownerA), 0);
        // Approving moves no tokens.
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_transferDoesNotTouchAllowances() public {
        token.approve(spender, 7 ether);
        vm.prank(alice);
        token.approve(spender, 9 ether);
        token.transfer(alice, 20 ether);
        vm.prank(alice);
        token.transfer(address(this), 5 ether);
        assertEq(token.allowance(address(this), spender), 7 ether);
        assertEq(token.allowance(alice, spender), 9 ether);
    }

    // ----------------------------------------------------------------------------------------------
    // Open-address transfers
    // ----------------------------------------------------------------------------------------------

    function testFuzz_transferToAnyNonZeroAddressIsExact(address to, uint256 amount) public {
        to = _usable(to, "recipient");
        amount = bound(amount, 0, SUPPLY);
        uint256 toBefore = token.balanceOf(to);
        uint256 fromBefore = token.balanceOf(address(this));
        assertTrue(token.transfer(to, amount));
        if (to == address(this)) {
            assertEq(token.balanceOf(to), toBefore);
        } else {
            assertEq(token.balanceOf(to), toBefore + amount);
            assertEq(token.balanceOf(address(this)), fromBefore - amount);
        }
        assertLe(token.balanceOf(to), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_strangerHoldsNothingAndCannotSend(address stranger, uint256 amount) public {
        stranger = _usable(stranger, "stranger");
        vm.assume(stranger != address(this));
        amount = bound(amount, 1, type(uint256).max);
        assertEq(token.balanceOf(stranger), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, stranger, 0, amount));
        vm.prank(stranger);
        token.transfer(alice, amount);
    }

    function test_transferOfMaxUint256Reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(this), SUPPLY, type(uint256).max
            )
        );
        token.transfer(alice, type(uint256).max);
    }

    function test_supplyPlusOneCannotMoveEvenFromTheFullHolder() public {
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), SUPPLY, SUPPLY + 1)
        );
        token.transfer(alice, SUPPLY + 1);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_tokensSentToTheTokenContractAreStrandedButCounted() public {
        // Documented: no rescue function exists. The supply still accounts for them.
        assertTrue(token.transfer(address(token), 1 ether));
        assertEq(token.balanceOf(address(token)), 1 ether);
        assertEq(token.totalSupply(), SUPPLY);
        (bool ok,) = address(token).call(abi.encodeWithSignature("rescue(address,uint256)", alice, 1 ether));
        assertFalse(ok);
        (ok,) = address(token).call(abi.encodeWithSignature("recoverERC20(address,uint256)", address(token), 1 ether));
        assertFalse(ok);
        assertEq(token.balanceOf(address(token)), 1 ether);
    }

    function test_transferToPrecompileAddressSucceeds() public {
        assertTrue(token.transfer(address(1), 1));
        assertEq(token.balanceOf(address(1)), 1);
    }

    // ----------------------------------------------------------------------------------------------
    // Independence and determinism
    // ----------------------------------------------------------------------------------------------

    function test_independentDeploymentsDoNotShareState() public {
        GotchiToken other = new GotchiToken();
        token.transfer(alice, 10 ether);
        token.approve(spender, 3 ether);
        assertEq(other.balanceOf(alice), 0);
        assertEq(other.balanceOf(address(this)), SUPPLY);
        assertEq(other.allowance(address(this), spender), 0);
        assertEq(other.totalSupply(), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        vm.prank(alice);
        other.transfer(bob, 1);
    }

    function test_metadataIsStableAcrossDeploymentsAndTime() public {
        GotchiToken other = new GotchiToken();
        vm.warp(block.timestamp + 365 days);
        vm.roll(block.number + 2_000_000);
        assertEq(other.name(), token.name());
        assertEq(other.symbol(), token.symbol());
        assertEq(other.decimals(), token.decimals());
        assertEq(other.INITIAL_SUPPLY(), token.INITIAL_SUPPLY());
        assertEq(keccak256(address(other).code), keccak256(address(token).code));
    }

    function testFuzz_transferSequenceIsOrderIndependentInTotals(uint256 a, uint256 b) public {
        // Two transfers to two recipients: the final balances do not depend on the order.
        a = bound(a, 0, SUPPLY / 2);
        b = bound(b, 0, SUPPLY / 2);
        GotchiToken other = new GotchiToken();
        token.transfer(alice, a);
        token.transfer(bob, b);
        other.transfer(bob, b);
        other.transfer(alice, a);
        assertEq(token.balanceOf(alice), other.balanceOf(alice));
        assertEq(token.balanceOf(bob), other.balanceOf(bob));
        assertEq(token.balanceOf(address(this)), other.balanceOf(address(this)));
        assertEq(token.balanceOf(alice) + token.balanceOf(bob) + token.balanceOf(address(this)), SUPPLY);
    }

    function testFuzz_splitAndMergeIsLossless(uint256 total, uint256 split) public {
        total = bound(total, 0, SUPPLY);
        split = bound(split, 0, total);
        token.transfer(alice, split);
        token.transfer(alice, total - split);
        assertEq(token.balanceOf(alice), total);
        vm.startPrank(alice);
        token.transfer(bob, total - split);
        token.transfer(bob, split);
        vm.stopPrank();
        assertEq(token.balanceOf(bob), total);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY - total);
    }
}
