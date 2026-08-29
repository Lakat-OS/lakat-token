// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {Lakat} from "src/Lakat.sol";

contract LakatTest is Test {
  Lakat public instance;

  function setUp() public {
    address recipient = vm.addr(1);
    address initialOwner = vm.addr(2);
    address proxy = Upgrades.deployUUPSProxy(
      "Lakat.sol",
      abi.encodeCall(Lakat.initialize, (recipient, initialOwner))
    );
    instance = Lakat(proxy);
  }

  function testName() public view {
    assertEq(instance.name(), "Lakat");
  }
}
