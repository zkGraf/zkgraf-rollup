// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IRegistry {
    function ensureMyIdx() external returns (uint32);
    function accountIdx(address a) external view returns (uint32);
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
    // Config
    // =============================================================
    IRegistry public immutable registry;
    IGroth16Verifier public immutable verifier;

    /// @dev Circuit max txs per batch (enforced on-chain)
    uint32 public constant MAX_BATCH = 100;

    /// @dev Exact ETH required to enqueue one tx (finalize or revoke)
    uint256 public constant TX_FEE = 0.00001 ether; // choose value
    uint256 public feePool;

    constructor(address registry_, address verifier_) {
        require(registry_ != address(0), "REGISTRY_ZERO");
        require(verifier_ != address(0), "VERIFIER_ZERO");
        registry = IRegistry(registry_);
        verifier = IGroth16Verifier(verifier_);
    }

    // =============================================================
    // Pair state (handshake)
    // =============================================================
    struct PairPacked {
        uint64 windowStart; // 0 => not open
        bool loFunded;
        bool hiFunded;
        uint8 stakeIndex; // 0 => inactive
        uint8 durationIndex; // window preset index
    }

    mapping(address => mapping(address => PairPacked)) public pairs; //[lo][hi]

    // =============================================================
    // Pull payments
    // =============================================================
    mapping(address => uint256) public balances;

    // =============================================================
    // Unforged queue (operation stream)
    // =============================================================
    // Record layout (15 bytes / 120 bits):
    //   ilo(4) | ihi(4) | stakeIndex(1) | durationIndex(1) | op(1) | ts(4)
    //
    // Packed into uint128:
    //   w = (ilo<<88) | (ihi<<56) | (stake<<48) | (dur<<40) | (op<<32) | ts
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

    error BadValue();
    error BadStakeIndex();
    error BadWindowIndex();
    error MissingIdx();

    error InsufficientBalance();
    error SendFailed();

    error EmptyBatch();
    error VerifyFail();
    error NotCounterpartyFunded();

    // =============================================================
    // Events
    // =============================================================
    event Deposit(address indexed from, uint256 amount);

    event Vouched(
        address indexed funder,
        address indexed counterparty,
        address lo,
        address hi,
        uint8 stakeIndex,
        uint8 durationIndex,
        uint256 stakeWei
    );

    event WindowOpened(
        address indexed lo,
        address indexed hi,
        uint64 windowStart,
        uint64 windowEnd,
        uint8 stakeIndex,
        uint8 durationIndex
    );

    event VouchCancelled(address indexed caller, address indexed counterparty, uint256 creditedWei);
    event ClosedNoLink(address indexed caller, address indexed counterparty, uint256 stakeWei);
    event Stolen(address indexed thief, address indexed counterparty, uint256 paidWei);

    /// @notice Emitted when an op is appended to the unforged queue.
    /// @dev Circuit should treat duplicate ADD and REVOKE-missing as NO-OP (Option 1).
    event TxQueued(
        uint64 indexed batchId,
        uint32 indexed txId,
        uint8 op,
        uint32 ilo,
        uint32 ihi,
        uint8 stakeIndex,
        uint8 durationIndex,
        uint32 ts
    );

    event BatchSubmitted(
        uint64 indexed batchId, uint32 n, uint32 startTxId, bytes32 storageHash, bytes32 newGraphRoot, bytes txData
    );

    event Withdrawal(address indexed account, uint256 amount);
    event FeePaid(address indexed payer, uint32 indexed txId, uint256 amount);
    event BatcherPaid(address indexed batcher, uint64 indexed batchId, uint32 n, uint256 amount);

    // =============================================================
    // Deposits (optional)
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
    // Handshake: vouch / revouch / cancel / steal / close / finalize
    // =============================================================
    function vouch(address counterparty, uint8 stakeIndex, uint8 durationIndex) external payable nonReentrant {
        if (counterparty == address(0)) revert ZeroAddress();
        if (counterparty == msg.sender) revert Self();

        (address lo, address hi) = _order(msg.sender, counterparty);
        PairPacked storage p = pairs[lo][hi];

        if (p.stakeIndex != 0) revert PairAlreadyActive();
        if (stakeIndex == 0) revert BadStakeIndex();
        if (durationIndex == 0) revert BadWindowIndex();

        uint256 stakeWei = getStakePreset(stakeIndex);
        getWindowPreset(durationIndex); // validates

        // register AFTER checks
        registry.ensureMyIdx();

        _takeFunds(stakeWei);

        p.stakeIndex = stakeIndex;
        p.durationIndex = durationIndex;

        if (msg.sender == lo) p.loFunded = true;
        else p.hiFunded = true;

        emit Vouched(msg.sender, counterparty, lo, hi, stakeIndex, durationIndex, stakeWei);
    }

    function revouch(address counterparty) external payable nonReentrant {
        if (counterparty == address(0)) revert ZeroAddress();
        if (counterparty == msg.sender) revert Self();

        (address lo, address hi) = _order(msg.sender, counterparty);
        PairPacked storage p = pairs[lo][hi];

        if (p.stakeIndex == 0) revert PairNotActive();
        if (p.windowStart != 0) revert WindowAlreadyOpen();

        if (msg.sender == lo) {
            if (p.loFunded) revert AlreadyFunded();
        } else {
            if (p.hiFunded) revert AlreadyFunded();
        }

        uint256 stakeWei = getStakePreset(p.stakeIndex);

        registry.ensureMyIdx();
        _takeFunds(stakeWei);

        if (msg.sender == lo) p.loFunded = true;
        else p.hiFunded = true;

        emit Vouched(msg.sender, counterparty, lo, hi, p.stakeIndex, p.durationIndex, stakeWei);

        if (p.loFunded && p.hiFunded) {
            uint64 start = uint64(block.timestamp);
            uint64 end = start + uint64(getWindowPreset(p.durationIndex));
            p.windowStart = start;

            emit WindowOpened(lo, hi, start, end, p.stakeIndex, p.durationIndex);
        }
    }

    function cancelVouch(address counterparty) external nonReentrant {
        if (counterparty == address(0)) revert ZeroAddress();
        if (counterparty == msg.sender) revert Self();

        (address lo, address hi) = _order(msg.sender, counterparty);
        PairPacked storage p = pairs[lo][hi];

        if (p.stakeIndex == 0) revert PairNotActive();
        if (p.windowStart != 0) revert WindowAlreadyOpen();

        bool callerIsLo = (msg.sender == lo);
        if (callerIsLo) {
            if (!(p.loFunded && !p.hiFunded)) revert NotSoleFunder();
        } else {
            if (!(p.hiFunded && !p.loFunded)) revert NotSoleFunder();
        }

        uint256 stakeWei = getStakePreset(p.stakeIndex);

        delete pairs[lo][hi];
        balances[msg.sender] += stakeWei;

        emit VouchCancelled(msg.sender, counterparty, stakeWei);
    }

    function steal(address counterparty) external nonReentrant {
        if (counterparty == address(0)) revert ZeroAddress();
        if (counterparty == msg.sender) revert Self();

        (address lo, address hi) = _order(msg.sender, counterparty);
        _requireParticipant(msg.sender, lo, hi);

        PairPacked storage p = pairs[lo][hi];
        if (p.stakeIndex == 0) revert PairNotActive();
        if (p.windowStart == 0) revert WindowNotOpen();
        if (!(p.loFunded && p.hiFunded)) revert NotBothFunded();

        uint64 end = p.windowStart + uint64(getWindowPreset(p.durationIndex));
        if (block.timestamp > end) revert PastWindow();

        uint256 stakeWei = getStakePreset(p.stakeIndex);

        delete pairs[lo][hi];
        balances[msg.sender] += (stakeWei * 2);

        emit Stolen(msg.sender, counterparty, stakeWei * 2);
    }

    function closeWithoutSteal(address counterparty) external nonReentrant {
        if (counterparty == address(0)) revert ZeroAddress();
        if (counterparty == msg.sender) revert Self();

        (address lo, address hi) = _order(msg.sender, counterparty);
        _requireParticipant(msg.sender, lo, hi);

        PairPacked storage p = pairs[lo][hi];
        if (p.stakeIndex == 0) revert PairNotActive();
        if (p.windowStart == 0) revert WindowNotOpen();
        if (!(p.loFunded && p.hiFunded)) revert NotBothFunded();

        uint64 end = p.windowStart + uint64(getWindowPreset(p.durationIndex));
        if (block.timestamp > end) revert PastWindow();

        uint256 stakeWei = getStakePreset(p.stakeIndex);

        delete pairs[lo][hi];
        balances[lo] += stakeWei;
        balances[hi] += stakeWei;

        emit ClosedNoLink(msg.sender, counterparty, stakeWei);
    }

    function revouchAndSteal(address counterparty) external payable nonReentrant {
        if (counterparty == address(0)) revert ZeroAddress();
        if (counterparty == msg.sender) revert Self();

        (address lo, address hi) = _order(msg.sender, counterparty);
        PairPacked storage p = pairs[lo][hi];

        if (p.stakeIndex == 0) revert PairNotActive();
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

        uint256 stakeWei = getStakePreset(p.stakeIndex);

        // Register + pay stake (same as revouch)
        registry.ensureMyIdx();
        _takeFunds(stakeWei);

        // Mark funded and open window (optional, but keeps semantics consistent)
        if (callerIsLo) p.loFunded = true;
        else p.hiFunded = true;

        uint64 start = uint64(block.timestamp);
        uint64 end = start + uint64(getWindowPreset(p.durationIndex));
        p.windowStart = start;

        emit Vouched(msg.sender, counterparty, lo, hi, p.stakeIndex, p.durationIndex, stakeWei);
        emit WindowOpened(lo, hi, start, end, p.stakeIndex, p.durationIndex);

        // Immediately punish: delete pair and pay caller both stakes
        delete pairs[lo][hi];
        balances[msg.sender] += (stakeWei * 2);

        emit Stolen(msg.sender, counterparty, stakeWei * 2);
    }

    /// @notice After window ends, refund both and enqueue an ADD op.
    /// @dev Uniqueness is enforced in-circuit via NO-OP on duplicate ADD.
    function finalize(address a, address b) external payable nonReentrant {
        if (a == address(0) || b == address(0)) revert ZeroAddress();
        if (a == b) revert Self();

        (address lo, address hi) = _order(a, b);
        _requireParticipant(msg.sender, lo, hi);

        PairPacked storage p = pairs[lo][hi];
        if (p.stakeIndex == 0) revert PairNotActive();
        if (p.windowStart == 0) revert WindowNotOpen();
        if (!(p.loFunded && p.hiFunded)) revert NotBothFunded();

        uint64 end = p.windowStart + uint64(getWindowPreset(p.durationIndex));
        if (block.timestamp <= end) revert WindowStillOpen();

        // IDs must already exist (each side self-registered in vouch/revouch).
        uint32 ia = registry.accountIdx(lo);
        uint32 ib = registry.accountIdx(hi);
        if (ia == 0 || ib == 0) revert MissingIdx();
        (uint32 ilo, uint32 ihi) = ia < ib ? (ia, ib) : (ib, ia);

        uint256 stakeWei = getStakePreset(p.stakeIndex);
        uint8 stakeIdx = p.stakeIndex;
        uint8 durIdx = p.durationIndex;

        if (msg.value != TX_FEE) revert BadValue();
        feePool += TX_FEE;

        delete pairs[lo][hi];

        balances[lo] += stakeWei;
        balances[hi] += stakeWei;

        uint32 txId = nextTxId++;
        uint32 ts = uint32(block.timestamp);

        unforged[txId] = _packTx(ilo, ihi, stakeIdx, durIdx, OP_ADD, ts);

        emit TxQueued(batchId, txId, OP_ADD, ilo, ihi, stakeIdx, durIdx, ts);
    }

    /// @notice Enqueue a REVOKE op. Callable only by either endpoint (caller + counterparty).
    /// @dev Circuit should treat REVOKE on absent edge as NO-OP to avoid queue DoS.
    function revoke(address counterparty) external payable nonReentrant {
        if (counterparty == address(0)) revert ZeroAddress();
        if (counterparty == msg.sender) revert Self();

        // Both must have ids.
        uint32 ia = registry.accountIdx(msg.sender);
        uint32 ib = registry.accountIdx(counterparty);
        if (ia == 0 || ib == 0) revert MissingIdx();
        (uint32 ilo, uint32 ihi) = ia < ib ? (ia, ib) : (ib, ia);

        if (msg.value != TX_FEE) revert BadValue();
        feePool += TX_FEE;

        uint32 txId = nextTxId++;
        uint32 ts = uint32(block.timestamp);

        unforged[txId] = _packTx(ilo, ihi, 0, 0, OP_REVOKE, ts);

        emit TxQueued(batchId, txId, OP_REVOKE, ilo, ihi, 0, 0, ts);
    }

    // =============================================================
    // Forging
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

        (bytes memory txData, bytes32 storageHash) = _buildTxDataAndStorageHash(start, n);

        // Commitment to what the circuit should verify
        bytes32 pubInputsHash = sha256(abi.encodePacked(latestGraphRoot, newGraphRoot, batchId, n, storageHash));

        uint256[1] memory input;
        input[0] = _maskTo253(pubInputsHash);

        if (!verifier.verifyProof(a, b, c, input)) revert VerifyFail();

        latestGraphRoot = newGraphRoot;

        emit BatchSubmitted(batchId, n, start, storageHash, newGraphRoot, txData);

        _deleteForged(start, n);

        lastForgedId = lastForgedId + n;
        unchecked {
            batchId += 1;
        }

        uint256 reward = uint256(n) * TX_FEE;
        require(feePool >= reward, "FEEPOOL_LOW");
        unchecked {
            feePool -= reward;
        }
        balances[msg.sender] += reward;
    }

    function _maskTo253(bytes32 h) internal pure returns (uint256) {
        // Keep low 253 bits so value is guaranteed < BN254 scalar field modulus.
        uint256 x = uint256(h);
        uint256 mask = (uint256(1) << 253) - 1;
        return x & mask;
    }

    function _buildTxDataAndStorageHash(uint32 start, uint32 n)
        internal
        view
        returns (bytes memory txData, bytes32 storageHash)
    {
        // 15 bytes per tx
        txData = new bytes(uint256(n) * 15);
        uint256 off = 0;

        for (uint32 i = 0; i < n; ++i) {
            uint128 w = unforged[start + i];
            (uint32 ilo, uint32 ihi, uint8 stakeIndex, uint8 durationIndex, uint8 op, uint32 ts) = _unpackTx(w);

            // ilo
            txData[off + 0] = bytes1(uint8(ilo >> 24));
            txData[off + 1] = bytes1(uint8(ilo >> 16));
            txData[off + 2] = bytes1(uint8(ilo >> 8));
            txData[off + 3] = bytes1(uint8(ilo));
            // ihi
            txData[off + 4] = bytes1(uint8(ihi >> 24));
            txData[off + 5] = bytes1(uint8(ihi >> 16));
            txData[off + 6] = bytes1(uint8(ihi >> 8));
            txData[off + 7] = bytes1(uint8(ihi));
            // stake/dur/op
            txData[off + 8] = bytes1(stakeIndex);
            txData[off + 9] = bytes1(durationIndex);
            txData[off + 10] = bytes1(op);
            // ts
            txData[off + 11] = bytes1(uint8(ts >> 24));
            txData[off + 12] = bytes1(uint8(ts >> 16));
            txData[off + 13] = bytes1(uint8(ts >> 8));
            txData[off + 14] = bytes1(uint8(ts));

            off += 15;
        }

        storageHash = sha256(abi.encodePacked(batchId, start, n, txData));
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
    // Packing helpers (120 bits used in uint128)
    // =============================================================
    function _packTx(uint32 ilo, uint32 ihi, uint8 stakeIndex, uint8 durationIndex, uint8 op, uint32 ts)
        internal
        pure
        returns (uint128 w)
    {
        w = (uint128(ilo) << 88) | (uint128(ihi) << 56) | (uint128(stakeIndex) << 48) | (uint128(durationIndex) << 40)
            | (uint128(op) << 32) | uint128(ts);
    }

    function _unpackTx(uint128 w)
        internal
        pure
        returns (uint32 ilo, uint32 ihi, uint8 stakeIndex, uint8 durationIndex, uint8 op, uint32 ts)
    {
        ilo = uint32(w >> 88);
        ihi = uint32(w >> 56);
        stakeIndex = uint8(w >> 48);
        durationIndex = uint8(w >> 40);
        op = uint8(w >> 32);
        ts = uint32(w);
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
    // Presets
    // =============================================================
    function getStakePreset(uint8 index) public pure returns (uint256) {
        if (index == 1) return 0.003 ether;
        if (index == 2) return 0.007 ether;
        revert BadStakeIndex();
    }

    function getWindowPreset(uint8 index) public pure returns (uint32) {
        if (index == 1) return 3 days;
        if (index == 2) return 7 days;
        if (index == 3) return 14 days;
        revert BadWindowIndex();
    }

    // =============================================================
    // Views
    // =============================================================
    function windowEnd(address a, address b) external view returns (uint64 end, bool open) {
        if (a == address(0) || b == address(0) || a == b) return (0, false);
        (address lo, address hi) = _order(a, b);
        PairPacked storage p = pairs[lo][hi];
        if (p.windowStart == 0) return (0, false);
        end = p.windowStart + uint64(getWindowPreset(p.durationIndex));
        open = true;
    }

    function pairState(address a, address b)
        external
        view
        returns (
            address lo,
            address hi,
            uint8 stakeIndex,
            uint8 durationIndex,
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

        stakeIndex = p.stakeIndex;
        durationIndex = p.durationIndex;
        loFunded = p.loFunded;
        hiFunded = p.hiFunded;
        windowStart = p.windowStart;

        if (windowStart != 0) {
            windowEndT = windowStart + uint64(getWindowPreset(durationIndex));
            windowOpen = block.timestamp <= windowEndT;
        }
    }
}
