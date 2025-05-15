// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IPancakeV2 {
    /// @notice Receive token0 and/or token1 and pay it back, plus a fee, in the callback
    /// @dev The caller of this method receives a callback in the form of pancakeCall
    /// @param amount0Out The amount of token0 to send
    /// @param amount1Out The amount of token1 to send
    /// @param to The address which will receive the token0 and token1 amounts
    /// @param data Any data to be passed through to the callback
    function swap(
        uint amount0Out, 
        uint amount1Out, 
        address to, 
        bytes calldata data
    ) external;
}