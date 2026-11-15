// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*
 * Validator Tycoon — community staking pool (DRAFT, UNAUDITED, TESTNET ONLY)
 *
 * Lets players pool any amount of PLS. Every 32M PLS the operator launches a real PulseChain validator whose
 * withdrawal credentials point back at THIS contract, so principal and rewards can only ever return here.
 * Rewards are shared pro-rata by pool shares; the operator takes a low fee (default 3%, hard cap 5%) on rewards only.
 *
 * Deliberately simple and conservative:
 *   - non-transferable shares (no liquid token, no DeFi composability risk)
 *   - deposits can be paused, withdrawals never can
 *   - fee can be lowered instantly; raises wait 7 days and can never exceed 5%
 *   - FIFO withdrawal queue: once validators exit and PLS comes back, anyone can pay out the queue in order
 *   - refuses to deploy on PulseChain mainnet (chain 369) until audited
 *
 * Trust assumptions (read docs/STAKING_POOL.md): the operator runs the validator clients, must report exits and
 * any slashing loss honestly, and must point execution-layer fees (fee recipient) at this contract.
 */
interface IDepositContract {
    function deposit(bytes calldata pubkey, bytes calldata withdrawal_credentials, bytes calldata signature, bytes32 deposit_data_root) external payable;
}

