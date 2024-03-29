// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.8.13;

import './Interfaces.sol';
import './Protocols.sol';
import './Hash.sol';
import './Sig.sol';
import './Safe.sol';

contract Swivel {
  /// @dev A single custom error capable of indicating a wide range of detected errors by providing
  /// an error code value whose string representation is documented <here>, and any possible other values
  /// that are pertinent to the error.
  error Exception(uint8, uint256, uint256, address, address);
  /// @dev maps the key of an order to a boolean indicating if an order was cancelled
  mapping (bytes32 => bool) public cancelled;
  /// @dev maps the key of an order to an amount representing its taken volume
  mapping (bytes32 => uint256) public filled;
  /// @dev maps a token address to a point in time, a hold, after which a withdrawal can be made
  mapping (address => uint256) public withdrawals;
  /// @dev maps a token address to a point in time, a hold, after which an approval can be made
  mapping (address => uint256) public approvals;

  string constant public NAME = 'Swivel Finance';
  string constant public VERSION = '3.0.0';
  uint256 constant public HOLD = 3 days;
  bytes32 public immutable domain;
  address public immutable marketPlace;
  address public admin;
  
  /// @dev address of a deployed Aave contract implementing IAave
  address public aaveAddr; // TODO immutable?

  uint16 constant public MIN_FEENOMINATOR = 33;
  /// @dev holds the fee demoninators for [zcTokenInitiate, zcTokenExit, vaultInitiate, vaultExit]
  uint16[4] public feenominators;
  /// @dev A point in time, a hold, after which a change to Fees
  uint256 public feeChange;

  /// @notice Emitted on order cancellation
  event Cancel (bytes32 indexed key, bytes32 hash);
  /// @notice Emitted on any initiate*
  /// @dev filled is 'principalFilled' when (vault:false, exit:false) && (vault:true, exit:true)
  /// @dev filled is 'premiumFilled' when (vault:true, exit:false) && (vault:false, exit:true)
  event Initiate(bytes32 indexed key, bytes32 hash, address indexed maker, bool vault, bool exit, address indexed sender, uint256 amount, uint256 filled);
  /// @notice Emitted on any exit*
  /// @dev filled is 'principalFilled' when (vault:false, exit:false) && (vault:true, exit:true)
  /// @dev filled is 'premiumFilled' when (vault:true, exit:false) && (vault:false, exit:true)
  event Exit(bytes32 indexed key, bytes32 hash, address indexed maker, bool vault, bool exit, address indexed sender, uint256 amount, uint256 filled);
  /// @notice Emitted on token withdrawal scheduling
  event ScheduleWithdrawal(address indexed token, uint256 hold);
  /// @notice Emitted on token withdrawal blocking
  event BlockWithdrawal(address indexed token);
  /// @notice Emitted on a change to the feenominators array
  event SetFee(uint256 indexed index, uint256 indexed feenominator);
  /// @notice Emitted on a token approval scheduling
  event ScheduleApproval(address indexed token, uint256 hold);
  /// @notice Emitted on a token approval blocking
  event BlockApproval(address indexed token);
  /// @notice Emitted on a fee change scheduling
  event ScheduleFeeChange(uint256 hold);
  /// @notice Emitted on a fee change blocking
  event BlockFeeChange();

  /// @param m Deployed MarketPlace contract address
  /// @param a Address of a deployed Aave contract implementing our interface
  constructor(address m, address a) {
    admin = msg.sender;
    domain = Hash.domain(NAME, VERSION, block.chainid, address(this));
    marketPlace = m;
    aaveAddr = a;
    feenominators = [200, 600, 400, 200];
  }

  // ********* INITIATING *************

  /// @notice Allows a user to initiate a position
  /// @param o Array of offline Swivel.Orders
  /// @param a Array of order volume (principal) amounts relative to passed orders
  /// @param c Array of Components from valid ECDSA signatures
  function initiate(Hash.Order[] calldata o, uint256[] calldata a, Sig.Components[] calldata c) external returns (bool) {
    uint256 len = o.length;
    // for each order filled, routes the order to the right interaction depending on its params
    for (uint256 i; i < len;) {
      Hash.Order memory order = o[i];
      if (!order.exit) {
        if (!order.vault) {
          initiateVaultFillingZcTokenInitiate(o[i], a[i], c[i]);
        } else {
          initiateZcTokenFillingVaultInitiate(o[i], a[i], c[i]);
        }
      } else {
        if (!order.vault) {
          initiateZcTokenFillingZcTokenExit(o[i], a[i], c[i]);
        } else {
          initiateVaultFillingVaultExit(o[i], a[i], c[i]);
        }
      }
      unchecked {i++;}
    }

    return true;
  }

  /// @notice Allows a user to initiate a Vault by filling an offline zcToken initiate order
  /// @dev This method should pass (underlying, maturity, maker, sender, principalFilled) to MarketPlace.custodialInitiate
  /// @param o Order being filled
  /// @param a Amount of volume (premium) being filled by the taker's initiate
  /// @param c Components of a valid ECDSA signature
  function initiateVaultFillingZcTokenInitiate(Hash.Order calldata o, uint256 a, Sig.Components calldata c) internal {
    // checks order signature, order cancellation and order expiry
    bytes32 hash = validOrderHash(o, c);

    // checks the side, and the amount compared to available
    uint256 amount = a + filled[hash];

    if (amount > o.premium) { revert Exception(5, amount, o.premium, address(0), address(0)); }
    
    // TODO cheaper to assign amount here or keep the ADD?
    filled[hash] += a;

    // transfer underlying tokens
    IErc20 uToken = IErc20(o.underlying);
    Safe.transferFrom(uToken, msg.sender, o.maker, a);

    uint256 principalFilled = (a * o.principal) / o.premium;
    Safe.transferFrom(uToken, o.maker, address(this), principalFilled);

    IMarketPlace mPlace = IMarketPlace(marketPlace);
    address cTokenAddr = mPlace.cTokenAddress(o.protocol, o.underlying, o.maturity);

    // perform the actual deposit type transaction, specific to a protocol
    if (!deposit(o.protocol, o.underlying, cTokenAddr, principalFilled)) { revert Exception(6, 0, 0, address(0), address(0)); }

    // alert marketplace
    if (!mPlace.custodialInitiate(o.protocol, o.underlying, o.maturity, o.maker, msg.sender, principalFilled)) { revert Exception(8, 0, 0, address(0), address(0)); }

    // transfer fee in vault notional to swivel (from msg.sender)
    uint256 fee = principalFilled / feenominators[2];
    if (!mPlace.transferVaultNotionalFee(o.protocol, o.underlying, o.maturity, msg.sender, fee)) { revert Exception(10, 0, 0, address(0), address(0)); }

    emit Initiate(o.key, hash, o.maker, o.vault, o.exit, msg.sender, a, principalFilled);
  }

  /// @notice Allows a user to initiate a zcToken by filling an offline vault initiate order
  /// @dev This method should pass (underlying, maturity, sender, maker, a) to MarketPlace.custodialInitiate
  /// @param o Order being filled
  /// @param a Amount of volume (principal) being filled by the taker's initiate
  /// @param c Components of a valid ECDSA signature
  function initiateZcTokenFillingVaultInitiate(Hash.Order calldata o, uint256 a, Sig.Components calldata c) internal {
    bytes32 hash = validOrderHash(o, c);
    uint256 amount = a + filled[hash];

    if (amount > o.principal) { revert Exception(5, amount, o.principal, address(0), address(0)); }

    // TODO assign amount or keep the ADD?
    filled[hash] += a;

    IErc20 uToken = IErc20(o.underlying);

    uint256 premiumFilled = (a * o.premium) / o.principal;
    Safe.transferFrom(uToken, o.maker, msg.sender, premiumFilled);

    // transfer principal + fee in underlying to swivel (from sender)
    uint256 fee = premiumFilled / feenominators[0];
    Safe.transferFrom(uToken, msg.sender, address(this), (a + fee));

    IMarketPlace mPlace = IMarketPlace(marketPlace);
    address cTokenAddr = mPlace.cTokenAddress(o.protocol, o.underlying, o.maturity);

    // perform the actual deposit type transaction, specific to a protocol
    if(!deposit(o.protocol, o.underlying, cTokenAddr, a)) { revert Exception(6, 0, 0, address(0), address(0)); }

    // alert marketplace 
    if (!mPlace.custodialInitiate(o.protocol, o.underlying, o.maturity, msg.sender, o.maker, a)) { revert Exception(8, 0, 0, address(0), address(0)); }

    emit Initiate(o.key, hash, o.maker, o.vault, o.exit, msg.sender, a, premiumFilled);
  }

  /// @notice Allows a user to initiate zcToken? by filling an offline zcToken exit order
  /// @dev This method should pass (underlying, maturity, maker, sender, a) to MarketPlace.p2pZcTokenExchange
  /// @param o Order being filled
  /// @param a Amount of volume (principal) being filled by the taker's initiate 
  /// @param c Components of a valid ECDSA signature
  function initiateZcTokenFillingZcTokenExit(Hash.Order calldata o, uint256 a, Sig.Components calldata c) internal {
    bytes32 hash = validOrderHash(o, c);
    uint256 amount = a + filled[hash];

    if (amount > o.principal) { revert Exception(5, amount, o.principal, address(0), address(0)); }

    // TODO assign amount or keep the ADD?
    filled[hash] += a;

    uint256 premiumFilled = (a * o.premium) / o.principal;

    IErc20 uToken = IErc20(o.underlying);
    // transfer underlying tokens, then take fee
    Safe.transferFrom(uToken, msg.sender, o.maker, a - premiumFilled);

    uint256 fee = premiumFilled / feenominators[0];
    Safe.transferFrom(uToken, msg.sender, address(this), fee);

    // alert marketplace
    if (!IMarketPlace(marketPlace).p2pZcTokenExchange(o.protocol, o.underlying, o.maturity, o.maker, msg.sender, a)) { revert Exception(11, 0, 0, address(0), address(0)); }
            
    emit Initiate(o.key, hash, o.maker, o.vault, o.exit, msg.sender, a, premiumFilled);
  }

  /// @notice Allows a user to initiate a Vault by filling an offline vault exit order
  /// @dev This method should pass (underlying, maturity, maker, sender, principalFilled) to MarketPlace.p2pVaultExchange
  /// @param o Order being filled
  /// @param a Amount of volume (interest) being filled by the taker's exit
  /// @param c Components of a valid ECDSA signature
  function initiateVaultFillingVaultExit(Hash.Order calldata o, uint256 a, Sig.Components calldata c) internal {
    bytes32 hash = validOrderHash(o, c);
    uint256 amount = a + filled[hash];

    if (amount > o.premium) { revert Exception(5, amount, o.premium, address(0), address(0)); }

    // TODO assign amount or keep ADD?
    filled[hash] += a;

    Safe.transferFrom(IErc20(o.underlying), msg.sender, o.maker, a);

    IMarketPlace mPlace = IMarketPlace(marketPlace);
    uint256 principalFilled = (a * o.principal) / o.premium;
    // alert marketplace
    if (!mPlace.p2pVaultExchange(o.protocol, o.underlying, o.maturity, o.maker, msg.sender, principalFilled)) { revert Exception(12, 0, 0, address(0), address(0)); }

    // transfer fee (in vault notional) to swivel
    uint256 fee = principalFilled / feenominators[2];
    if (!mPlace.transferVaultNotionalFee(o.protocol, o.underlying, o.maturity, msg.sender, fee)) { revert Exception(10, 0, 0, address(0), address(0)); }

    emit Initiate(o.key, hash, o.maker, o.vault, o.exit, msg.sender, a, principalFilled);
  }

  // ********* EXITING ***************

  /// @notice Allows a user to exit (sell) a currently held position to the marketplace.
  /// @param o Array of offline Swivel.Orders
  /// @param a Array of order volume (principal) amounts relative to passed orders
  /// @param c Components of a valid ECDSA signature
  function exit(Hash.Order[] calldata o, uint256[] calldata a, Sig.Components[] calldata c) external returns (bool) {
    uint256 len = o.length;
    // for each order filled, routes the order to the right interaction depending on its params
    for (uint256 i; i < len;) {
      Hash.Order memory order = o[i];
      // if the order being filled is not an exit
      if (!order.exit) {
        // if the order being filled is a vault initiate or a zcToken initiate
          if (!order.vault) {
            // if filling a zcToken initiate with an exit, one is exiting zcTokens
            exitZcTokenFillingZcTokenInitiate(o[i], a[i], c[i]);
          } else {
            // if filling a vault initiate with an exit, one is exiting vault notional
            exitVaultFillingVaultInitiate(o[i], a[i], c[i]);
          }
      } else {
        // if the order being filled is a vault exit or a zcToken exit
        if (!order.vault) {
          // if filling a zcToken exit with an exit, one is exiting vault
          exitVaultFillingZcTokenExit(o[i], a[i], c[i]);
        } else {
          // if filling a vault exit with an exit, one is exiting zcTokens
          exitZcTokenFillingVaultExit(o[i], a[i], c[i]);
        }   
      }
      unchecked {i++;}
    }

    return true;
  }

  /// @notice Allows a user to exit their zcTokens by filling an offline zcToken initiate order
  /// @dev This method should pass (underlying, maturity, sender, maker, principalFilled) to MarketPlace.p2pZcTokenExchange
  /// @param o Order being filled
  /// @param a Amount of volume (interest) being filled by the taker's exit
  /// @param c Components of a valid ECDSA signature
  function exitZcTokenFillingZcTokenInitiate(Hash.Order calldata o, uint256 a, Sig.Components calldata c) internal {
    bytes32 hash = validOrderHash(o, c);
    uint256 amount = a + filled[hash];

    if (amount > o.premium) { revert Exception(5, amount, o.premium, address(0), address(0)); }

    // TODO assign amount or keep the ADD?
    filled[hash] += a;       

    IErc20 uToken = IErc20(o.underlying);

    uint256 principalFilled = (a * o.principal) / o.premium;
    // transfer underlying from initiating party to exiting party, minus the price the exit party pays for the exit (premium), and the fee.
    Safe.transferFrom(uToken, o.maker, msg.sender, principalFilled - a);

    // transfer fee in underlying to swivel
    uint256 fee = principalFilled / feenominators[1];

    Safe.transferFrom(uToken, msg.sender, address(this), fee);

    // alert marketplace
    if (!IMarketPlace(marketPlace).p2pZcTokenExchange(o.protocol, o.underlying, o.maturity, msg.sender, o.maker, principalFilled)) { revert Exception(11, 0, 0, address(0), address(0)); }

    emit Exit(o.key, hash, o.maker, o.vault, o.exit, msg.sender, a, principalFilled);
  }
  
  /// @notice Allows a user to exit their Vault by filling an offline vault initiate order
  /// @dev This method should pass (underlying, maturity, sender, maker, a) to MarketPlace.p2pVaultExchange
  /// @param o Order being filled
  /// @param a Amount of volume (principal) being filled by the taker's exit
  /// @param c Components of a valid ECDSA signature
  function exitVaultFillingVaultInitiate(Hash.Order calldata o, uint256 a, Sig.Components calldata c) internal {
    bytes32 hash = validOrderHash(o, c);
    uint256 amount = a + filled[hash];

    if (amount > o.principal) { revert Exception(5, amount, o.principal, address(0), address(0)); }
    
    // TODO assign amount or keep the ADD?
    filled[hash] += a;
        
    IErc20 uToken = IErc20(o.underlying);

    // transfer premium from maker to sender
    uint256 premiumFilled = (a * o.premium) / o.principal;
    Safe.transferFrom(uToken, o.maker, msg.sender, premiumFilled);

    uint256 fee = premiumFilled / feenominators[3];
    // transfer fee in underlying to swivel from sender
    Safe.transferFrom(uToken, msg.sender, address(this), fee);

    // transfer <a> notional from sender to maker
    if (!IMarketPlace(marketPlace).p2pVaultExchange(o.protocol, o.underlying, o.maturity, msg.sender, o.maker, a)) { revert Exception(12, 0, 0, address(0), address(0)); }

    emit Exit(o.key, hash, o.maker, o.vault, o.exit, msg.sender, a, premiumFilled);
  }

  /// @notice Allows a user to exit their Vault filling an offline zcToken exit order
  /// @dev This method should pass (underlying, maturity, maker, sender, a) to MarketPlace.exitFillingExit
  /// @param o Order being filled
  /// @param a Amount of volume (principal) being filled by the taker's exit
  /// @param c Components of a valid ECDSA signature
  function exitVaultFillingZcTokenExit(Hash.Order calldata o, uint256 a, Sig.Components calldata c) internal {
    bytes32 hash = validOrderHash(o, c);
    uint256 amount = a + filled[hash];

    if (amount > o.principal) { revert Exception(5, amount, o.principal, address(0), address(0)); }

    // TODO assign amount or keep the ADD?
    filled[hash] += a;

    // redeem underlying on Compound and burn cTokens
    IMarketPlace mPlace = IMarketPlace(marketPlace);
    address cTokenAddr = mPlace.cTokenAddress(o.protocol, o.underlying, o.maturity);

    if (!withdraw(o.protocol, o.underlying, cTokenAddr, a)) { revert Exception(7, 0, 0, address(0), address(0)); }

    IErc20 uToken = IErc20(o.underlying);
    // transfer principal-premium  back to fixed exit party now that the interest coupon and zcb have been redeemed
    uint256 premiumFilled = (a * o.premium) / o.principal;
    Safe.transfer(uToken, o.maker, a - premiumFilled);

    // transfer premium-fee to floating exit party
    uint256 fee = premiumFilled / feenominators[3];
    Safe.transfer(uToken, msg.sender, premiumFilled - fee);

    // burn zcTokens + nTokens from o.maker and msg.sender respectively
    if (!mPlace.custodialExit(o.protocol, o.underlying, o.maturity, o.maker, msg.sender, a)) { revert Exception(9, 0, 0, address(0), address(0)); }

    emit Exit(o.key, hash, o.maker, o.vault, o.exit, msg.sender, a, premiumFilled);
  }

  /// @notice Allows a user to exit their zcTokens by filling an offline vault exit order
  /// @dev This method should pass (underlying, maturity, sender, maker, principalFilled) to MarketPlace.exitFillingExit
  /// @param o Order being filled
  /// @param a Amount of volume (interest) being filled by the taker's exit
  /// @param c Components of a valid ECDSA signature
  function exitZcTokenFillingVaultExit(Hash.Order calldata o, uint256 a, Sig.Components calldata c) internal {
    bytes32 hash = validOrderHash(o, c);
    uint256 amount = a + filled[hash];

    if (amount > o.premium) { revert Exception(5, amount, o.premium, address(0), address(0)); }
    
    // TODO assign amount or keep the ADD?
    filled[hash] += a;

    // redeem underlying on Compound and burn cTokens
    IMarketPlace mPlace = IMarketPlace(marketPlace);
    address cTokenAddr = mPlace.cTokenAddress(o.protocol, o.underlying, o.maturity);
    uint256 principalFilled = (a * o.principal) / o.premium;

    if (!withdraw(o.protocol, o.underlying, cTokenAddr, principalFilled)) { revert Exception(7, 0, 0, address(0), address(0)); }

    IErc20 uToken = IErc20(o.underlying);
    // transfer principal-premium-fee back to fixed exit party now that the interest coupon and zcb have been redeemed
    uint256 fee = principalFilled / feenominators[1];
    Safe.transfer(uToken, msg.sender, principalFilled - a - fee);
    Safe.transfer(uToken, o.maker, a);

    // burn <principalFilled> zcTokens + nTokens from msg.sender and o.maker respectively
    if (!mPlace.custodialExit(o.protocol, o.underlying, o.maturity, msg.sender, o.maker, principalFilled)) { revert Exception(9, 0, 0, address(0), address(0)); }

    emit Exit(o.key, hash, o.maker, o.vault, o.exit, msg.sender, a, principalFilled);
  }

  /// @notice Allows a user to cancel an order, preventing it from being filled in the future
  /// @param o Order being cancelled
  /// @param c Components of a valid ECDSA signature
  function cancel(Hash.Order[] calldata o, Sig.Components[] calldata c) external returns (bool) {
    uint256 len = o.length;
    for (uint256 i; i < len;) {
      bytes32 hash = validOrderHash(o[i], c[i]);
      if (msg.sender != o[i].maker) { revert Exception(15, 0, 0, msg.sender, o[i].maker); }

      cancelled[hash] = true;

      emit Cancel(o[i].key, hash);

      unchecked {
        i++;
      }
    }

    return true;
  }

  // ********* ADMINISTRATIVE ***************

  /// @param a Address of a new admin
  function setAdmin(address a) external authorized(admin) returns (bool) {
    admin = a;

    return true;
  }

  /// @notice Allows the admin to schedule the withdrawal of tokens
  /// @param e Address of (erc20) token to withdraw
  function scheduleWithdrawal(address e) external authorized(admin) returns (bool) {
    uint256 when = block.timestamp + HOLD;
    withdrawals[e] = when;

    emit ScheduleWithdrawal(e, when);

    return true;
  }

  /// @notice Emergency function to block unplanned withdrawals
  /// @param e Address of token withdrawal to block
  function blockWithdrawal(address e) external authorized(admin) returns (bool) {
      withdrawals[e] = 0;

      emit BlockWithdrawal(e);

      return true;
  }

  /// @notice Allows the admin to withdraw the given token, provided the holding period has been observed
  /// @param e Address of token to withdraw
  function withdraw(address e) external authorized(admin) returns (bool) {
    uint256 when = withdrawals[e];

    if (when == 0) { revert Exception(16, 0, 0, address(0), address(0)); }

    if (block.timestamp < when) { revert Exception(17, block.timestamp, when, address(0), address(0)); }

    withdrawals[e] = 0;

    IErc20 token = IErc20(e);
    Safe.transfer(token, admin, token.balanceOf(address(this)));

    return true;
  }

  /// @notice Allows the admin to schedule the change of fees
  function scheduleFeeChange() external authorized(admin) returns (bool) {
    uint256 when = block.timestamp + HOLD;
    feeChange = when;

    emit ScheduleFeeChange(when);

    return true;
  }

  /// @notice Emergency function to block unplanned withdrawals
  function blockFeeChange() external authorized(admin) returns (bool) {
      feeChange = 0;

      emit BlockFeeChange();

      return true;
  }


  /// @notice Allows the admin to set a new fee denominator
  /// @param i The index of the new fee denominator
  /// @param d The new fee denominator
  function setFee(uint16[] memory i, uint16[] memory d) external authorized(admin) returns (bool) {
    uint256 len = i.length;

    if (len != d.length) { revert Exception(19, len, d.length, address(0), address(0)); }

    if (feeChange == 0) { revert Exception(16, 0, 0, address(0), address(0)); }

    if (block.timestamp < feeChange) { revert Exception(17, block.timestamp, feeChange, address(0), address(0)); }

    for (uint256 x; x < len;) {
      if (d[x] < MIN_FEENOMINATOR) { revert Exception(18, uint256(d[x]), 0, address(0), address(0)); }

      feenominators[x] = d[x];
      emit SetFee(i[x], d[x]);

      unchecked {
        x++;
      }
    }

    feeChange = 0;

    return true;
  }

  /// @notice Allows the admin to schedule the approval of tokens
  /// @param e Address of (erc20) token to withdraw
  function scheduleApproval(address e) external authorized(admin) returns (bool) {
    uint256 when = block.timestamp + HOLD;
    approvals[e] = when;

    emit ScheduleApproval(e, when);

    return true;
  }

  /// @notice Emergency function to block unplanned withdrawals
  /// @param e Address of token approval to block
  function blockApproval(address e) external authorized(admin) returns (bool) {
      approvals[e] = 0;

      emit BlockApproval(e);

      return true;
  }

  /// @notice Allows the admin to bulk approve given compound addresses at the underlying token, saving marginal approvals
  /// @param u array of underlying token addresses
  /// @param c array of compound token addresses
  function approveUnderlying(address[] calldata u, address[] calldata c) external authorized(admin) returns (bool) {
    uint256 len = u.length;

    if (len != c.length) { revert Exception(19, len, c.length, address(0), address(0)); }

    uint256 max = 2**256 - 1;
    uint256 when;

    for (uint256 i; i < len;) {
      when = approvals[u[i]];

      if (when == 0) { revert Exception(16, 0, 0, address(0), address(0)); }

      if (block.timestamp < when) { revert Exception(17, block.timestamp, when, address(0), address(0));
      }

      approvals[u[i]] = 0;
      IErc20 uToken = IErc20(u[i]);
      Safe.approve(uToken, c[i], max);
      unchecked {
        i++;
      }
    }

    return true;
  }
  // ********* PROTOCOL UTILITY ***************

  /// @notice Allows users to deposit underlying and in the process split it into/mint 
  /// zcTokens and vault notional. Calls mPlace.mintZcTokenAddingNotional
  /// @param p Protocol Enum value associated with this market pair
  /// @param u Underlying token address associated with this market pair
  /// @param m Maturity timestamp of this associated market
  /// @param a Amount of underlying being deposited
  function splitUnderlying(uint8 p, address u, uint256 m, uint256 a) external returns (bool) {
    IErc20 uToken = IErc20(u);
    Safe.transferFrom(uToken, msg.sender, address(this), a);

    IMarketPlace mPlace = IMarketPlace(marketPlace);
    
    // the underlying deposit is directed to the appropriate abstraction
    if (!deposit(p, u, mPlace.cTokenAddress(p, u, m), a)) { revert Exception(6, 0, 0, address(0), address(0));
    }

    if (!mPlace.mintZcTokenAddingNotional(p, u, m, msg.sender, a)) { revert Exception(13, 0, 0, address(0), address(0));
    }

    return true;
  }

  /// @notice Allows users deposit/burn 1-1 amounts of both zcTokens and vault notional,
  /// in the process "combining" the two, and redeeming underlying. Calls mPlace.burnZcTokenRemovingNotional.
  /// @param p Protocol Enum value associated with this market pair
  /// @param u Underlying token address associated with the market
  /// @param m Maturity timestamp of the market
  /// @param a Amount of zcTokens being redeemed
  function combineTokens(uint8 p, address u, uint256 m, uint256 a) external returns (bool) {
    IMarketPlace mPlace = IMarketPlace(marketPlace);

    if (!mPlace.burnZcTokenRemovingNotional(p, u, m, msg.sender, a)) { revert Exception(14, 0, 0, address(0), address(0));
    }

    if (!withdraw(p, u, mPlace.cTokenAddress(p, u, m), a)) { revert Exception(7, 0, 0, address(0), address(0));
    }

    Safe.transfer(IErc20(u), msg.sender, a);

    return true;
  }

  /// @notice Allows users to redeem zcTokens and withdraw underlying, boiling up from the zcToken instead of starting on Swivel
  /// @notice p Protocol Enum value associated with this market pair
  /// @param u Underlying token address associated with this market pair
  /// @param c Compound token address associated with this market pair
  /// @param t Address of the user receiving the underlying tokens
  /// @param a Amount of underlying being redeemed
  function authRedeemZcToken(uint8 p, address u, address c, address t, uint256 a) external authorized(marketPlace) returns(bool) {
    // redeem underlying from compounding
    if (!withdraw(p, u, c, a)) { revert Exception(7, 0, 0, address(0), address(0)); }
    // transfer underlying back to msg.sender
    Safe.transfer(IErc20(u), t, a);

    return (true);
  }

  /// @notice Allows zcToken holders to redeem their tokens for underlying tokens after maturity has been reached (via MarketPlace).
  /// @param p Protocol Enum value associated with this market pair
  /// @param u Underlying token address associated with the market
  /// @param m Maturity timestamp of the market
  /// @param a Amount of zcTokens being redeemed
  function redeemZcToken(uint8 p, address u, uint256 m, uint256 a) external returns (bool) {
    IMarketPlace mPlace = IMarketPlace(marketPlace);
    // call marketplace to determine the amount redeemed
    uint256 redeemed = mPlace.redeemZcToken(p, u, m, msg.sender, a);
    // redeem underlying from compounding
    if (!withdraw(p, u, mPlace.cTokenAddress(p, u, m), redeemed)) { revert Exception(7, 0, 0, address(0), address(0)); }

    // transfer underlying back to msg.sender
    Safe.transfer(IErc20(u), msg.sender, redeemed);

    return true;
  }

  /// @notice Allows Vault owners to redeem any currently accrued interest (via MarketPlace)
  /// @param p Protocol Enum value associated with this market pair
  /// @param u Underlying token address associated with the market
  /// @param m Maturity timestamp of the market
  function redeemVaultInterest(uint8 p, address u, uint256 m) external returns (bool) {
    IMarketPlace mPlace = IMarketPlace(marketPlace);
    // call marketplace to determine the amount redeemed
    uint256 redeemed = mPlace.redeemVaultInterest(p, u, m, msg.sender);
    // redeem underlying from compounding
    address cTokenAddr = mPlace.cTokenAddress(p, u, m);

    if (!withdraw(p, u, cTokenAddr, redeemed)) { revert Exception(7, 0, 0, address(0), address(0)); }

    // transfer underlying back to msg.sender
    Safe.transfer(IErc20(u), msg.sender, redeemed);

    return true;
  }

  /// @notice Allows Swivel to redeem any currently accrued interest (via MarketPlace)
  /// @param p Protocol Enum value associated with this market pair
  /// @param u Underlying token address associated with the market
  /// @param m Maturity timestamp of the market
  function redeemSwivelVaultInterest(uint8 p, address u, uint256 m) external returns (bool) {
    IMarketPlace mPlace = IMarketPlace(marketPlace);
    // call marketplace to determine the amount redeemed
    uint256 redeemed = mPlace.redeemVaultInterest(p, u, m, address(this));
    // redeem underlying from compounding
    if (!withdraw(p, u, mPlace.cTokenAddress(p, u, m), redeemed)) { revert Exception(7, 0, 0, address(0), address(0)); }

    // NOTE: for swivel reddem there is no transfer out as there is in redeemVaultInterest

    return true;
  }

  /// @notice Varifies the validity of an order and it's signature.
  /// @param o An offline Swivel.Order
  /// @param c Components of a valid ECDSA signature
  /// @return the hashed order.
  function validOrderHash(Hash.Order calldata o, Sig.Components calldata c) internal view returns (bytes32) {
    bytes32 hash = Hash.order(o);

    if (cancelled[hash]) { revert Exception(2, 0, 0, address(0), address(0)); }

    if (o.expiry < block.timestamp) { revert Exception(3, o.expiry, block.timestamp, address(0), address(0)); }

    address recovered = Sig.recover(Hash.message(domain, hash), c);

    if (o.maker != recovered) { revert Exception(4, 0, 0, o.maker, recovered); }

    return hash;
  }

  /// @notice Use the Protocol Enum to direct deposit type transactions to their specific library abstraction
  /// @dev This functionality is an abstraction used by `IVFZI`, `IZFVI` and `splitUnderlying`
  /// @param p Protocol Enum Value
  /// @param u Address of an underlying token (used by Aave)
  /// @param c Compounding token address
  /// @param a Amount to deposit
  function deposit(uint8 p, address u, address c, uint256 a) internal returns (bool) {
    // TODO as stated elsewhere, we may choose to simply return true in all and not attempt to measure against any expected return
    if (p == uint8(Protocols.Compound)) { // TODO is Rari a drop in here?
      return ICompound(c).mint(a) == 0;
    } else if (p == uint8(Protocols.Yearn)) {
      // yearn vault api states that deposit returns shares as uint256
      return IYearn(c).deposit(a) >= 0;
    } else if (p == uint8(Protocols.Aave)) {
      // Aave deposit is void. NOTE the change in pattern here where our interface is not wrapping a compounding token directly, but
      // a specified protocol contract whose address we have set
      // TODO explain the Aave deposit args
      IAave(aaveAddr).deposit(u, a, address(this), 0);
      return true;
    } else if (p == uint8(Protocols.Euler)) {
      // Euler deposit is void.
      // TODO explain the 0 (primary account)
      IEuler(c).deposit(0, a);
      return true;
    } else {
      // we will allow protocol[0] to also function as a catchall for Erc4626
      // NOTE: deposit, as per the spec, returns 'shares' but it is unknown if 0 would revert, thus we'll check for 0 or greater
      return IErc4626(c).deposit(a, address(this)) >= 0;
    }
  }

  /// @notice Use the Protocol Enum to direct withdraw type transactions to their specific library abstraction
  /// @dev This functionality is an abstraction used by `EVFZE`, `EZFVE`, `combineTokens`, `redeemZcToken` and `redeemVaultInterest`.
  /// Note that while there is an external method `withdraw` also on this contract the unique method signatures (and visibility)
  /// exclude any possible clashing
  /// @param p Protocol Enum Value
  /// @param u Address of an underlying token (used by Aave)
  /// @param c Compounding token address
  /// @param a Amount to withdraw
  function withdraw(uint8 p, address u, address c, uint256 a) internal returns (bool) {
    // TODO as stated elsewhere, we may choose to simply return true in all and not attempt to measure against any expected return
    if (p == uint8(Protocols.Compound)) { // TODO is Rari a drop in here?
      return ICompound(c).redeemUnderlying(a) == 0;
    } else if (p == uint8(Protocols.Yearn)) {
      // yearn vault api states that withdraw returns uint256
      return IYearn(c).withdraw(a) >= 0;
    } else if (p == uint8(Protocols.Aave)) {
      // Aave v2 docs state that withraw returns uint256
      // TODO explain the withdraw args
      return IAave(aaveAddr).withdraw(u, a, address(this)) >= 0;
    } else if (p == uint8(Protocols.Euler)) {
      // Euler withdraw is void
      // TODO explain the 0
      IEuler(c).withdraw(0, a);
      return true;
    } else {
      // we will allow protocol[0] to also function as a catchall for Erc4626
      return IErc4626(c).withdraw(a, address(this), address(this)) >= 0;
    }
  }

  modifier authorized(address a) {
    if(msg.sender != a) { revert Exception(0, 0, 0, msg.sender, a); }
    _;
  }
}
