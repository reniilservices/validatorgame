// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title Validator Tycoon — Season Prize Pool
/// @notice Holds a stablecoin (e.g. bridged USDC/DAI on PulseChain) funded from game revenue and sponsors.
///         Entry to the game is free; prizes go to the top of each season's leaderboard.
///         After a season ends, the owner publishes a Merkle root of (season, player, amount) and
///         winners claim their own prize. Unclaimed funds can be swept after the claim window.
contract SeasonPrizePool is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable token;

    struct Season {
        bytes32 root;
        uint64 claimDeadline;
        uint256 total;     // total allocated in the Merkle tree
        uint256 claimed;
    }

    mapping(uint256 => Season) public seasons;
    mapping(uint256 => mapping(address => bool)) public hasClaimed;
    uint256 public committed; // allocated but not yet claimed or swept

    event Funded(address indexed from, uint256 amount);
    event SeasonPublished(uint256 indexed season, bytes32 root, uint256 total, uint64 deadline);
    event PrizeClaimed(uint256 indexed season, address indexed player, uint256 amount);
    event Swept(uint256 indexed season, uint256 amount);

    error SeasonExists();
    error InsufficientFunds();
    error NotPublished();
    error ClaimClosed();
    error ClaimStillOpen();
    error AlreadyClaimed();
    error InvalidProof();

    constructor(IERC20 token_) Ownable(msg.sender) {
        token = token_;
    }

    function fund(uint256 amount) external {
        token.safeTransferFrom(msg.sender, address(this), amount);
        emit Funded(msg.sender, amount);
    }

    function available() public view returns (uint256) {
        return token.balanceOf(address(this)) - committed;
    }

    function publishSeason(uint256 season, bytes32 root, uint256 total, uint64 claimDeadline) external onlyOwner {
        if (seasons[season].root != bytes32(0)) revert SeasonExists();
        if (total > available()) revert InsufficientFunds();
        seasons[season] = Season(root, claimDeadline, total, 0);
        committed += total;
        emit SeasonPublished(season, root, total, claimDeadline);
    }

    function claim(uint256 season, uint256 amount, bytes32[] calldata proof) external nonReentrant {
        Season storage s = seasons[season];
        if (s.root == bytes32(0)) revert NotPublished();
        if (block.timestamp > s.claimDeadline) revert ClaimClosed();
        if (hasClaimed[season][msg.sender]) revert AlreadyClaimed();
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(season, msg.sender, amount))));
        if (!MerkleProof.verify(proof, s.root, leaf)) revert InvalidProof();
        hasClaimed[season][msg.sender] = true;
        s.claimed += amount;
        committed -= amount;
        token.safeTransfer(msg.sender, amount);
        emit PrizeClaimed(season, msg.sender, amount);
    }

    /// @notice Return a season's unclaimed prizes to the general pool after its deadline.
    function sweep(uint256 season) external onlyOwner {
        Season storage s = seasons[season];
        if (s.root == bytes32(0)) revert NotPublished();
        if (block.timestamp <= s.claimDeadline) revert ClaimStillOpen();
        uint256 left = s.total - s.claimed;
        s.claimed = s.total;
        committed -= left;
        emit Swept(season, left);
    }
}
