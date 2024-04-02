// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";

import { IERC20Metadata } from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { VelodromeFarmer, ISafe, IGauge, IOptimizer, IPool, IRouter, IVoter, IERC20 } from "../src/VelodromeFarmer.sol";

contract VelodromeFarmerTest is Test {
  VelodromeFarmer public farmer;
  ISafeAdmin public safe;

  IERC20 public pool;
  IGauge public gauge;
  IVoter public voter;
  IRouter public router;
  IOptimizer public optimizer;

  function setUp() external {
    vm.createSelectFork("optimism", 118_203_346);

    safe = ISafeAdmin(0x23fD464e0b0eE21cEdEb929B19CABF9bD5215019);
    voter = IVoter(0x41C914ee0c7E1A5edCD0295623e6dC557B5aBf3C);
    router = IRouter(0xa062aE8A9c5e11aaA026fc2670B0D65cCc8B2858);
    optimizer = IOptimizer(0x2b0547920a21C0496742e92ddDC6483Db227a130);
    gauge = IGauge(0x76ec1eF8c0F72ccdFbB661664C6cB0Ac187D2fB5);
    pool = IERC20(voter.poolForGauge(address(gauge)));

    vm.label(address(safe), "Safe");
    vm.label(address(pool), "Pool");
    vm.label(address(gauge), "Gauge");
    vm.label(address(voter), "Voter");
    vm.label(address(router), "Router");
    vm.label(address(optimizer), "Optimizer");
    vm.label(address(optimizer.factory()), "PoolFactory");
    vm.label(address(uint160(uint256(vm.load(address(safe), 0)))), "SafeSingleton");
    (address token0, address token1) = IPool(voter.poolForGauge(address(gauge))).tokens();
    vm.label(token0, IERC20Metadata(token0).symbol());
    vm.label(token1, IERC20Metadata(token1).symbol());

    farmer = new VelodromeFarmer(voter, router, optimizer);

    vm.startPrank(address(safe));
    safe.enableModule(farmer);
    safe.addOwnerWithThreshold(address(this), safe.getThreshold());
    vm.stopPrank();
  }

  function testVelodromeFarmLP() external {
    farmer.farmLP(safe, gauge, 500);

    assertEq(pool.balanceOf(address(safe)), 0);
  }
}

interface ISafeAdmin is ISafe {
  function getThreshold() external view returns (uint256);
  function enableModule(VelodromeFarmer module) external;
  function addOwnerWithThreshold(address owner, uint256 threshold) external;
}
