// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title Validator Tycoon — Company Licences
/// @notice Limited-supply, tradeable cosmetic licences (ERC-1155) for PulseChain (chain ID 369).
///         Licences are cosmetic/status items only: they unlock a company skin and a nameplate in-game
///         and do NOT entitle holders to any share of revenue or rewards.
contract ValidatorLicence is ERC1155, Ownable {
    struct Tier {
        uint256 price;      // in wei of the native coin (PLS)
        uint256 maxSupply;  // 0 = tier disabled
        uint256 minted;
        bool active;
    }

    mapping(uint256 => Tier) public tiers;
    address payable public treasury;
    string public name = "Validator Tycoon Licence";
    string public symbol = "VTLIC";

    event TierSet(uint256 indexed id, uint256 price, uint256 maxSupply, bool active);
    event LicenceMinted(address indexed to, uint256 indexed id, uint256 amount);

    error TierInactive();
    error SoldOut();
    error WrongPayment();
    error SupplyBelowMinted();

    constructor(string memory uri_, address payable treasury_) ERC1155(uri_) Ownable(msg.sender) {
        treasury = treasury_;
    }

    function setTier(uint256 id, uint256 price, uint256 maxSupply, bool active) external onlyOwner {
        if (maxSupply < tiers[id].minted) revert SupplyBelowMinted();
        Tier storage t = tiers[id];
        t.price = price;
        t.maxSupply = maxSupply;
        t.active = active;
        emit TierSet(id, price, maxSupply, active);
    }

    function mint(uint256 id, uint256 amount) external payable {
        Tier storage t = tiers[id];
        if (!t.active) revert TierInactive();
        if (t.minted + amount > t.maxSupply) revert SoldOut();
        if (msg.value != t.price * amount) revert WrongPayment();
        t.minted += amount;
        _mint(msg.sender, id, amount, "");
        emit LicenceMinted(msg.sender, id, amount);
        (bool ok, ) = treasury.call{value: msg.value}("");
        require(ok, "treasury transfer failed");
    }

    function setURI(string calldata uri_) external onlyOwner {
        _setURI(uri_);
    }

    function setTreasury(address payable t) external onlyOwner {
        treasury = t;
    }
}
