// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IPancakeV3 } from "../../interfaces/Pancake/IPancakeV3.sol";
import { IPancakeV2 } from "../../interfaces/Pancake/IPancakeV2.sol";

import { LibRouter } from "../libraries/LibRouter.sol";

import { IPool } from "../../interfaces/IPool.sol";

abstract contract PancakeFlashLoanFacetBase {
  using SafeERC20 for IERC20;
  /**********
   * Errors *
   **********/

  /// @dev Thrown when the caller is not self.
  error ErrorNotFromSelf();

  /// @dev Unauthorized reentrant call.
  error ReentrancyGuardReentrantCall();

  /// @dev Thrown when the caller is not pancakePool.
  error ErrorNotFromPancake();

  error ErrorNotFromRouterFlashLoan();

  /***********************
   * Immutable Variables *
   ***********************/

  /// @dev The address of Pancake Pool contract.
  address private immutable pancakePoolV3;
  address private immutable pancakePoolV2;

  /*************
   * Modifiers *
   *************/

  modifier onlySelf() {
    if (msg.sender != address(this)) revert ErrorNotFromSelf();
    _;
  }

  modifier onFlashLoan() {
    LibRouter.RouterStorage storage $ = LibRouter.routerStorage();
    $.flashLoanContext = LibRouter.HAS_FLASH_LOAN;
    _;
    $.flashLoanContext = LibRouter.NOT_FLASH_LOAN;
  }

  modifier nonReentrant() {
    LibRouter.RouterStorage storage $ = LibRouter.routerStorage();
    if ($.reentrantContext == LibRouter.HAS_ENTRANT) {
      revert ReentrancyGuardReentrantCall();
    }
    $.reentrantContext = LibRouter.HAS_ENTRANT;
    _;
    $.reentrantContext = LibRouter.NOT_ENTRANT;
  }

  /***************
   * Constructor *
   ***************/

  constructor(address _pancakePoolV3, address _pancakePoolV2) {
    pancakePoolV3 = _pancakePoolV3;
    pancakePoolV2 = _pancakePoolV2;
  }

  /**********************
   * Internal Functions *
   **********************/

  function _invokeFlashLoan(uint256 amount, bytes memory data) internal onFlashLoan {
    try IPancakeV3(pancakePoolV3).flash(address(this), 0, amount, data) {
    } catch {
      IPancakeV2(pancakePoolV2).swap(0, amount, address(this), data);
    }
  }

  /**********************
   * Callback Functions *
   **********************/

  function pancakeV3FlashCallback(
    uint256, //fee0,
    uint256 fee1,
    bytes calldata data
  ) external {
    if (msg.sender != pancakePoolV3) revert ErrorNotFromPancake();

    // make sure call invoked by router
    LibRouter.RouterStorage storage $ = LibRouter.routerStorage();
    if ($.flashLoanContext != LibRouter.HAS_FLASH_LOAN) revert ErrorNotFromRouterFlashLoan();

    //decode data
    bytes4 selector = bytes4(data[:4]);
    bytes memory argsData = data[4:];
    (
      address pool,
      uint256 positionId,
      uint256 amountIn,
      uint256 borrowAmount,
      ,
      address caller,
      bytes memory swapData
    ) = abi.decode(
      argsData,
      (address, uint256, uint256, uint256, uint256, address, bytes)
    );
    //add fee, encode & call
    bytes memory newData = abi.encodeWithSelector(
      selector,
      pool,
      positionId,
      amountIn,
      borrowAmount,
      fee1,
      caller,
      swapData
    );
    (bool success, ) = address(this).call(newData);
    // below lines will propagate inner error up
    if (!success) {
      // solhint-disable-next-line no-inline-assembly
      assembly {
        let ptr := mload(0x40)
        let size := returndatasize()
        returndatacopy(ptr, 0, size)
        revert(ptr, size)
      }
    }

    //pay back flashloan
    IERC20(IPool(pool).collateralToken()).safeTransfer(msg.sender, borrowAmount + fee1);
  }

  function pancakeCall(
    address, //sender,
    uint256, //amount0,
    uint256 amount1,
    bytes calldata data
  ) external {
    if (msg.sender != pancakePoolV2) revert ErrorNotFromPancake();

    // make sure call invoked by router
    LibRouter.RouterStorage storage $ = LibRouter.routerStorage();
    if ($.flashLoanContext != LibRouter.HAS_FLASH_LOAN) revert ErrorNotFromRouterFlashLoan();

    //decode data
    bytes4 selector = bytes4(data[:4]);
    bytes memory argsData = data[4:];
    (
      address pool,
      uint256 positionId,
      uint256 amountIn,
      uint256 borrowAmount,
      ,
      address caller,
      bytes memory swapData
    ) = abi.decode(
      argsData,
      (address, uint256, uint256, uint256, uint256, address, bytes)
    );
    //add fee, encode & call
    uint256 fee1 = ((amount1 * 25) / 9975) + 1; // pancake v3 fee is 0.25%
    bytes memory newData = abi.encodeWithSelector(
      selector,
      pool,
      positionId,
      amountIn,
      borrowAmount,
      fee1,
      caller,
      swapData
    );
    (bool success, ) = address(this).call(newData);
    // below lines will propagate inner error up
    if (!success) {
      // solhint-disable-next-line no-inline-assembly
      assembly {
        let ptr := mload(0x40)
        let size := returndatasize()
        returndatacopy(ptr, 0, size)
        revert(ptr, size)
      }
    }

    //pay back flashloan
    IERC20(IPool(pool).collateralToken()).safeTransfer(msg.sender, amount1 + fee1);
  }


}
