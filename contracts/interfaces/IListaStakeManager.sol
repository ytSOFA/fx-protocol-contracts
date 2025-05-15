// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IListaStakeManager {
    function deposit() external payable;
    function convertSnBnbToBnb(uint256 _amountInSlisBnb) external view returns (uint256);
    function convertBnbToSnBnb(uint256 _amount) external view returns (uint256);
}