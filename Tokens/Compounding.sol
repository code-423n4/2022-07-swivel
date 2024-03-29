// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.8.13;

import './Protocols.sol'; // NOTE: if size restrictions become extreme we can use ints (implicit enum)
import './LibCompound.sol';
import './LibFuse.sol';

interface IErc4626 {
  /// @dev Converts the given 'assets' (uint256) to 'shares', returning that amount
  function convertToAssets(uint256) external view returns (uint256);
}

interface ICompoundToken {
  function exchangeRateCurrent() external view returns(uint256);
}

interface IYearnVault {
  function pricePerShare() external view returns (uint256);
}

interface IAavePool {
   /// @dev Returns the normalized income of the reserve given the address of the underlying asset of the reserve
  function getReserveNormalizedIncome(address) external view returns (uint256);
}

interface IAaveToken {
  function POOL() external view returns (address);
  function UNDERLYING_ASSET_ADDRESS() external view returns (address);
}

interface IEulerToken {
  /// @notice Convert an eToken balance to an underlying amount, taking into account current exchange rate
  function convertBalanceToUnderlying(uint256) external view returns(uint256);
}

library Compounding {
  /// @param p Protocol Enum value
  /// @param c Compounding token address
  function exchangeRate(uint8 p, address c) internal view returns (uint256) {
    if (p == uint8(Protocols.Compound)) {
      return LibCompound.viewExchangeRate(ICERC20(c));
    } else if (p == uint8(Protocols.Rari)) { 
      return LibFuse.viewExchangeRate(ICERC20(c));
    } else if (p == uint8(Protocols.Yearn)) {
      return IYearnVault(c).pricePerShare();
    } else if (p == uint8(Protocols.Aave)) {
      IAaveToken aToken = IAaveToken(c);
      return IAavePool(aToken.POOL()).getReserveNormalizedIncome(aToken.UNDERLYING_ASSET_ADDRESS());
    } else if (p == uint8(Protocols.Euler)) {
      // NOTE: the 1e26 const is a degree of precision to enforce on the return
      return IEulerToken(c).convertBalanceToUnderlying(1e26);
    } else {
      // NOTE: the 1e26 const is a degree of precision to enforce on the return
      return IErc4626(c).convertToAssets(1e26);
    }
  }
}
