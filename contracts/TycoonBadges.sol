// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @title Validator Tycoon — Soulbound Badges
/// @notice Achievement badges that cannot be transferred. The game server checks a player's
///         progress and signs (player, badgeId, chainId, contract); the player then claims on-chain
///         and pays their own gas. Each badge can be claimed once per wallet.
contract TycoonBadges is ERC1155, Ownable {
    using MessageHashUtils for bytes32;

    address public signer;
    mapping(address => mapping(uint256 => bool)) public claimed;

    event BadgeClaimed(address indexed player, uint256 indexed badgeId);

    error Soulbound();
    error AlreadyClaimed();
    error BadSignature();

    constructor(string memory uri_, address signer_) ERC1155(uri_) Ownable(msg.sender) {
        signer = signer_;
    }

    function claim(uint256 badgeId, bytes calldata signature) external {
        if (claimed[msg.sender][badgeId]) revert AlreadyClaimed();
        bytes32 digest = keccak256(abi.encodePacked(msg.sender, badgeId, block.chainid, address(this)))
            .toEthSignedMessageHash();
        if (ECDSA.recover(digest, signature) != signer) revert BadSignature();
        claimed[msg.sender][badgeId] = true;
        _mint(msg.sender, badgeId, 1, "");
        emit BadgeClaimed(msg.sender, badgeId);
    }

    /// @dev Block every transfer except minting (from == 0). Burning by the holder is also blocked.
    function _update(address from, address to, uint256[] memory ids, uint256[] memory values) internal override {
        if (from != address(0)) revert Soulbound();
        super._update(from, to, ids, values);
    }

    function setApprovalForAll(address, bool) public pure override {
        revert Soulbound();
    }

    function setSigner(address s) external onlyOwner {
        signer = s;
    }

    function setURI(string calldata uri_) external onlyOwner {
        _setURI(uri_);
    }
}
