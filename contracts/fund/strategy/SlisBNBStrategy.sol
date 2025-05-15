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
  
  event BinanceWalletChanged(address previousBinanceWallet, address binanceWallet);
  event Deposit(uint256 WBNBAmount, uint256 toSlisBNBAmount);
  event Withdraw(uint256 WBNBamount, uint256 fromSlisBNBAmount, address recipient);

  address public immutable LISTA; //ListaStakeManager
  address public immutable SWAPROUTER; //PancakeSwap v3 SwapRouter
  uint256 public immutable SLIPPAGE; //slippage for swap, / 10000
  address public immutable ASSET; //WBNB
  address public immutable STOKEN; //slisBNB
  uint256 public principal;
  address public binanceWallet; //Binance Web3 MPC wallet

  constructor(
    address _admin,
    address _operator,
    address _listaStakeManager,
    address _swapRouter,
    address _binanceWallet,
    uint256 _slippage,
    address _asset,
    address _stoken
  ) StrategyBase(_admin, _operator) {
    LISTA = _listaStakeManager;
    SWAPROUTER = _swapRouter;
    binanceWallet = _binanceWallet;
    SLIPPAGE = _slippage;
    ASSET = _asset;
    STOKEN = _stoken;

    IERC20(STOKEN).forceApprove(SWAPROUTER, type(uint256).max);
  }

  //set walletAddress zero address to disable depositing to Binance Web3 MPC wallet
  function setBinanceWallet(address walletAddress) external onlyRole(DEFAULT_ADMIN_ROLE) {
    if (binanceWallet != walletAddress) {
      address previousBinanceWallet = binanceWallet;
      binanceWallet = walletAddress;
      emit BinanceWalletChanged(previousBinanceWallet, walletAddress);
    }
  }

  function totalSupply() public view returns (uint256) {
    //only STOKEN in this contract
    uint256 stokenAmount = IERC20(STOKEN).balanceOf(address(this)) + IERC20(STOKEN).balanceOf(binanceWallet);
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
    uint256 slisBnbMinted = IERC20(STOKEN).balanceOf(address(this));
    //transfer to Binance Web3 MPC wallet to get Launchpool rewards
    if (binanceWallet != address(0)) {
      IERC20(STOKEN).safeTransfer(binanceWallet, slisBnbMinted);
    }
    emit Deposit(amount, slisBnbMinted);
  }

  function withdraw(uint256 amount, address recipient) public onlyOperator {
    //binanceWallet should approve this contract address to transfer slisBNB
    uint256 cachedPrincipal = principal;
    if (amount > cachedPrincipal) amount = cachedPrincipal;
    unchecked {
      principal = cachedPrincipal - amount;
    }
    uint256 stokenAmount = IListaStakeManager(LISTA).convertBnbToSnBnb(amount);
    uint256 amountInMax = stokenAmount + stokenAmount * SLIPPAGE / 10000;
    if (binanceWallet != address(0)) {
      //transfer slisBNB back
      uint256 binanceWalletBalance = IERC20(STOKEN).balanceOf(binanceWallet);
      if (binanceWalletBalance >= amountInMax) {
        IERC20(STOKEN).safeTransferFrom(binanceWallet, address(this), amountInMax);
      } else {
        IERC20(STOKEN).safeTransferFrom(binanceWallet, address(this), binanceWalletBalance);
      }
    }
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
    uint256 amountIn = ISwapRouter(SWAPROUTER).exactOutputSingle(params);
    if (binanceWallet != address(0) && IERC20(STOKEN).balanceOf(address(this)) > 0) {
      //transfer remaining slisBNB back to binanceWallet
      IERC20(STOKEN).safeTransfer(binanceWallet, IERC20(STOKEN).balanceOf(address(this)));
    }
    emit Withdraw(amount, amountIn, recipient);
  }

  function kill() external onlyOperator {
    //transfer slisBNB back
    uint256 binanceWalletBalance = IERC20(STOKEN).balanceOf(binanceWallet);
    if (binanceWallet != address(0) && binanceWalletBalance > 0) {
      IERC20(STOKEN).safeTransferFrom(binanceWallet, address(this), binanceWalletBalance);
    }
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
      uint256 amountOut = ISwapRouter(SWAPROUTER).exactInputSingle(params);
      emit Withdraw(amountOut, stokenAmount, operator);
    }
    principal = 0;
  }

  function _harvest(address receiver) internal virtual override {
    uint256 amount = totalSupply() - principal;
    if (amount > 0) {
      uint256 stokenAmount = IListaStakeManager(LISTA).convertBnbToSnBnb(amount);
      uint256 amountInMax = stokenAmount + stokenAmount * SLIPPAGE / 10000;
      if (binanceWallet != address(0)) {
        //transfer slisBNB back
        uint256 binanceWalletBalance = IERC20(STOKEN).balanceOf(binanceWallet);
        if (binanceWalletBalance >= amountInMax) {
          IERC20(STOKEN).safeTransferFrom(binanceWallet, address(this), amountInMax);
        } else {
          IERC20(STOKEN).safeTransferFrom(binanceWallet, address(this), binanceWalletBalance);
        }
      }
      amountInMax = amountInMax > IERC20(STOKEN).balanceOf(address(this)) ? IERC20(STOKEN).balanceOf(address(this)) : amountInMax;
      //swap
      ISwapRouter.ExactOutputSingleParams memory params =
        ISwapRouter.ExactOutputSingleParams({
          tokenIn: STOKEN,
          tokenOut: ASSET,
          fee: 500, // 0.05% pool fee
          recipient: receiver,
          deadline: block.timestamp + 300,
          amountOut: amount,
          amountInMaximum: amountInMax,
          sqrtPriceLimitX96: 0
        });
      uint256 amountIn = ISwapRouter(SWAPROUTER).exactOutputSingle(params);
      if (binanceWallet != address(0) && IERC20(STOKEN).balanceOf(address(this)) > 0) {
        //transfer remaining slisBNB back to binanceWallet
        IERC20(STOKEN).safeTransfer(binanceWallet, IERC20(STOKEN).balanceOf(address(this)));
      }
      emit Withdraw(amount, amountIn, receiver);
    }
  }

  receive() external payable {}

}
