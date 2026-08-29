// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {Lakat} from "src/Lakat.sol";
import {LakatTokenDistributor} from "src/LakatTokenDistributor.sol";

/// @notice Pins the on-chain leaf encoding to what `@openzeppelin/merkle-tree`
///         produces off-chain. The fixture below is the verbatim output of
///
///             node merkle/build-tree.mjs merkle/allocations.example.csv
///
///         (merkle/allocations.example.json is the same list and yields the
///         same root).
///
///         If this test starts failing, the Solidity leaf encoding and
///         merkle/build-tree.mjs have drifted apart.
contract MerkleTreeCompatTest is Test {
    bytes32 internal constant ROOT = 0x921f1eb42f3902443112742ad0457d82b63a66f499751667f03f06509d19d26e;

    Lakat internal lakat;
    LakatTokenDistributor internal distributor;

    address internal owner = vm.addr(1);
    address internal treasury = vm.addr(2);

    function setUp() public {
        address distributorProxy = Upgrades.deployUUPSProxy(
            "LakatTokenDistributor.sol", abi.encodeCall(LakatTokenDistributor.initialize, (owner))
        );
        distributor = LakatTokenDistributor(distributorProxy);

        address tokenProxy = Upgrades.deployUUPSProxy(
            "Lakat.sol", abi.encodeCall(Lakat.initialize, (distributorProxy, owner))
        );
        lakat = Lakat(tokenProxy);

        vm.startPrank(owner);
        distributor.setToken(tokenProxy);
        distributor.setMerkleRoot(ROOT);
        vm.stopPrank();
    }

    function test_ClaimsFromJsGeneratedTree() public {
        _claim(
            0,
            0x70997970C51812dc3A010C7d01b50e0d17dc79C8,
            1000000000000000000000000,
            0x7998d8daa7f7b6fe733aac92d9427f3c0081d1a9e4529bf85d3071acff856b26,
            0xb6fc7d4b0bdc3e11802fb88302742b5fa19954d9724c0628d3d66b0fbaf78cb9
        );
        _claim(
            1,
            0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC,
            250000500000000000000000,
            0xe5c3b5546c5df4aeb3044d9752c92a95b4b355b709f91da17893436bf7f632ac,
            0x643ba49e197729487cf05767cddf42995b0c5cef286b70bbff6370121aa60e28
        );
        _claim(
            2,
            0x90F79bf6EB2c4f870365E785982E1f101E93b906,
            1000000000000000000,
            0x7d409cc7907565b56351c1c9580e3807b5ff62e7f2190d8db3158413897e62c2,
            0xb6fc7d4b0bdc3e11802fb88302742b5fa19954d9724c0628d3d66b0fbaf78cb9
        );
        _claim(
            3,
            0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65,
            42000000000000000000,
            0xbf99dc8a565b604de9d4f32a6b4540a5cb32b75c569093567ed4c55f252ef903,
            0x643ba49e197729487cf05767cddf42995b0c5cef286b70bbff6370121aa60e28
        );

        assertEq(distributor.totalClaimed(), 1250043500000000000000000);
    }

    function _claim(uint256 index, address account, uint256 amount, bytes32 p0, bytes32 p1) internal {
        bytes32[] memory proof = new bytes32[](2);
        proof[0] = p0;
        proof[1] = p1;

        distributor.claim(index, account, amount, proof);
        assertEq(lakat.balanceOf(account), amount);
    }
}
