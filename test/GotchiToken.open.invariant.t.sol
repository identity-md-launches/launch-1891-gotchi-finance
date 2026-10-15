// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {GotchiToken} from "../src/GotchiToken.sol";

/// @dev Drives the token with fuzzer-chosen addresses rather than a fixed cast, so the token contract,
/// the handler, precompiles and arbitrary accounts all become holders. Keeps a ghost ledger of what
/// each address received and sent, an enumerable set of every address that ever held tokens, and a
/// ghost allowance book for every (owner, spender) pair touched. Rejected operations are driven on
/// purpose and must leave every ghost unchanged.
contract OpenGotchiHandler is Test {
    uint256 public constant SUPPLY = 1_000_000_000 * 10 ** 18;

    GotchiToken public immutable token;
    address public immutable launcher;

    address[] public holders;
    mapping(address => bool) public isHolder;
    mapping(address => uint256) public ghostReceived;
    mapping(address => uint256) public ghostSent;

    struct Pair {
        address owner;
        address spender;
    }

    Pair[] public pairs;
    mapping(address => mapping(address => bool)) public pairSeen;
    mapping(address => mapping(address => uint256)) public ghostAllowance;

    uint256 public ghostTransfers;
    uint256 public ghostDelegatedTransfers;
    uint256 public ghostRejected;
    uint256 public ghostVolume;

    constructor(GotchiToken token_, address launcher_) {
        token = token_;
        launcher = launcher_;
        _track(launcher_);
        ghostReceived[launcher_] = SUPPLY;
    }

    // ------------------------------------------------------------------------------------------
    // Address selection
    // ------------------------------------------------------------------------------------------

    /// @dev Any address but zero and the two cheatcode addresses. Half the time the fuzzer's raw
    /// address is used, half the time an existing holder, so senders usually have something to send.
    function _pick(address raw, uint256 seed) private view returns (address) {
        if (seed % 2 == 0 && holders.length > 0) return holders[seed / 2 % holders.length];
        if (raw == address(0) || raw == VM_ADDRESS || raw == CONSOLE) return holders[seed % holders.length];
        return raw;
    }

    function _track(address account) private {
        if (!isHolder[account]) {
            isHolder[account] = true;
            holders.push(account);
        }
    }

    function _trackPair(address owner, address spender) private {
        if (!pairSeen[owner][spender]) {
            pairSeen[owner][spender] = true;
            pairs.push(Pair(owner, spender));
        }
    }

    function _ghostBalance(address account) private view returns (uint256) {
        return ghostReceived[account] - ghostSent[account];
    }

    function holderCount() external view returns (uint256) {
        return holders.length;
    }

    function pairCount() external view returns (uint256) {
        return pairs.length;
    }

    // ------------------------------------------------------------------------------------------
    // Successful operations
    // ------------------------------------------------------------------------------------------

    function transfer(address rawFrom, address rawTo, uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = _pick(rawFrom, fromSeed);
        address to = _pick(rawTo, toSeed);
        uint256 amount = bound(amountSeed, 0, _ghostBalance(from));
        _transfer(from, to, amount);
    }

    /// @dev Full-amount stress variant: the sender empties itself.
    function transferAll(address rawFrom, address rawTo, uint256 fromSeed, uint256 toSeed) external {
        address from = _pick(rawFrom, fromSeed);
        address to = _pick(rawTo, toSeed);
        _transfer(from, to, _ghostBalance(from));
    }

    /// @dev Near-zero stress variant: dust amounts, including zero.
    function transferDust(address rawFrom, address rawTo, uint256 fromSeed, uint256 toSeed, uint256 amountSeed)
        external
    {
        address from = _pick(rawFrom, fromSeed);
        address to = _pick(rawTo, toSeed);
        uint256 cap = _ghostBalance(from) < 3 ? _ghostBalance(from) : 3;
        _transfer(from, to, bound(amountSeed, 0, cap));
    }

    function _transfer(address from, address to, uint256 amount) private {
        uint256 fromBefore = token.balanceOf(from);
        uint256 toBefore = token.balanceOf(to);
        vm.prank(from);
        assertTrue(token.transfer(to, amount), "transfer returned false");
        if (from == to) {
            assertEq(token.balanceOf(from), fromBefore, "self-transfer changed the balance");
        } else {
            assertEq(token.balanceOf(from), fromBefore - amount, "sender debited wrongly");
            assertEq(token.balanceOf(to), toBefore + amount, "receiver credited wrongly");
        }
        ghostSent[from] += amount;
        ghostReceived[to] += amount;
        _track(to);
        ++ghostTransfers;
        ghostVolume += amount;
    }

    function approve(address rawOwner, address rawSpender, uint256 ownerSeed, uint256 spenderSeed, uint256 amount)
        external
    {
        address owner = _pick(rawOwner, ownerSeed);
        address spender = _pick(rawSpender, spenderSeed);
        vm.prank(owner);
        assertTrue(token.approve(spender, amount), "approve returned false");
        assertEq(token.allowance(owner, spender), amount, "approve did not replace the allowance");
        ghostAllowance[owner][spender] = amount;
        _trackPair(owner, spender);
    }

    /// @dev Type-boundary variant: the conventional unlimited allowance, which must never be consumed.
    /// A random uint256 practically never lands on the maximum, so this path is driven on purpose.
    function approveInfinite(address rawOwner, address rawSpender, uint256 ownerSeed, uint256 spenderSeed) external {
        address owner = _pick(rawOwner, ownerSeed);
        address spender = _pick(rawSpender, spenderSeed);
        vm.prank(owner);
        assertTrue(token.approve(spender, type(uint256).max), "approve returned false");
        ghostAllowance[owner][spender] = type(uint256).max;
        _trackPair(owner, spender);
    }

    function transferFrom(
        address rawOwner,
        address rawSpender,
        address rawTo,
        uint256 ownerSeed,
        uint256 spenderSeed,
        uint256 toSeed,
        uint256 amountSeed
    ) external {
        address owner = _pick(rawOwner, ownerSeed);
        address spender = _pick(rawSpender, spenderSeed);
        address to = _pick(rawTo, toSeed);
        uint256 approved = ghostAllowance[owner][spender];
        uint256 balance = _ghostBalance(owner);
        uint256 amount = bound(amountSeed, 0, approved < balance ? approved : balance);
        _transferFrom(owner, spender, to, amount);
    }

    /// @dev Full-amount stress variant: spends min(allowance, balance) in one call.
    function transferFromAll(
        address rawOwner,
        address rawSpender,
        address rawTo,
        uint256 ownerSeed,
        uint256 spenderSeed,
        uint256 toSeed
    ) external {
        address owner = _pick(rawOwner, ownerSeed);
        address spender = _pick(rawSpender, spenderSeed);
        address to = _pick(rawTo, toSeed);
        uint256 approved = ghostAllowance[owner][spender];
        uint256 balance = _ghostBalance(owner);
        _transferFrom(owner, spender, to, approved < balance ? approved : balance);
    }

    function _transferFrom(address owner, address spender, address to, uint256 amount) private {
        uint256 approved = ghostAllowance[owner][spender];
        uint256 ownerBefore = token.balanceOf(owner);
        uint256 toBefore = token.balanceOf(to);
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount), "transferFrom returned false");
        if (owner == to) {
            assertEq(token.balanceOf(owner), ownerBefore, "self-transferFrom changed the balance");
        } else {
            assertEq(token.balanceOf(owner), ownerBefore - amount, "owner debited wrongly");
            assertEq(token.balanceOf(to), toBefore + amount, "receiver credited wrongly");
        }
        if (approved != type(uint256).max) ghostAllowance[owner][spender] = approved - amount;
        assertEq(token.allowance(owner, spender), ghostAllowance[owner][spender], "allowance consumed wrongly");
        ghostSent[owner] += amount;
        ghostReceived[to] += amount;
        _track(to);
        _trackPair(owner, spender);
        ++ghostDelegatedTransfers;
        ghostVolume += amount;
    }

    /// @dev Time and block height move; nothing about the token may depend on them.
    function advanceTime(uint256 secondsSeed, uint256 blocksSeed) external {
        vm.warp(block.timestamp + bound(secondsSeed, 0, 365 days));
        vm.roll(block.number + bound(blocksSeed, 0, 1_000_000));
    }

    // ------------------------------------------------------------------------------------------
    // Rejected operations: every one must revert with the exact error and change nothing
    // ------------------------------------------------------------------------------------------

    function rejectOverspend(address rawFrom, address rawTo, uint256 fromSeed, uint256 toSeed, uint256 excessSeed)
        external
    {
        address from = _pick(rawFrom, fromSeed);
        address to = _pick(rawTo, toSeed);
        uint256 balance = _ghostBalance(from);
        uint256 amount = balance + bound(excessSeed, 1, type(uint256).max - balance);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, balance, amount));
        vm.prank(from);
        token.transfer(to, amount);
        ++ghostRejected;
    }

    function rejectTransferToZero(address rawFrom, uint256 fromSeed, uint256 amountSeed) external {
        address from = _pick(rawFrom, fromSeed);
        uint256 amount = bound(amountSeed, 0, _ghostBalance(from));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(from);
        token.transfer(address(0), amount);
        ++ghostRejected;
    }

    function rejectTransferFromZeroSender(address rawTo, uint256 toSeed, uint256 amountSeed) external {
        address to = _pick(rawTo, toSeed);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSender.selector, address(0)));
        vm.prank(address(0));
        token.transfer(to, amountSeed);
        ++ghostRejected;
    }

    function rejectApproveZeroSpender(address rawOwner, uint256 ownerSeed, uint256 amount) external {
        address owner = _pick(rawOwner, ownerSeed);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        vm.prank(owner);
        token.approve(address(0), amount);
        ++ghostRejected;
    }

    function rejectOverAllowance(
        address rawOwner,
        address rawSpender,
        address rawTo,
        uint256 ownerSeed,
        uint256 spenderSeed,
        uint256 toSeed,
        uint256 excessSeed
    ) external {
        address owner = _pick(rawOwner, ownerSeed);
        address spender = _pick(rawSpender, spenderSeed);
        address to = _pick(rawTo, toSeed);
        uint256 approved = ghostAllowance[owner][spender];
        if (approved == type(uint256).max) return;
        uint256 amount = approved + bound(excessSeed, 1, type(uint256).max - approved);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, approved, amount)
        );
        vm.prank(spender);
        token.transferFrom(owner, to, amount);
        ++ghostRejected;
    }

    /// @dev Allowance covers the amount but the balance does not: the allowance must roll back intact.
    function rejectOverBalanceViaAllowance(
        address rawOwner,
        address rawSpender,
        address rawTo,
        uint256 ownerSeed,
        uint256 spenderSeed,
        uint256 toSeed,
        uint256 excessSeed
    ) external {
        address owner = _pick(rawOwner, ownerSeed);
        address spender = _pick(rawSpender, spenderSeed);
        address to = _pick(rawTo, toSeed);
        uint256 balance = _ghostBalance(owner);
        uint256 amount = balance + bound(excessSeed, 1, SUPPLY);
        vm.prank(owner);
        token.approve(spender, amount);
        ghostAllowance[owner][spender] = amount;
        _trackPair(owner, spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, balance, amount));
        vm.prank(spender);
        token.transferFrom(owner, to, amount);
        assertEq(token.allowance(owner, spender), amount, "a failed transferFrom consumed allowance");
        ++ghostRejected;
    }

    /// @dev Pulling from the zero address with a zero amount passes the allowance check and must still
    /// be refused when the unchanged allowance is written back.
    function rejectPullFromZeroOwner(address rawSpender, uint256 spenderSeed) external {
        address spender = _pick(rawSpender, spenderSeed);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        vm.prank(spender);
        token.transferFrom(address(0), spender, 0);
        ++ghostRejected;
    }

    /// @dev Common privileged entrypoints, called by the launcher (the address a token would most
    /// plausibly trust) and by a random account. None may exist.
    function rejectPrivilegedCall(address rawCaller, uint256 callerSeed, uint256 which, uint256 amount) external {
        address caller = _pick(rawCaller, callerSeed);
        address target = holders[which % holders.length];
        bytes[8] memory calls = [
            abi.encodeWithSignature("mint(address,uint256)", caller, amount),
            abi.encodeWithSignature("burn(uint256)", amount),
            abi.encodeWithSignature("burnFrom(address,uint256)", target, amount),
            abi.encodeWithSignature("pause()"),
            abi.encodeWithSignature("freeze(address)", target),
            abi.encodeWithSignature("seize(address)", target),
            abi.encodeWithSignature("setBlacklist(address,bool)", target, true),
            abi.encodeWithSignature("transferOwnership(address)", caller)
        ];
        bytes memory data = calls[which % calls.length];
        vm.prank(launcher);
        (bool ok,) = address(token).call(data);
        assertFalse(ok, "launcher reached a privileged entrypoint");
        vm.prank(caller);
        (ok,) = address(token).call(data);
        assertFalse(ok, "a stranger reached a privileged entrypoint");
        ++ghostRejected;
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 48
/// forge-config: default.invariant.fail-on-revert = true
contract GotchiTokenOpenInvariantTest is StdInvariant, Test {
    uint256 private constant SUPPLY = 1_000_000_000 * 10 ** 18;

    GotchiToken private token;
    OpenGotchiHandler private handler;
    address private launcher;

    function setUp() public {
        launcher = makeAddr("launcher");
        vm.prank(launcher);
        token = new GotchiToken();
        handler = new OpenGotchiHandler(token, launcher);
        targetContract(address(handler));
    }

    /// @dev T-01: the supply is exactly the sum over every address that ever held tokens. Because the
    /// holder set is open, this also proves no tokens leaked to an address the handler never used.
    function invariant_supplyIsTheSumOverEveryHolder() public view {
        uint256 count = handler.holderCount();
        uint256 sum;
        for (uint256 i; i < count; ++i) {
            sum += token.balanceOf(handler.holders(i));
        }
        assertEq(sum, SUPPLY, "balances do not sum to the supply");
        assertEq(token.totalSupply(), SUPPLY, "the supply changed");
    }

    /// @dev Every holder's balance equals what it received minus what it sent, from an independent
    /// ledger that only counts successful calls. Rejected calls therefore must not have moved anything.
    function invariant_everyBalanceMatchesTheGhostLedger() public view {
        uint256 count = handler.holderCount();
        for (uint256 i; i < count; ++i) {
            address holder = handler.holders(i);
            uint256 expected = handler.ghostReceived(holder) - handler.ghostSent(holder);
            assertEq(token.balanceOf(holder), expected, "a balance disagrees with the ledger");
            assertLe(token.balanceOf(holder), SUPPLY, "a balance exceeds the supply");
        }
    }

    /// @dev Every (owner, spender) pair touched holds exactly the allowance the ledger expects.
    function invariant_everyAllowanceMatchesTheGhostBook() public view {
        uint256 count = handler.pairCount();
        for (uint256 i; i < count; ++i) {
            (address owner, address spender) = handler.pairs(i);
            assertEq(token.allowance(owner, spender), handler.ghostAllowance(owner, spender));
        }
    }

    /// @dev T-06 and provenance: the zero address never holds, and nobody but the launcher can hold
    /// more than the volume that successful transfers have moved, because that is the only way in.
    function invariant_zeroAddressHoldsNothingAndTokensOnlyArriveByTransfer() public view {
        assertEq(token.balanceOf(address(0)), 0);
        uint256 count = handler.holderCount();
        uint256 moved = handler.ghostVolume();
        for (uint256 i; i < count; ++i) {
            address holder = handler.holders(i);
            if (holder == launcher) continue;
            assertLe(token.balanceOf(holder), moved, "a holder has more than was ever transferred");
        }
    }

    /// @dev Volume can only have moved through counted calls, and the supply never depended on it.
    function invariant_volumeAccountingIsConsistent() public view {
        uint256 count = handler.holderCount();
        uint256 totalSent;
        uint256 totalReceived;
        for (uint256 i; i < count; ++i) {
            address holder = handler.holders(i);
            totalSent += handler.ghostSent(holder);
            totalReceived += handler.ghostReceived(holder);
        }
        assertEq(totalSent, handler.ghostVolume(), "sent volume disagrees");
        assertEq(totalReceived, handler.ghostVolume() + SUPPLY, "received volume disagrees");
    }
}
