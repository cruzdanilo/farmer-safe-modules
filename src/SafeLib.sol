// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.25;

library SafeLib {
  function txCall(ISafe account, address to, bytes memory data) internal {
    assert(account.execTransactionFromModule({ to: to, value: 0, data: data, operation: Operation.Call }));
  }
}

interface ISafe {
  function isOwner(address owner) external view returns (bool);
  function execTransactionFromModule(address to, uint256 value, bytes calldata data, Operation operation)
    external
    returns (bool success);
}

enum Operation {
  Call,
  DelegateCall
}
