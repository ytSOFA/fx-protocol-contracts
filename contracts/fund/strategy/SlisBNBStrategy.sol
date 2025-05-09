// SPDX-License-Identifier: MIT

pragma solidity ^0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IWBNB} from "../../interfaces/IWBNB.sol";
import { IListaStakeManager} from "../../interfaces/IListaStakeManager.sol";
import { ISwapRouter } from "../../interfaces/Pancake/ISwapRouter.sol";
import { StrategyBase } from "./StrategyBase.sol";

contract SlisBNBStrategy is StrategyBase {
  using SafeERC20 for IERC20;

  address public immutable LISTA; //ListaStakeManager
  address public immutable SWAPROUTER; //PancakeSwap v3 SwapRouter
  uint256 public immutable SLIPPAGE; //slippage for swap, / 10000
  address public immutable ASSET; //WBNB
  address public immutable STOKEN; //slisBNB
  uint256 public principal;

  constructor(
    address _admin,
    address _operator,
    address _listaStakeManager,
    address _swapRouter,
    uint256 _slippage,
    address _asset,
    address _stoken
  ) StrategyBase(_admin, _operator) {
    LISTA = _listaStakeManager;
    SWAPROUTER = _swapRouter;
    SLIPPAGE = _slippage;
    ASSET = _asset;
    STOKEN = _stoken;

    IERC20(STOKEN).forceApprove(SWAPROUTER, type(uint256).max);
  }

  function totalSupply() public view returns (uint256) {
    //only STOKEN in this contract
    uint256 stokenAmount = IERC20(STOKEN).balanceOf(address(this));
    //convert slisBNB to BNB
    return IListaStakeManager(LISTA).convertSnBnbToBnb(stokenAmount);
  }

  function deposit(uint256 amount) external onlyOperator {
    unchecked {
      principal += amount;
    }
    //WBNB to BNB
    IWBNB(ASSET).withdraw(amount);
    //deposit BNB to lisdao, get slisBNB
    IListaStakeManager(LISTA).deposit{value: amount}();
  }

  function withdraw(uint256 amount, address recipient) public onlyOperator {
    uint256 cachedPrincipal = principal;
    if (amount > cachedPrincipal) amount = cachedPrincipal;
    unchecked {
      principal = cachedPrincipal - amount;
    }
    uint256 stokenAmount = IListaStakeManager(LISTA).convertBnbToSnBnb(amount);
    uint256 amountInMax = stokenAmount + stokenAmount * SLIPPAGE / 10000;
    amountInMax = amountInMax > IERC20(STOKEN).balanceOf(address(this)) ? IERC20(STOKEN).balanceOf(address(this)) : amountInMax;
    //swap
    ISwapRouter.ExactOutputSingleParams memory params =
      ISwapRouter.ExactOutputSingleParams({
        tokenIn: STOKEN,
        tokenOut: ASSET,
        fee: 500, // 0.05% pool fee
        recipient: recipient,
        deadline: block.timestamp + 300,
        amountOut: amount,
        amountInMaximum: amountInMax,
        sqrtPriceLimitX96: 0
      });
    ISwapRouter(SWAPROUTER).exactOutputSingle(params);
  }

  function kill() external onlyOperator {
    uint256 stokenAmount = IERC20(STOKEN).balanceOf(address(this));
    if (stokenAmount > 0) {
      uint256 assertAmount = IListaStakeManager(LISTA).convertSnBnbToBnb(stokenAmount);
      uint256 amountOutMin = assertAmount - (assertAmount * SLIPPAGE / 10000);
      ISwapRouter.ExactInputSingleParams memory params =
        ISwapRouter.ExactInputSingleParams({
          tokenIn: STOKEN,
          tokenOut: ASSET,
          fee: 500, // 0.05% pool fee
          recipient: operator,
          deadline: block.timestamp + 300,
          amountIn: stokenAmount,
          amountOutMinimum: amountOutMin,
          sqrtPriceLimitX96: 0
        });
      ISwapRouter(SWAPROUTER).exactInputSingle(params);
    }
    principal = 0;
  }

  function _harvest(address receiver) internal virtual override {
    uint256 rewards = totalSupply() - principal;

    if (rewards > 0) {
      withdraw(rewards, receiver);
    }
  }

  receive() external payable {}

}
