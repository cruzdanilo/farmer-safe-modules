// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import { IERC20 } from "openzeppelin-contracts/contracts/interfaces/IERC20.sol";

import { IGauge } from "@velodrome/contracts/interfaces/IGauge.sol";
import { IPool } from "@velodrome/contracts/interfaces/IPool.sol";
import { IRouter } from "@velodrome/contracts/interfaces/IRouter.sol";
import { IVoter } from "@velodrome/contracts/interfaces/IVoter.sol";
import { IVotingEscrow } from "@velodrome/contracts/interfaces/IVotingEscrow.sol";

import { IOptimizer } from "velodrome/src/interfaces/IOptimizer.sol";

import { ISafe, SafeLib } from "./SafeLib.sol";

contract VelodromeFarmer {
  using SafeLib for ISafe;

  IVoter public immutable VOTER;
  IOptimizer public immutable OPTIMIZER;
  address public immutable POOL_FACTORY;
  address public immutable ROUTER;
  address public immutable VELO;

  uint256 public constant POINTS = 3;
  uint256 public constant MAX_SLIPPAGE = 500;

  constructor(IVoter voter, IOptimizer optimizer, address router) {
    assert(router != address(0));

    VELO = IVotingEscrow(voter.ve()).token();
    VOTER = voter;
    ROUTER = router;
    OPTIMIZER = optimizer;
    POOL_FACTORY = optimizer.factory();

    assert(VELO == optimizer.velo());
  }

  function farmLP(ISafe account, address gauge, uint256 slippage) external {
    if (slippage > MAX_SLIPPAGE) revert SlippageTooHigh();
    if (!account.isOwner(msg.sender)) revert NotOwner();

    address pool = VOTER.poolForGauge(gauge);
    if (pool == address(0)) revert NotGauge();

    account.txCall(gauge, abi.encodeCall(IGauge.getReward, address(account)));

    address[2] memory tokens;
    (tokens[0], tokens[1]) = IPool(pool).tokens();

    {
      uint256 balanceVELO = IERC20(VELO).balanceOf(address(account));
      swapTo(account, tokens[0], balanceVELO - balanceVELO / 2, slippage);
      swapTo(account, tokens[1], balanceVELO / 2, slippage);
    }

    bool stable = IPool(pool).stable();
    uint256[2] memory amounts;
    amounts[0] = IERC20(tokens[0]).balanceOf(address(account));
    amounts[1] = IERC20(tokens[1]).balanceOf(address(account));

    {
      uint256[2] memory approvals;
      // slither-disable-next-line unused-return -- liquidity is unneeded
      (approvals[0], approvals[1],) =
        IRouter(ROUTER).quoteAddLiquidity(tokens[0], tokens[1], stable, POOL_FACTORY, amounts[0], amounts[1]);

      account.txCall(tokens[0], abi.encodeCall(IERC20.approve, (ROUTER, approvals[0])));
      account.txCall(tokens[1], abi.encodeCall(IERC20.approve, (ROUTER, approvals[1])));
    }

    account.txCall(
      ROUTER,
      abi.encodeCall(
        IRouter.addLiquidity,
        (tokens[0], tokens[1], stable, amounts[0], amounts[1], 0, 0, address(account), block.timestamp)
      )
    );
    account.txCall(gauge, abi.encodeWithSignature("deposit(uint256)", IERC20(pool).balanceOf(address(account))));
  }

  function swapTo(ISafe account, address token, uint256 amount, uint256 slippage) internal {
    if (token == VELO) return;

    IRouter.Route[] memory routes = OPTIMIZER.getOptimalTokenToTokenRoute(VELO, token, amount);
    uint256 amountOutMin = OPTIMIZER.getOptimalAmountOutMin(routes, amount, POINTS, slippage);
    // slither-disable-next-line incorrect-equality -- zero is a flag value
    if (amountOutMin == 0) revert NoRouteFound();

    account.txCall(VELO, abi.encodeCall(IERC20.approve, (ROUTER, amount)));
    account.txCall(
      ROUTER,
      abi.encodeCall(
        IRouter.swapExactTokensForTokens, (amount, amountOutMin, routes, address(account), block.timestamp)
      )
    );
  }
}

error NoRouteFound();
error NotGauge();
error NotOwner();
error SlippageTooHigh();
