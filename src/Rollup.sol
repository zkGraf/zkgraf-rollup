// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IRegistry {
    function ensureMyIdx() external returns (uint32);
    function accountIdx(address a) external view returns (uint32);
    function idxToAccount(uint32 idx) external view returns (address);
}

/// @dev Groth16 verifier adapter (snarkjs-style).
interface IGroth16Verifier {
    function verifyProof(
        uint256[2] calldata a,
        uint256[2][2] calldata b,
        uint256[2] calldata c,
        uint256[1] calldata input
    ) external view returns (bool);
}

/// @notice Minimal reentrancy guard
abstract contract ReentrancyGuard {
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _status = _NOT_ENTERED;

    modifier nonReentrant() {
        require(_status != _ENTERED, "REENTRANCY");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }
}

contract Rollup is ReentrancyGuard {
    // =============================================================
    // Owner / Config
    // =============================================================
    IRegistry public immutable registry;
    IGroth16Verifier public immutable verifier;

    address public owner;

    uint32 public constant MAX_BATCH = 3;
    uint256 public constant TX_FEE_WEI = 0.00005 ether;
    uint8 public constant MAX_DEGREE = 64;

    /// @notice reward pool funded by enqueue fees
    uint256 public feePool;

    /// @notice owner-controlled handshake params (locked per pair at vouch-time)
    uint256 public stakeWei;
    uint32 public windowDuration; // seconds

    modifier onlyOwner() {
        require(msg.sender == owner, "NOT_OWNER");
        _;
    }

    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);
    event StakeUpdated(uint256 stakeWei);
    event DurationUpdated(uint32 windowDuration);

    constructor(address registry_, address verifier_, uint256 stakeWei_, uint32 windowDuration_) {
        require(registry_ != address(0), "REGISTRY_ZERO");
        require(verifier_ != address(0), "VERIFIER_ZERO");
        require(stakeWei_ != 0, "STAKE_ZERO");
        require(windowDuration_ != 0, "DURATION_ZERO");

        registry = IRegistry(registry_);
        verifier = IGroth16Verifier(verifier_);
        owner = msg.sender;

        stakeWei = stakeWei_;
        windowDuration = windowDuration_;

        emit OwnershipTransferred(address(0), msg.sender);
        emit StakeUpdated(stakeWei_);
        emit DurationUpdated(windowDuration_);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "OWNER_ZERO");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function setStake(uint256 newStakeWei) external onlyOwner {
        require(newStakeWei != 0, "STAKE_ZERO");
        stakeWei = newStakeWei;
        emit StakeUpdated(newStakeWei);
    }

    function setDuration(uint32 newWindowDuration) external onlyOwner {
        require(newWindowDuration != 0, "DURATION_ZERO");
        windowDuration = newWindowDuration;
        emit DurationUpdated(newWindowDuration);
    }

    // =============================================================
    // Pair state (handshake)
    // =============================================================
    struct PairPacked {
        uint128 stakeWeiLocked; // 0 => inactive
        uint32 durationLocked; // seconds
        uint64 windowStart; // 0 => not open
        bool loFunded;
        bool hiFunded;
    }

    mapping(address => mapping(address => PairPacked)) public pairs; // [lo][hi]

    // =============================================================
    // Truth-state: permanent links (address-keyed, canonical order)
    // =============================================================
    mapping(address => mapping(address => bool)) public linked; // [lo][hi]
    mapping(address => uint8) public degree;
    // =============================================================
    // Pull payments
    // =============================================================
    mapping(address => uint256) public balances;

    // =============================================================
    // Unforged queue (operation stream)
    // =============================================================
    // Tx record layout (9 bytes / 72 bits):
    //   ilo(4) | ihi(4) | op(1)
    // Packed into uint128:
    //   w = (ilo<<40) | (ihi<<8) | op
    mapping(uint32 => uint128) public unforged;
    uint32 public nextTxId = 1;
    uint32 public lastForgedId = 0;

    // =============================================================
    // Roots / batches
    // =============================================================
    bytes32 public latestGraphRoot;
    uint64 public batchId = 0;

    // =============================================================
    // Opcodes
    // =============================================================
    uint8 internal constant OP_ADD = 1;
    uint8 internal constant OP_REVOKE = 2;

    // =============================================================
    // Errors
    // =============================================================
    error ZeroAddress();
    error Self();
    error NotParticipant();

    error PairAlreadyActive();
    error PairNotActive();
    error AlreadyFunded();
    error WindowAlreadyOpen();
    error WindowNotOpen();
    error WindowStillOpen();
    error PastWindow();
    error NotBothFunded();
    error NotSoleFunder();
    error NotCounterpartyFunded();

    error BadValue();
    error MissingIdx();

    error InsufficientBalance();
    error SendFailed();

    error EmptyBatch();
    error VerifyFail();

    error LinkDoesNotExist();
    error LinkAlreadyExists();
    error BadOp();

    // =============================================================
    // Events
    // =============================================================
    event Deposit(address indexed from, uint256 amount);

    event Vouched(
        address indexed funder,
        address indexed counterparty,
        address lo,
        address hi,
        uint256 stakeWei,
        uint32 durationSeconds
    );

    event WindowOpened(
        address indexed lo,
        address indexed hi,
        uint64 windowStart,
        uint64 windowEnd,
        uint256 stakeWei,
        uint32 durationSeconds
    );

    event VouchCancelled(address indexed caller, address indexed counterparty, uint256 creditedWei);
    event ClosedNoLink(address indexed caller, address indexed counterparty, uint256 stakeWei);
    event Stolen(address indexed thief, address indexed counterparty, uint256 paidWei);

    /// @notice Emitted when an op is appended to the unforged queue.
    event TxQueued(uint64 indexed batchId, uint32 indexed txId, uint8 op, uint32 ilo, uint32 ihi, uint32 ts);

    event BatchSubmitted(
        uint64 indexed batchId, uint32 n, uint32 startTxId, bytes32 storageHash, bytes32 newGraphRoot, bytes txData
    );

    event Withdrawal(address indexed account, uint256 amount);

    // =============================================================
    // Deposits
    // =============================================================
    function deposit() external payable nonReentrant {
        if (msg.value == 0) revert BadValue();
        balances[msg.sender] += msg.value;
        emit Deposit(msg.sender, msg.value);
    }

    /// @dev Pays `required` using (balances[msg.sender] + msg.value). Any msg.value surplus is credited to balance.
    function _takeFunds(uint256 required) internal {
        uint256 b = balances[msg.sender];

        if (b >= required) {
            unchecked {
                balances[msg.sender] = b - required;
            }
            if (msg.value != 0) balances[msg.sender] += msg.value;
            return;
        }

        uint256 shortfall = required - b;
        if (msg.value < shortfall) revert BadValue();

        balances[msg.sender] = msg.value - shortfall;
    }

    // =============================================================
    // Handshake
    // =============================================================
    function vouch(address counterparty) external payable nonReentrant {
        if (counterparty == address(0)) revert ZeroAddress();
        if (counterparty == msg.sender) revert Self();

        (address lo, address hi) = _order(msg.sender, counterparty);

        // Gate vouch: don't start handshake if already linked in truth-state.
        if (linked[lo][hi]) revert LinkAlreadyExists();

        PairPacked storage p = pairs[lo][hi];
        if (p.stakeWeiLocked != 0) revert PairAlreadyActive();

        uint256 s = stakeWei;
        uint32 d = windowDuration;
        if (s == 0 || d == 0) revert BadValue();

        registry.ensureMyIdx();
        _takeFunds(s);

        p.stakeWeiLocked = uint128(s);
        p.durationLocked = d;

        if (msg.sender == lo) p.loFunded = true;
        else p.hiFunded = true;

        emit Vouched(msg.sender, counterparty, lo, hi, s, d);
    }

    function revouch(address counterparty) external payable nonReentrant {
        if (counterparty == address(0)) revert ZeroAddress();
        if (counterparty == msg.sender) revert Self();

        (address lo, address hi) = _order(msg.sender, counterparty);
        PairPacked storage p = pairs[lo][hi];

        if (p.stakeWeiLocked == 0) revert PairNotActive();
        if (p.windowStart != 0) revert WindowAlreadyOpen();

        if (msg.sender == lo) {
            if (p.loFunded) revert AlreadyFunded();
        } else {
            if (p.hiFunded) revert AlreadyFunded();
        }

        uint256 s = uint256(p.stakeWeiLocked);

        registry.ensureMyIdx();
        _takeFunds(s);

        if (msg.sender == lo) p.loFunded = true;
        else p.hiFunded = true;

        emit Vouched(msg.sender, counterparty, lo, hi, s, p.durationLocked);

        if (p.loFunded && p.hiFunded) {
            uint64 start = uint64(block.timestamp);
            uint64 end = start + uint64(p.durationLocked);
            p.windowStart = start;

            emit WindowOpened(lo, hi, start, end, s, p.durationLocked);
        }
    }

    function cancelVouch(address counterparty) external nonReentrant {
        if (counterparty == address(0)) revert ZeroAddress();
        if (counterparty == msg.sender) revert Self();

        (address lo, address hi) = _order(msg.sender, counterparty);
        PairPacked storage p = pairs[lo][hi];

        if (p.stakeWeiLocked == 0) revert PairNotActive();
        if (p.windowStart != 0) revert WindowAlreadyOpen();

        bool callerIsLo = (msg.sender == lo);
        if (callerIsLo) {
            if (!(p.loFunded && !p.hiFunded)) revert NotSoleFunder();
        } else {
            if (!(p.hiFunded && !p.loFunded)) revert NotSoleFunder();
        }

        uint256 s = uint256(p.stakeWeiLocked);

        delete pairs[lo][hi];
        balances[msg.sender] += s;

        emit VouchCancelled(msg.sender, counterparty, s);
    }

    function steal(address counterparty) external nonReentrant {
        if (counterparty == address(0)) revert ZeroAddress();
        if (counterparty == msg.sender) revert Self();

        (address lo, address hi) = _order(msg.sender, counterparty);
        _requireParticipant(msg.sender, lo, hi);

        PairPacked storage p = pairs[lo][hi];
        if (p.stakeWeiLocked == 0) revert PairNotActive();
        if (p.windowStart == 0) revert WindowNotOpen();
        if (!(p.loFunded && p.hiFunded)) revert NotBothFunded();

        uint64 end = p.windowStart + uint64(p.durationLocked);
        if (block.timestamp > end) revert PastWindow();

        uint256 s = uint256(p.stakeWeiLocked);

        delete pairs[lo][hi];
        balances[msg.sender] += (s * 2);

        emit Stolen(msg.sender, counterparty, s * 2);
    }

    function closeWithoutSteal(address counterparty) external nonReentrant {
        if (counterparty == address(0)) revert ZeroAddress();
        if (counterparty == msg.sender) revert Self();

        (address lo, address hi) = _order(msg.sender, counterparty);
        _requireParticipant(msg.sender, lo, hi);

        PairPacked storage p = pairs[lo][hi];
        if (p.stakeWeiLocked == 0) revert PairNotActive();
        if (p.windowStart == 0) revert WindowNotOpen();
        if (!(p.loFunded && p.hiFunded)) revert NotBothFunded();

        uint64 end = p.windowStart + uint64(p.durationLocked);
        if (block.timestamp > end) revert PastWindow();

        uint256 s = uint256(p.stakeWeiLocked);

        delete pairs[lo][hi];
        balances[lo] += s;
        balances[hi] += s;

        emit ClosedNoLink(msg.sender, counterparty, s);
    }

    function revouchAndSteal(address counterparty) external payable nonReentrant {
        if (counterparty == address(0)) revert ZeroAddress();
        if (counterparty == msg.sender) revert Self();

        (address lo, address hi) = _order(msg.sender, counterparty);
        PairPacked storage p = pairs[lo][hi];

        if (p.stakeWeiLocked == 0) revert PairNotActive();
        if (p.windowStart != 0) revert WindowAlreadyOpen();

        bool callerIsLo = (msg.sender == lo);

        // Must be the unfunded side; counterparty must already be funded.
        if (callerIsLo) {
            if (p.loFunded) revert AlreadyFunded();
            if (!p.hiFunded) revert NotCounterpartyFunded();
        } else {
            if (p.hiFunded) revert AlreadyFunded();
            if (!p.loFunded) revert NotCounterpartyFunded();
        }

        uint256 s = uint256(p.stakeWeiLocked);

        registry.ensureMyIdx();
        _takeFunds(s);

        if (callerIsLo) p.loFunded = true;
        else p.hiFunded = true;

        uint64 start = uint64(block.timestamp);
        uint64 end = start + uint64(p.durationLocked);
        p.windowStart = start;

        emit Vouched(msg.sender, counterparty, lo, hi, s, p.durationLocked);
        emit WindowOpened(lo, hi, start, end, s, p.durationLocked);

        delete pairs[lo][hi];
        balances[msg.sender] += (s * 2);

        emit Stolen(msg.sender, counterparty, s * 2);
    }

    /// @notice After window ends, refund both and enqueue an ADD op.
    /// @dev Truth-state updates immediately: linked[lo][hi] becomes true here.
    ///      latestGraphRoot catches up later via batching/proofs.
    function finalize(address a, address b) external payable nonReentrant {
        if (a == address(0) || b == address(0)) revert ZeroAddress();
        if (a == b) revert Self();

        (address lo, address hi) = _order(a, b);
        _requireParticipant(msg.sender, lo, hi);

        PairPacked storage p = pairs[lo][hi];
        if (p.stakeWeiLocked == 0) revert PairNotActive();
        if (p.windowStart == 0) revert WindowNotOpen();
        if (!(p.loFunded && p.hiFunded)) revert NotBothFunded();

        uint64 end = p.windowStart + uint64(p.durationLocked);
        if (block.timestamp <= end) revert WindowStillOpen();

        if (linked[lo][hi]) revert LinkAlreadyExists();

        // indices must exist
        uint32 ia = registry.accountIdx(lo);
        uint32 ib = registry.accountIdx(hi);
        if (ia == 0 || ib == 0) revert MissingIdx();
        (uint32 ilo, uint32 ihi) = ia < ib ? (ia, ib) : (ib, ia);

        if (degree[lo] >= MAX_DEGREE || degree[hi] >= MAX_DEGREE) revert BadValue(); // or NodeFull()

        if (msg.value != TX_FEE_WEI) revert BadValue();
        feePool += TX_FEE_WEI;

        uint256 s = uint256(p.stakeWeiLocked);

        delete pairs[lo][hi];
        balances[lo] += s;
        balances[hi] += s;

        // Truth-state update
        linked[lo][hi] = true;
        unchecked {
            degree[lo] += 1;
            degree[hi] += 1;
        }
        uint32 txId = nextTxId++;
        uint32 ts = uint32(block.timestamp);

        unforged[txId] = _packTx(ilo, ihi, OP_ADD);

        emit TxQueued(batchId, txId, OP_ADD, ilo, ihi, ts);
    }

    /// @notice Enqueue a REVOKE op. Gated to existing truth-state edge.
    /// @dev Truth-state updates immediately: linked[lo][hi] becomes false here.
    function revoke(address counterparty) external payable nonReentrant {
        if (counterparty == address(0)) revert ZeroAddress();
        if (counterparty == msg.sender) revert Self();

        (address lo, address hi) = _order(msg.sender, counterparty);

        // Gate revoke: only allow if edge currently exists in truth-state.
        if (!linked[lo][hi]) revert LinkDoesNotExist();

        uint32 ia = registry.accountIdx(msg.sender);
        uint32 ib = registry.accountIdx(counterparty);
        if (ia == 0 || ib == 0) revert MissingIdx();
        (uint32 ilo, uint32 ihi) = ia < ib ? (ia, ib) : (ib, ia);

        if (msg.value != TX_FEE_WEI) revert BadValue();
        feePool += TX_FEE_WEI;

        // Truth-state update
        linked[lo][hi] = false;

        // Optional sanity (should always hold if invariants are correct)
        if (degree[lo] == 0 || degree[hi] == 0) revert BadValue(); // or custom DegreeInvariant()

        // Degree update (authoritative)
        unchecked {
            degree[lo] -= 1;
            degree[hi] -= 1;
        }
        uint32 txId = nextTxId++;
        uint32 ts = uint32(block.timestamp);

        unforged[txId] = _packTx(ilo, ihi, OP_REVOKE);

        emit TxQueued(batchId, txId, OP_REVOKE, ilo, ihi, ts);
    }

    // =============================================================
    // Forging (root catch-up only; does NOT touch linked)
    // =============================================================
    function submitBatch(
        bytes32 newGraphRoot,
        uint32 n,
        uint256[2] calldata a,
        uint256[2][2] calldata b,
        uint256[2] calldata c
    ) external nonReentrant {
        if (n == 0 || n > MAX_BATCH) revert BadValue();

        uint32 start = lastForgedId + 1;
        uint32 endSnapshot = nextTxId - 1;
        if (endSnapshot < start) revert EmptyBatch();

        uint32 avail = endSnapshot - lastForgedId;
        if (n > avail) revert EmptyBatch();

        (bytes memory txDataFixed, bytes32 storageHash) = _buildTxDataFixedAndStorageHash(start, n);

        bytes32 pubInputsHash = sha256(abi.encodePacked(latestGraphRoot, newGraphRoot, batchId, start, n, storageHash));

        uint256[1] memory input;
        input[0] = _maskTo253(pubInputsHash);

        if (!verifier.verifyProof(a, b, c, input)) revert VerifyFail();

        latestGraphRoot = newGraphRoot;

        emit BatchSubmitted(batchId, n, start, storageHash, newGraphRoot, txDataFixed);

        _deleteForged(start, n);

        lastForgedId = lastForgedId + n;
        unchecked {
            batchId += 1;
        }

        uint256 reward = uint256(n) * TX_FEE_WEI;
        require(feePool >= reward, "FEEPOOL_LOW");
        unchecked {
            feePool -= reward;
        }
        balances[msg.sender] += reward;
    }

    function _maskTo253(bytes32 h) internal pure returns (uint256) {
        uint256 x = uint256(h);
        uint256 mask = (uint256(1) << 253) - 1;
        return x & mask;
    }

    function _buildTxDataFixedAndStorageHash(uint32 start, uint32 n)
        internal
        view
        returns (bytes memory txDataFixed, bytes32 storageHash)
    {
        // 9 bytes per tx, fixed MAX_BATCH slots
        txDataFixed = new bytes(uint256(MAX_BATCH) * 9);
        uint256 off = 0;

        for (uint32 i = 0; i < n; ++i) {
            uint128 w = unforged[start + i];
            (uint32 ilo, uint32 ihi, uint8 op) = _unpackTx(w);

            txDataFixed[off + 0] = bytes1(uint8(ilo >> 24));
            txDataFixed[off + 1] = bytes1(uint8(ilo >> 16));
            txDataFixed[off + 2] = bytes1(uint8(ilo >> 8));
            txDataFixed[off + 3] = bytes1(uint8(ilo));
            txDataFixed[off + 4] = bytes1(uint8(ihi >> 24));
            txDataFixed[off + 5] = bytes1(uint8(ihi >> 16));
            txDataFixed[off + 6] = bytes1(uint8(ihi >> 8));
            txDataFixed[off + 7] = bytes1(uint8(ihi));
            txDataFixed[off + 8] = bytes1(op);

            off += 9;
        }

        // Remaining bytes are already zero (NULL tx)
        storageHash = sha256(txDataFixed);
    }

    function _deleteForged(uint32 start, uint32 n) internal {
        for (uint32 i = 0; i < n; ++i) {
            delete unforged[start + i];
        }
    }

    // =============================================================
    // Withdrawals
    // =============================================================
    function withdraw(uint256 amount) external nonReentrant {
        uint256 b = balances[msg.sender];
        if (amount > b) revert InsufficientBalance();

        unchecked {
            balances[msg.sender] = b - amount;
        }

        (bool ok,) = payable(msg.sender).call{value: amount}("");
        if (!ok) revert SendFailed();

        emit Withdrawal(msg.sender, amount);
    }

    function withdrawAll() external nonReentrant {
        uint256 b = balances[msg.sender];
        if (b == 0) return;

        balances[msg.sender] = 0;

        (bool ok,) = payable(msg.sender).call{value: b}("");
        if (!ok) revert SendFailed();

        emit Withdrawal(msg.sender, b);
    }

    // =============================================================
    // Packing helpers
    // =============================================================
    function _packTx(uint32 ilo, uint32 ihi, uint8 op) internal pure returns (uint128 w) {
        // w = (ilo<<40) | (ihi<<8) | op
        w = (uint128(ilo) << 40) | (uint128(ihi) << 8) | uint128(op);
    }

    function _unpackTx(uint128 w) internal pure returns (uint32 ilo, uint32 ihi, uint8 op) {
        ilo = uint32(w >> 40);
        ihi = uint32(w >> 8);
        op = uint8(w);
    }

    // =============================================================
    // Helpers
    // =============================================================
    function _order(address x, address y) internal pure returns (address lo, address hi) {
        if (x < y) return (x, y);
        return (y, x);
    }

    function _requireParticipant(address caller, address lo, address hi) internal pure {
        if (caller != lo && caller != hi) revert NotParticipant();
    }

    // =============================================================
    // Read helpers (pending ops view)
    // =============================================================
    /// @notice Pending txs are [lastForgedId+1 .. nextTxId-1]
    function pendingOps() external view returns (uint32 startTxId, uint32 endTxId, uint32 count) {
        startTxId = lastForgedId + 1;
        endTxId = nextTxId - 1;
        if (endTxId < startTxId) return (startTxId, endTxId, 0);
        count = endTxId - lastForgedId;
    }

    /// @notice Useful "lag" metric: how many enqueued ops are not yet represented in latestGraphRoot
    function lag() external view returns (uint32 pending) {
        uint32 endTxId = nextTxId - 1;
        if (endTxId <= lastForgedId) return 0;
        return endTxId - lastForgedId;
    }

    /// @notice Read a queued tx by id.
    function getQueuedTx(uint32 txId) external view returns (uint32 ilo, uint32 ihi, uint8 op) {
        uint128 w = unforged[txId];
        (ilo, ihi, op) = _unpackTx(w);
    }

    /// @notice Fetch a slice of queued packed words (handy for offchain batch building).
    function getQueuedWords(uint32 startTxId, uint32 n) external view returns (uint128[] memory words) {
        words = new uint128[](n);
        for (uint32 i = 0; i < n; ++i) {
            words[i] = unforged[startTxId + i];
        }
    }

    // =============================================================
    // Existing views from earlier
    // =============================================================
    function windowEnd(address a, address b) external view returns (uint64 end, bool open) {
        if (a == address(0) || b == address(0) || a == b) return (0, false);
        (address lo, address hi) = _order(a, b);
        PairPacked storage p = pairs[lo][hi];
        if (p.windowStart == 0) return (0, false);
        end = p.windowStart + uint64(p.durationLocked);
        open = true;
    }

    function pairState(address a, address b)
        external
        view
        returns (
            address lo,
            address hi,
            uint256 stakeWeiLocked,
            uint32 durationLocked,
            bool loFunded,
            bool hiFunded,
            uint64 windowStart,
            uint64 windowEndT,
            bool windowOpen
        )
    {
        if (a == address(0) || b == address(0) || a == b) {
            return (address(0), address(0), 0, 0, false, false, 0, 0, false);
        }

        (lo, hi) = _order(a, b);
        PairPacked storage p = pairs[lo][hi];

        stakeWeiLocked = uint256(p.stakeWeiLocked);
        durationLocked = p.durationLocked;
        loFunded = p.loFunded;
        hiFunded = p.hiFunded;
        windowStart = p.windowStart;

        if (windowStart != 0) {
            windowEndT = windowStart + uint64(durationLocked);
            windowOpen = block.timestamp <= windowEndT;
        }
    }
}
