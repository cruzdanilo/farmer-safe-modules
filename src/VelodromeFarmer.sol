// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.25;

import { IERC20 } from "openzeppelin-contracts/contracts/interfaces/IERC20.sol";

import { IGauge } from "velodrome/contracts/interfaces/IGauge.sol";
import { IPool } from "velodrome/contracts/interfaces/IPool.sol";
import { IPoolFactory } from "velodrome/contracts/interfaces/factories/IPoolFactory.sol";
import { IRouter } from "velodrome/contracts/interfaces/IRouter.sol";
import { IVoter } from "velodrome/contracts/interfaces/IVoter.sol";
import { IVotingEscrow } from "velodrome/contracts/interfaces/IVotingEscrow.sol";

contract VelodromeFarmer {
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
    if (!VOTER.isGauge(address(gauge))) revert NotGauge();
    if (!account.isOwner(msg.sender)) revert NotOwner();

    Pool memory p;
    p.pool = IPool(VOTER.poolForGauge(address(gauge)));
    p.stable = p.pool.stable();
    (p.token0, p.token1) = p.pool.tokens();

    {
      uint256 earned = gauge.earned(address(account));
      if (earned == 0) return;

      assert(
        account.execTransactionFromModule({
          to: address(gauge),
          value: 0,
          data: abi.encodeCall(IGauge.getReward, address(account)),
          operation: Operation.Call
        })
      );

      p.amount0 = swapTo(account, IERC20(p.token0), earned - earned / 2, slippage);
      p.amount1 = swapTo(account, IERC20(p.token1), earned / 2, slippage);
    }

    (p.amount0Min, p.amount1Min,) =
      ROUTER.quoteAddLiquidity(p.token0, p.token1, p.stable, address(POOL_FACTORY), p.amount0, p.amount1);
    approveRouter(account, p.token0, p.amount0Min);
    approveRouter(account, p.token1, p.amount1Min);

    assert(
      account.execTransactionFromModule({
        to: address(ROUTER),
        value: 0,
        data: abi.encodeCall(
          IRouter.addLiquidity,
          (
            p.token0,
            p.token1,
            p.stable,
            p.amount0,
            p.amount1,
            p.amount0Min,
            p.amount1Min,
            address(account),
            block.timestamp
          )
          ),
        operation: Operation.Call
      })
    );
    assert(
      account.execTransactionFromModule({
        to: address(gauge),
        value: 0,
        data: abi.encodeWithSignature("deposit(uint256)", IERC20(address(p.pool)).balanceOf(address(account))),
        operation: Operation.Call
      })
    );
  }

  function swapTo(ISafe account, IERC20 token, uint256 amount, uint256 slippage) internal returns (uint256 amountOut) {
    if (address(token) == address(VELO)) return amount;

    IRouter.Route[] memory routes = OPTIMIZER.getOptimalTokenToTokenRoute(address(VELO), address(token), amount);
    uint256 amountOutMin = OPTIMIZER.getOptimalAmountOutMin(routes, amount, POINTS, slippage);
    if (amountOutMin == 0) revert NoRouteFound();

    uint256 balanceBefore = token.balanceOf(address(account));

    approveRouter(account, address(VELO), amount);
    assert(
      account.execTransactionFromModule({
        to: address(ROUTER),
        value: 0,
        data: abi.encodeCall(
          IRouter.swapExactTokensForTokens, (amount, amountOutMin, routes, address(account), block.timestamp)
          ),
        operation: Operation.Call
      })
    );

    return token.balanceOf(address(account)) - balanceBefore;
  }

  function approveRouter(ISafe account, address token, uint256 amount) internal {
    assert(
      account.execTransactionFromModule({
        to: token,
        value: 0,
        data: abi.encodeCall(IERC20.approve, (address(ROUTER), amount)),
        operation: Operation.Call
      })
    );
  }
}

interface ISafe {
  function isOwner(address owner) external view returns (bool);
  function execTransactionFromModule(address to, uint256 value, bytes calldata data, Operation operation)
    external
    returns (bool success);
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

struct Pool {
  IPool pool;
  address token0;
  address token1;
  bool stable;
  uint256 amount0;
  uint256 amount1;
  uint256 amount0Min;
  uint256 amount1Min;
}

enum Operation {
  Call,
  DelegateCall
}

error NoRouteFound();
error NotGauge();
error NotOwner();
error SlippageTooHigh();
