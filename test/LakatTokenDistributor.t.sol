// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {Hashes} from "@openzeppelin/contracts/utils/cryptography/Hashes.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Lakat} from "src/Lakat.sol";
import {LakatTokenDistributor} from "src/LakatTokenDistributor.sol";

contract LakatTokenDistributorTest is Test {
    Lakat internal lakat;
    LakatTokenDistributor internal distributor;

    address internal owner = vm.addr(1);
    address internal treasury = vm.addr(2);
    address internal alice = vm.addr(3);
    address internal bob = vm.addr(4);
    address internal carol = vm.addr(5);
    address internal dave = vm.addr(6);

    uint256 internal constant ALICE_AMOUNT = 100e18;
    uint256 internal constant BOB_AMOUNT = 250e18;
    uint256 internal constant CAROL_AMOUNT = 1e18;
    uint256 internal constant DAVE_AMOUNT = 7e18;

    bytes32[4] internal leaves;
    bytes32 internal root;

    function setUp() public {
        // Mirrors script/Deploy.s.sol: distributor first, then Lakat minting
        // its entire initial supply straight into it.
        address distributorProxy = Upgrades.deployUUPSProxy(
            "LakatTokenDistributor.sol", abi.encodeCall(LakatTokenDistributor.initialize, (owner))
        );
        distributor = LakatTokenDistributor(distributorProxy);

        address tokenProxy = Upgrades.deployUUPSProxy(
            "Lakat.sol", abi.encodeCall(Lakat.initialize, (distributorProxy, owner))
        );
        lakat = Lakat(tokenProxy);

        vm.prank(owner);
        distributor.setToken(tokenProxy);

        leaves[0] = distributor.leafHash(0, alice, ALICE_AMOUNT);
        leaves[1] = distributor.leafHash(1, bob, BOB_AMOUNT);
        leaves[2] = distributor.leafHash(2, carol, CAROL_AMOUNT);
        leaves[3] = distributor.leafHash(3, dave, DAVE_AMOUNT);
        root = Hashes.commutativeKeccak256(
            Hashes.commutativeKeccak256(leaves[0], leaves[1]), Hashes.commutativeKeccak256(leaves[2], leaves[3])
        );

        vm.prank(owner);
        distributor.setMerkleRoot(root);
    }

    /// @dev Proof for a leaf of the balanced 4-leaf tree built in `setUp`.
    function _proof(uint256 index) internal view returns (bytes32[] memory proof) {
        proof = new bytes32[](2);
        proof[0] = leaves[index ^ 1];
        proof[1] = index < 2
            ? Hashes.commutativeKeccak256(leaves[2], leaves[3])
            : Hashes.commutativeKeccak256(leaves[0], leaves[1]);
    }

    function test_HoldsEntireInitialSupply() public view {
        assertEq(lakat.balanceOf(address(distributor)), 1_000_000_000e18);
        assertEq(lakat.balanceOf(address(distributor)), lakat.totalSupply());
        assertEq(distributor.unclaimedBalance(), lakat.totalSupply());
    }

    function test_Initialization() public view {
        assertEq(address(distributor.token()), address(lakat));
        assertEq(distributor.owner(), owner);
        assertEq(distributor.distributionId(), 1);
        assertEq(distributor.merkleRoot(), root);
    }

    function test_Claim() public {
        assertTrue(distributor.verify(0, alice, ALICE_AMOUNT, _proof(0)));

        vm.expectEmit(true, true, true, true);
        emit LakatTokenDistributor.Claimed(1, 0, alice, ALICE_AMOUNT);
        distributor.claim(0, alice, ALICE_AMOUNT, _proof(0));

        assertEq(lakat.balanceOf(alice), ALICE_AMOUNT);
        assertTrue(distributor.isClaimed(0));
        assertEq(distributor.totalClaimed(), ALICE_AMOUNT);
    }

    function test_ClaimByRelayer() public {
        vm.prank(bob); // anyone may relay; funds still go to the leaf's account
        distributor.claim(2, carol, CAROL_AMOUNT, _proof(2));
        assertEq(lakat.balanceOf(carol), CAROL_AMOUNT);
        assertEq(lakat.balanceOf(bob), 0);
    }

    function test_ClaimAllLeaves() public {
        distributor.claim(0, alice, ALICE_AMOUNT, _proof(0));
        distributor.claim(1, bob, BOB_AMOUNT, _proof(1));
        distributor.claim(2, carol, CAROL_AMOUNT, _proof(2));
        distributor.claim(3, dave, DAVE_AMOUNT, _proof(3));

        uint256 total = ALICE_AMOUNT + BOB_AMOUNT + CAROL_AMOUNT + DAVE_AMOUNT;
        assertEq(distributor.totalClaimed(), total);
        assertEq(distributor.unclaimedBalance(), lakat.totalSupply() - total);
    }

    function test_RevertWhen_ClaimedTwice() public {
        distributor.claim(0, alice, ALICE_AMOUNT, _proof(0));
        vm.expectRevert(abi.encodeWithSelector(LakatTokenDistributor.AlreadyClaimed.selector, 0));
        distributor.claim(0, alice, ALICE_AMOUNT, _proof(0));
    }

    function test_RevertWhen_AmountTampered() public {
        vm.expectRevert(LakatTokenDistributor.InvalidProof.selector);
        distributor.claim(0, alice, ALICE_AMOUNT + 1, _proof(0));
    }

    function test_RevertWhen_AccountTampered() public {
        vm.expectRevert(LakatTokenDistributor.InvalidProof.selector);
        distributor.claim(0, bob, ALICE_AMOUNT, _proof(0));
    }

    function test_RevertWhen_IndexTampered() public {
        vm.expectRevert(LakatTokenDistributor.InvalidProof.selector);
        distributor.claim(1, alice, ALICE_AMOUNT, _proof(0));
    }

    function test_RevertWhen_NoDistribution() public {
        address proxy = Upgrades.deployUUPSProxy(
            "LakatTokenDistributor.sol", abi.encodeCall(LakatTokenDistributor.initialize, (owner))
        );
        vm.expectRevert(LakatTokenDistributor.NoActiveDistribution.selector);
        LakatTokenDistributor(proxy).claim(0, alice, ALICE_AMOUNT, _proof(0));
    }

    function test_NewRootStartsNewRound() public {
        distributor.claim(0, alice, ALICE_AMOUNT, _proof(0));
        assertTrue(distributor.isClaimed(0));

        vm.prank(owner);
        distributor.setMerkleRoot(root);

        assertEq(distributor.distributionId(), 2);
        assertFalse(distributor.isClaimed(0));
        assertTrue(distributor.isClaimedIn(1, 0));

        distributor.claim(0, alice, ALICE_AMOUNT, _proof(0));
        assertEq(lakat.balanceOf(alice), 2 * ALICE_AMOUNT);
    }

    function test_RevertWhen_NonOwnerSetsRoot() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        distributor.setMerkleRoot(bytes32(uint256(1)));
    }

    function test_Sweep() public {
        uint256 amount = 5e18;
        vm.prank(owner);
        distributor.sweep(treasury, amount);
        assertEq(lakat.balanceOf(treasury), amount);
    }

    function test_RevertWhen_NonOwnerSweeps() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        distributor.sweep(alice, 1);
    }

    function test_RevertWhen_ClaimExceedsBalance() public {
        vm.startPrank(owner);
        distributor.sweep(treasury, lakat.balanceOf(address(distributor)));
        vm.stopPrank();

        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(distributor), 0, ALICE_AMOUNT
            )
        );
        distributor.claim(0, alice, ALICE_AMOUNT, _proof(0));
    }

    function test_RevertWhen_TokenSetTwice() public {
        vm.prank(owner);
        vm.expectRevert(LakatTokenDistributor.TokenAlreadySet.selector);
        distributor.setToken(address(lakat));
    }

    function test_RevertWhen_NonOwnerSetsToken() public {
        address proxy = Upgrades.deployUUPSProxy(
            "LakatTokenDistributor.sol", abi.encodeCall(LakatTokenDistributor.initialize, (owner))
        );
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        LakatTokenDistributor(proxy).setToken(address(lakat));
    }

    function test_RevertWhen_TokenSetToZero() public {
        address proxy = Upgrades.deployUUPSProxy(
            "LakatTokenDistributor.sol", abi.encodeCall(LakatTokenDistributor.initialize, (owner))
        );
        vm.prank(owner);
        vm.expectRevert(LakatTokenDistributor.ZeroAddress.selector);
        LakatTokenDistributor(proxy).setToken(address(0));
    }

    function test_RevertWhen_RootSetBeforeToken() public {
        address proxy = Upgrades.deployUUPSProxy(
            "LakatTokenDistributor.sol", abi.encodeCall(LakatTokenDistributor.initialize, (owner))
        );
        vm.prank(owner);
        vm.expectRevert(LakatTokenDistributor.TokenNotSet.selector);
        LakatTokenDistributor(proxy).setMerkleRoot(root);
    }

    function test_RevertWhen_NonOwnerUpgrades() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        distributor.upgradeToAndCall(address(1), "");
    }
}