contract TycoonStakingPool {
    uint256 public constant VALIDATOR_DEPOSIT = 32_000_000 ether;   // 32M PLS
    uint256 public constant MAX_FEE_BPS = 500;                       // 5%
    uint256 public constant FEE_DELAY = 7 days;
    uint256 public constant MIN_DEPOSIT = 1 ether;                   // 1 PLS

    IDepositContract public immutable depositContract;
    address public operator;
    address public pendingOperator;
    bool public depositsPaused;

    uint256 public feeBps;
    uint256 public pendingFeeBps;
    uint256 public pendingFeeAt;

    uint256 public totalShares;
    mapping(address => uint256) public sharesOf;

    uint256 public activeValidators;       // funded and not reported as exited
    uint256 public expectedPrincipal;      // principal of reported exits that has not arrived yet
    uint256 public trackedBalance;         // part of this contract's balance already accounted for
    uint256 public operatorFees;           // earmarked for the operator, not pool assets
    uint256 public reservedForClaims;      // owed to the withdrawal queue, not pool assets

    struct Claim { address owner; uint128 amount; bool paid; }
    Claim[] public claims;
    uint256 public nextClaim;

    uint256 private locked = 1;

    event Deposited(address indexed who, uint256 amount, uint256 shares);
    event WithdrawalRequested(uint256 indexed id, address indexed who, uint256 shares, uint256 amount);
    event ClaimPaid(uint256 indexed id, address indexed who, uint256 amount);
    event ValidatorFunded(bytes pubkey, uint256 activeValidators);
    event ExitReported(uint256 count, uint256 activeValidators);
    event LossReported(uint256 amount);
    event Harvested(uint256 rewards, uint256 fee);
    event FeeScheduled(uint256 bps, uint256 at);
    event FeeChanged(uint256 bps);
    event OperatorChanged(address operator);
    event DepositsPaused(bool paused);

    modifier onlyOperator() { require(msg.sender == operator, "operator only"); _; }
    modifier nonReentrant() { require(locked == 1, "reentrant"); locked = 2; _; locked = 1; }

    constructor(address depositContract_, address operator_, uint256 feeBps_) {
        require(block.chainid != 369, "unaudited: testnet only");
        require(depositContract_ != address(0) && operator_ != address(0), "zero address");
        require(feeBps_ <= MAX_FEE_BPS, "fee too high");
        depositContract = IDepositContract(depositContract_);
        operator = operator_;
        feeBps = feeBps_;
    }

    /// @notice Rewards (consensus withdrawals and execution fees) arrive as plain transfers.
    receive() external payable {}

    // ---------------------------------------------------------------- views
    /// @notice Pooled PLS sitting in the contract that is free to stake (not owed to the operator or the queue).
    function cash() public view returns (uint256) {
        uint256 owed = operatorFees + reservedForClaims;
        return trackedBalance > owed ? trackedBalance - owed : 0;
    }
    /// @notice Everything that belongs to current share holders: cash, staked principal, principal on its way back.
    ///         Queued withdrawals may exceed cash while PLS is still validating; they are backed by staked principal.
    function totalAssets() public view returns (uint256) {
        uint256 gross = trackedBalance + activeValidators * VALIDATOR_DEPOSIT + expectedPrincipal;
        uint256 owed = operatorFees + reservedForClaims;
        return gross > owed ? gross - owed : 0;
    }
    function assetsOf(address who) external view returns (uint256) {
        return totalShares == 0 ? 0 : sharesOf[who] * totalAssets() / totalShares;
    }
    function withdrawalCredentials() public view returns (bytes memory) {
        return abi.encodePacked(bytes1(0x01), bytes11(0), address(this));
    }
    function claimsLength() external view returns (uint256) { return claims.length; }

    // ---------------------------------------------------------------- accounting
    /// @dev Counts PLS that arrived since the last call. Returning principal of reported exits is not a reward.
    function _harvest(uint256 exclude) internal {
        uint256 bal = address(this).balance - exclude;
        if (bal <= trackedBalance) return;
        uint256 incoming = bal - trackedBalance;
        uint256 principal = incoming < expectedPrincipal ? incoming : expectedPrincipal;
        expectedPrincipal -= principal;
        uint256 rewards = incoming - principal;
        uint256 fee = rewards * feeBps / 10_000;
        operatorFees += fee;
        trackedBalance = bal;
        if (rewards > 0) emit Harvested(rewards, fee);
    }
    function harvest() external nonReentrant { _harvest(0); }

    // ---------------------------------------------------------------- stakers
    function deposit() external payable nonReentrant returns (uint256 minted) {
        require(!depositsPaused, "deposits paused");
        require(msg.value >= MIN_DEPOSIT, "below minimum");
        _harvest(msg.value);
        uint256 assets = totalAssets();
        minted = (totalShares == 0 || assets == 0) ? msg.value : msg.value * totalShares / assets;
        require(minted > 0, "zero shares");
        totalShares += minted;
        sharesOf[msg.sender] += minted;
        trackedBalance += msg.value;
        emit Deposited(msg.sender, msg.value, minted);
    }

    /// @notice Burns shares at today's value and joins the FIFO queue. Paid out as cash becomes available.
    function requestWithdrawal(uint256 shares) external nonReentrant returns (uint256 id) {
        require(shares > 0 && shares <= sharesOf[msg.sender], "bad shares");
        _harvest(0);
        uint256 amount = shares * totalAssets() / totalShares;
        require(amount > 0 && amount <= type(uint128).max, "bad amount");
        sharesOf[msg.sender] -= shares;
        totalShares -= shares;
        reservedForClaims += amount;
        id = claims.length;
        claims.push(Claim(msg.sender, uint128(amount), false));
        emit WithdrawalRequested(id, msg.sender, shares, amount);
        _payQueue(8);
    }

    /// @notice Anyone can push queued withdrawals out once PLS is back in the pool.
    function payQueue(uint256 max) external nonReentrant { _harvest(0); _payQueue(max); }

    function _payQueue(uint256 max) internal {
        for (uint256 n = 0; n < max && nextClaim < claims.length; n++) {
            Claim storage c = claims[nextClaim];
            uint256 available = trackedBalance - operatorFees;   // reserved claims are paid from here, in order
            if (available < c.amount) return;
            c.paid = true;
            nextClaim++;
            reservedForClaims -= c.amount;
            trackedBalance -= c.amount;
            (bool ok, ) = c.owner.call{value: c.amount}("");
            if (!ok) {   // a contract that refuses PLS doesn't block the queue: its claim stays reserved for manual retry
                c.paid = false;
                reservedForClaims += c.amount;
                trackedBalance += c.amount;
                failed.push(nextClaim - 1);
            } else emit ClaimPaid(nextClaim - 1, c.owner, c.amount);
        }
    }
    uint256[] public failed;
    function retryFailed(uint256 i) external nonReentrant {
        uint256 id = failed[i]; Claim storage c = claims[id];
        require(!c.paid && msg.sender == c.owner, "not yours");
        require(trackedBalance - operatorFees >= c.amount, "no cash");
        c.paid = true; reservedForClaims -= c.amount; trackedBalance -= c.amount;
        failed[i] = failed[failed.length - 1]; failed.pop();
        (bool ok, ) = c.owner.call{value: c.amount}(""); require(ok, "send failed");
        emit ClaimPaid(id, c.owner, c.amount);
    }

    // ---------------------------------------------------------------- operator
    /// @notice Launch one validator from pooled cash. Withdrawal credentials are forced to this contract.
    function stake(bytes calldata pubkey, bytes calldata signature, bytes32 depositDataRoot) external onlyOperator nonReentrant {
        _harvest(0);
        require(cash() >= VALIDATOR_DEPOSIT, "not enough pooled PLS");
        trackedBalance -= VALIDATOR_DEPOSIT;
        activeValidators += 1;
        depositContract.deposit{value: VALIDATOR_DEPOSIT}(pubkey, withdrawalCredentials(), signature, depositDataRoot);
        emit ValidatorFunded(pubkey, activeValidators);
    }

    /// @notice Call when validators have been voluntarily exited; their 32M principal is then expected back.
    function reportExit(uint256 count) external onlyOperator nonReentrant {
        require(count > 0 && count <= activeValidators, "bad count");
        _harvest(0);
        activeValidators -= count;
        expectedPrincipal += count * VALIDATOR_DEPOSIT;
        emit ExitReported(count, activeValidators);
    }

    /// @notice Call if exited principal came back short (e.g. slashing). Lowers pool assets honestly for everyone.
    function reportLoss(uint256 amount) external onlyOperator nonReentrant {
        require(amount <= expectedPrincipal, "too much");
        expectedPrincipal -= amount;
        emit LossReported(amount);
    }

    function withdrawFees(address to) external onlyOperator nonReentrant {
        _harvest(0);
        uint256 amt = operatorFees;
        operatorFees = 0; trackedBalance -= amt;
        (bool ok, ) = to.call{value: amt}(""); require(ok, "send failed");
    }

    function setDepositsPaused(bool p) external onlyOperator { depositsPaused = p; emit DepositsPaused(p); }

    function scheduleFee(uint256 bps) external onlyOperator {
        require(bps <= MAX_FEE_BPS, "fee too high");
        if (bps <= feeBps) { _harvest(0); feeBps = bps; pendingFeeAt = 0; emit FeeChanged(bps); return; }
        pendingFeeBps = bps; pendingFeeAt = block.timestamp + FEE_DELAY; emit FeeScheduled(bps, pendingFeeAt);
    }
    function applyFee() external {
        require(pendingFeeAt != 0 && block.timestamp >= pendingFeeAt, "not yet");
        _harvest(0); feeBps = pendingFeeBps; pendingFeeAt = 0; emit FeeChanged(feeBps);
    }

    function transferOperator(address next) external onlyOperator { pendingOperator = next; }
    function acceptOperator() external { require(msg.sender == pendingOperator, "not pending"); operator = msg.sender; pendingOperator = address(0); emit OperatorChanged(msg.sender); }
}
