// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.25;

import { IERC20 } from "openzeppelin-contracts/contracts/interfaces/IERC20.sol";

import { IGauge } from "velodrome/contracts/interfaces/IGauge.sol";
import { IPool } from "velodrome/contracts/interfaces/IPool.sol";
import { IRouter } from "velodrome/contracts/interfaces/IRouter.sol";
import { IVoter } from "velodrome/contracts/interfaces/IVoter.sol";
import { IVotingEscrow } from "velodrome/contracts/interfaces/IVotingEscrow.sol";
import { IPoolFactory } from "velodrome/contracts/interfaces/factories/IPoolFactory.sol";

import { ISafe, SafeLib } from "./SafeLib.sol";

contract VelodromeFarmer {
  using SafeLib for ISafe;

  IERC20 public immutable VELO;
  IVoter public immutable VOTER;
  IRouter public immutable ROUTER;
  IOptimizer public immutable OPTIMIZER;
  IPoolFactory public immutable POOL_FACTORY;

  uint256 public constant POINTS = 3;
  uint256 public constant MAX_SLIPPAGE = 500;

  constructor(IVoter voter, IRouter router, IOptimizer optimizer) {
    VELO = IERC20(IVotingEscrow(voter.ve()).token());
    VOTER = voter;
    ROUTER = router;
    OPTIMIZER = optimizer;
    POOL_FACTORY = optimizer.factory();

    assert(VELO == optimizer.velo());
  }

  function farmLP(ISafe account, IGauge gauge, uint256 slippage) external {
    if (slippage > MAX_SLIPPAGE) revert SlippageTooHigh();
    if (!account.isOwner(msg.sender)) revert NotOwner();

    IPool pool = IPool(VOTER.poolForGauge(address(gauge)));
    if (address(pool) == address(0)) revert NotGauge();

    account.txCall(address(gauge), abi.encodeCall(IGauge.getReward, address(account)));

    address[2] memory tokens;
    (tokens[0], tokens[1]) = pool.tokens();

    {
      uint256 balanceVELO = IERC20(VELO).balanceOf(address(account));
      swapTo(account, IERC20(tokens[0]), balanceVELO - balanceVELO / 2, slippage);
      swapTo(account, IERC20(tokens[1]), balanceVELO / 2, slippage);
    }

    bool stable = pool.stable();
    uint256[2] memory amounts;
    amounts[0] = IERC20(tokens[0]).balanceOf(address(account));
    amounts[1] = IERC20(tokens[1]).balanceOf(address(account));

    {
      uint256[2] memory approvals;
      // slither-disable-next-line unused-return -- liquidity is unneeded
      (approvals[0], approvals[1],) =
        ROUTER.quoteAddLiquidity(tokens[0], tokens[1], stable, address(POOL_FACTORY), amounts[0], amounts[1]);

      account.txCall(tokens[0], abi.encodeCall(IERC20.approve, (address(ROUTER), approvals[0])));
      account.txCall(tokens[1], abi.encodeCall(IERC20.approve, (address(ROUTER), approvals[1])));
    }

    account.txCall(
      address(ROUTER),
      abi.encodeCall(
        IRouter.addLiquidity,
        (tokens[0], tokens[1], stable, amounts[0], amounts[1], 0, 0, address(account), block.timestamp)
      )
    );
    account.txCall(
      address(gauge), abi.encodeWithSignature("deposit(uint256)", IERC20(address(pool)).balanceOf(address(account)))
    );
  }

  function swapTo(ISafe account, IERC20 token, uint256 amount, uint256 slippage) internal {
    if (address(token) == address(VELO)) return;

    IRouter.Route[] memory routes = OPTIMIZER.getOptimalTokenToTokenRoute(address(VELO), address(token), amount);
    uint256 amountOutMin = OPTIMIZER.getOptimalAmountOutMin(routes, amount, POINTS, slippage);
    // slither-disable-next-line incorrect-equality -- zero is a flag value
    if (amountOutMin == 0) revert NoRouteFound();

    account.txCall(address(VELO), abi.encodeCall(IERC20.approve, (address(ROUTER), amount)));
    account.txCall(
      address(ROUTER),
      abi.encodeCall(
        IRouter.swapExactTokensForTokens, (amount, amountOutMin, routes, address(account), block.timestamp)
      )
    );
  }
}

interface IOptimizer {
  function velo() external view returns (IERC20);
  function factory() external view returns (IPoolFactory);
  function getOptimalTokenToTokenRoute(address token0, address token1, uint256 amountIn)
    external
    view
    returns (IRouter.Route[] memory);
  function getOptimalAmountOutMin(IRouter.Route[] calldata routes, uint256 amountIn, uint256 points, uint256 slippage)
    external
    view
    returns (uint256);
}

error NoRouteFound();
error NotGauge();
error NotOwner();
error SlippageTooHigh();
