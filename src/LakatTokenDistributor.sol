// SPDX-License-Identifier: MIT
// Compatible with OpenZeppelin Contracts ^5.7.0
pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {BitMaps} from "@openzeppelin/contracts/utils/structs/BitMaps.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/// @title LakatTokenDistributor
/// @notice Holds the initial supply of the Lakat token and releases it against
///         Merkle proofs. The owner (who is also the UUPS upgrader) publishes a
///         Merkle root; anyone can then submit a claim on behalf of a recipient.
/// @dev Leaves are encoded the way OpenZeppelin's `@openzeppelin/merkle-tree`
///      `StandardMerkleTree` encodes them, i.e. double-hashed ABI encoding:
///
///          keccak256(bytes.concat(keccak256(abi.encode(index, account, amount))))
///
///      with leaf types `["uint256", "address", "uint256"]`. The double hash
///      makes internal nodes and leaves unambiguously distinct, and OZ's
///      `MerkleProof` hashes sibling pairs commutatively, matching the JS lib.
/// @custom:security-contact info@lakat.science
contract LakatTokenDistributor is Initializable, OwnableUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;
    using BitMaps for BitMaps.BitMap;

    /// @notice The token being distributed.
    IERC20 public token;

    /// @notice Root of the currently active distribution.
    bytes32 public merkleRoot;

    /// @notice Incremented every time a new root is published, so that claim
    ///         bookkeeping of an old distribution never blocks a new one.
    uint256 public distributionId;

    /// @notice Total amount handed out across all distributions.
    uint256 public totalClaimed;

    /// @dev distributionId => bitmap of claimed leaf indices.
    mapping(uint256 => BitMaps.BitMap) private _claimed;

    event TokenSet(address indexed token);
    event MerkleRootUpdated(uint256 indexed distributionId, bytes32 indexed merkleRoot);
    event Claimed(uint256 indexed distributionId, uint256 indexed index, address indexed account, uint256 amount);
    event Swept(address indexed to, uint256 amount);

    error ZeroAddress();
    error TokenAlreadySet();
    error TokenNotSet();
    error NoActiveDistribution();
    error AlreadyClaimed(uint256 index);
    error InvalidProof();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice The token is deliberately *not* set here. This contract is
    ///         deployed before Lakat so that Lakat can mint its entire initial
    ///         supply straight to this address, which means the token address
    ///         does not exist yet at this point. Call `setToken` immediately
    ///         afterwards (see script/Deploy.s.sol).
    /// @param initialOwner Owner and UUPS upgrader. Set here rather than in a
    ///        follow-up call so the proxy is never briefly ownerless.
    function initialize(address initialOwner) public initializer {
        __Ownable_init(initialOwner);
    }

    /// @notice Bind the distributed token. Can only be done once, so the
    ///         distributor cannot be repointed at a different token later.
    function setToken(address token_) external onlyOwner {
        if (token_ == address(0)) revert ZeroAddress();
        if (address(token) != address(0)) revert TokenAlreadySet();

        token = IERC20(token_);
        emit TokenSet(token_);
    }

    // --------------------------------------------------------------------
    // Owner
    // --------------------------------------------------------------------

    /// @notice Publish a new Merkle root. Starts a fresh distribution round:
    ///         indices claimed under the previous root are claimable again
    ///         under the new one, so a new root must contain the *remaining*
    ///         allocations only.
    function setMerkleRoot(bytes32 newMerkleRoot) external onlyOwner {
        if (address(token) == address(0)) revert TokenNotSet();

        merkleRoot = newMerkleRoot;
        uint256 id = ++distributionId;
        emit MerkleRootUpdated(id, newMerkleRoot);
    }

    /// @notice Recover tokens that were never claimed (or sent here by mistake).
    function sweep(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        emit Swept(to, amount);
        token.safeTransfer(to, amount);
    }

    /// @notice Recover an arbitrary ERC-20 that ended up in this contract.
    function sweepToken(address token_, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        IERC20(token_).safeTransfer(to, amount);
    }

    // --------------------------------------------------------------------
    // Claiming
    // --------------------------------------------------------------------

    /// @notice Claim `amount` for `account`. Callable by anyone; the tokens
    ///         always go to `account`, so a relayer can pay the gas.
    /// @param index Position of the leaf in the tree that produced `merkleRoot`.
    /// @param account Recipient encoded in the leaf.
    /// @param amount Amount encoded in the leaf, in token base units.
    /// @param proof Merkle proof for the leaf.
    function claim(uint256 index, address account, uint256 amount, bytes32[] calldata proof) external {
        uint256 id = distributionId;
        if (id == 0) revert NoActiveDistribution();
        if (_claimed[id].get(index)) revert AlreadyClaimed(index);
        if (!MerkleProof.verifyCalldata(proof, merkleRoot, leafHash(index, account, amount))) revert InvalidProof();

        _claimed[id].set(index);
        totalClaimed += amount;

        emit Claimed(id, index, account, amount);
        token.safeTransfer(account, amount);
    }

    // --------------------------------------------------------------------
    // Views
    // --------------------------------------------------------------------

    /// @notice Leaf hash for a claim, matching `StandardMerkleTree` encoding.
    function leafHash(uint256 index, address account, uint256 amount) public pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(index, account, amount))));
    }

    /// @notice Whether `index` has been claimed in the current distribution.
    function isClaimed(uint256 index) public view returns (bool) {
        return _claimed[distributionId].get(index);
    }

    /// @notice Whether `index` has been claimed in a given distribution round.
    function isClaimedIn(uint256 id, uint256 index) public view returns (bool) {
        return _claimed[id].get(index);
    }

    /// @notice Dry-run a claim without submitting it.
    function verify(uint256 index, address account, uint256 amount, bytes32[] calldata proof)
        external
        view
        returns (bool)
    {
        return MerkleProof.verifyCalldata(proof, merkleRoot, leafHash(index, account, amount));
    }

    /// @notice Tokens still sitting in the distributor.
    function unclaimedBalance() external view returns (uint256) {
        return token.balanceOf(address(this));
    }

    // --------------------------------------------------------------------
    // UUPS
    // --------------------------------------------------------------------

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
