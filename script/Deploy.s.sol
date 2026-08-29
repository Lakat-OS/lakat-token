// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {Lakat} from "src/Lakat.sol";
import {LakatTokenDistributor} from "src/LakatTokenDistributor.sol";

/// @notice Deploys the whole system in one run:
///
///   1. LakatTokenDistributor implementation + UUPS proxy, owned by the deployer
///   2. Lakat implementation + UUPS proxy, minting its entire initial supply
///      directly to the distributor proxy
///   3. Binds the token on the distributor
///   4. Optionally publishes the first Merkle root
///   5. Hands ownership of the distributor to OWNER
///
/// The distributor goes first so that Lakat can mint straight into it: the
/// initial supply is never held by the deploying EOA, so there is no window in
/// which a leaked deployer key controls the tokens, and no transfer to forget.
///
/// The distributor is initialised with the deployer as owner (atomically, in
/// the proxy's own construction — an uninitialised UUPS proxy can be hijacked
/// by anyone calling `initialize` first) and handed to OWNER at the end, which
/// lets OWNER be a multisig that cannot itself run the setup calls.
///
/// Environment:
///   OWNER         (required) final owner + UUPS upgrader of both proxies
///   MERKLE_ROOT   (optional) first distribution root, from `npm run merkle:root`.
///                            Omit, or set to 0x0, to publish it later.
///
/// Run:
///   OWNER=0x… forge script script/Deploy.s.sol:Deploy \
///     --rpc-url $RPC_URL --broadcast --verify --force
contract Deploy is Script {
    function run() public returns (address lakatProxy, address distributorProxy) {
        address owner = vm.envAddress("OWNER");
        bytes32 merkleRoot = vm.envOr("MERKLE_ROOT", bytes32(0));
        address deployer = msg.sender;

        require(owner != address(0), "OWNER must not be the zero address");

        vm.startBroadcast();

        // 1. Distributor first — its address is what Lakat mints to.
        distributorProxy = Upgrades.deployUUPSProxy(
            "LakatTokenDistributor.sol", abi.encodeCall(LakatTokenDistributor.initialize, (deployer))
        );
        LakatTokenDistributor distributor = LakatTokenDistributor(distributorProxy);

        // 2. Lakat, minting the entire initial supply to the distributor.
        lakatProxy =
            Upgrades.deployUUPSProxy("Lakat.sol", abi.encodeCall(Lakat.initialize, (distributorProxy, owner)));
        Lakat lakat = Lakat(lakatProxy);

        // 3. Bind the token (one-shot).
        distributor.setToken(lakatProxy);

        // 4. Publish the first root, if one was supplied.
        if (merkleRoot != bytes32(0)) {
            distributor.setMerkleRoot(merkleRoot);
        }

        // 5. Hand over. Single-step: check OWNER carefully, there is no undo.
        distributor.transferOwnership(owner);

        vm.stopBroadcast();

        // Fail loudly rather than leave a half-configured deployment behind.
        require(lakat.balanceOf(distributorProxy) == lakat.totalSupply(), "supply not in distributor");
        require(address(distributor.token()) == lakatProxy, "token not bound");
        require(distributor.owner() == owner, "distributor owner not handed over");
        require(lakat.owner() == owner, "lakat owner not set");

        console.log("Lakat proxy:        %s", lakatProxy);
        console.log("Distributor proxy:  %s", distributorProxy);
        console.log("Owner / upgrader:   %s", owner);
        console.log("Supply held:        %s", lakat.balanceOf(distributorProxy));
        if (merkleRoot != bytes32(0)) {
            console.log("Distribution id:    %s", distributor.distributionId());
        } else {
            console.log("No MERKLE_ROOT set; publish one with SetMerkleRoot before anyone can claim.");
        }
    }
}

/// @notice Publishes a Merkle root on an already deployed distributor. Must be
///         run by the owner.
///
/// Environment:
///   DISTRIBUTOR   address of the distributor proxy
///   MERKLE_ROOT   root from `npm run merkle:root`
///
/// Run:
///   DISTRIBUTOR=0x… MERKLE_ROOT=0x… forge script script/Deploy.s.sol:SetMerkleRoot \
///     --rpc-url $RPC_URL --broadcast --force
contract SetMerkleRoot is Script {
    function run() public {
        LakatTokenDistributor distributor = LakatTokenDistributor(vm.envAddress("DISTRIBUTOR"));
        bytes32 merkleRoot = vm.envBytes32("MERKLE_ROOT");

        require(merkleRoot != bytes32(0), "MERKLE_ROOT must not be zero");

        vm.startBroadcast();
        distributor.setMerkleRoot(merkleRoot);
        vm.stopBroadcast();

        console.log("Distribution id: %s", distributor.distributionId());
        console.log("Unclaimed:       %s", distributor.unclaimedBalance());
    }
}
