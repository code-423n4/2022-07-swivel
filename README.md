# Swivel v3 contest details
- $33,250 USDC main award pot
- $1,750 USDC gas optimization award pot
- Join [C4 Discord](https://discord.gg/code4rena) to register
- Submit findings [using the C4 form](https://code4rena.com/contests/2022-07-swivel-v3-contest/submit)
- [Read our guidelines for more details](https://docs.code4rena.com/roles/wardens)
- Starts July 12, 2022 20:00 UTC
- Ends July 15, 2022 20:00 UTC

# Introduction To Swivel

Swivel is a yield tokenization protocol that allows LP's, ETH stakers and lenders to separate their yield into two components, zcTokens -- EIP-5095 Compliant (which represent the 1-1 claim to deposited tokens upon maturity), and nTokens (which represent the claim to any yield generated). In addition to this base functionality, Swivel provides the infrastructure to facilitate the exchange of these tokens through an orderbook.

Regarding our orderbook infrastructure, the base orderbook functionality is most similar to the original 0x-v3. Users EIP-712 sign an order object which contains information regarding protocol integrated, asset, maturity, maker, price, amount, and two bools which help indicate which path to execute the order, (`exit`/`vault`) which indicate whether the user is exiting a currently held position and/or interacting with their "vault" to trade nTokens.

Our mainnet is currently live at https://swivel.exchange .

Our testnet is currently live at https://rinkeby.swivel.exchange . 

General Project Docs: https://docs.swivel.finance

Contract Docs: https://docs.swivel.finance/developers/contract 

Our Testing Suite: https://github.com/Swivel-Finance/gost/tree/v3 

Old v2 Overview (ETHOnline): https://www.youtube.com/watch?v=hI0Uwd4Xayg 

## **New In v3**

As a general focus of our audit, we would like to highlight our new features in Swivel v3. 

### Protocol Integrations

The focus of v3 is to open our protocol to nearly all large money-market integrations. This largely includes:
- Include a "protocol" enum, `p` as part of our `markets` mapping
- Creating generic `withdraw` and `deposit` methods that encapsulate all cToken or equivalent mint/redemptions.
- Creating a library, `Compounding.sol` which takes a cToken address and protocol enum and reads the exchangeRate for given external cToken integrations
- Including solmate / t11s libraries for optimized Compound protocol and Rari protocol `exchangeRate` reads

### 5095

Another focus of v3 was the integration of [EIP-5095](https://github.com/ethereum/EIPs/pull/5095). We wanted to ensure compliance and demonstrate how one could integrate a 5095 with some backwards compatable infrastructure for authorized redemptions. That said, 5095 is in flux and not finalized and 100% compliance is not to be expected. (e.g. Our previews currently return 0 before maturity, an old version of 5095.) This largely includes:
- A `ZcToken.sol` which follows the 5095 interface, and redemptions that call an authorized `IRedeemer.authRedeem`
- The addition of `MarketPlace.authRedeem` which acts as our IRedeemer and burns zcTokens then calls and authorized `Swivel.authRedeem`
- The addition of `Swivel.authRedeem` which withdraws from an external protocol and then transfers an ERC20 out

### Marketplace Split

Alongside these additions, the bytecode of `Marketplace.sol` bloated, and we needed to split the direct creation of new contracts into `Creator.sol` which acts as an external contract to deploy new markets.

## Other Information
### **Order Path:**
A taker initiates their own position using `initiate` or `exit` on Swivel.sol, in the process filling another user's order. Swivel.sol handles fund custody and deposits/withdrawals from underlying protocols (compound). Params are routed to Marketplace.sol and according to the `underlying` and `maturity` of an order, a market is identified (asset-maturity combination), and zcTokens and nTokens are minted/burnt/exchanged within that market according to the params.

Order fill amounts and cancellations are tracked on chain based on a keccak of the order itself.

### **nToken and zcToken functionality:**
When a user initiates a new fixed-yield position on our orderbook, or manually calls `splitUnderlying`, an underlying token is split into zcTokens and nTokens. (the fixed-yield comes from immediately selling nTokens).

A zcToken (ERC-5095) can be redeemed 1-1 for underlying upon maturity. After maturity, if a user has not redeemed their zcTokens, they begin accruing interest from the deposit in compound. 

An nToken (non-standard contract balance) is a balance within a users `vault`(vault.notional) within VaultTracker.sol. nTokens (notional balance) represent a deposit in an underlying protocol (compound), and accrue the interest from this deposit until maturity. This interest can be redeemed at any time.

### **Custom Errors**
We recently implemented custom errors which follow a generic pattern, `error Exception(uint8, uint256, uint256, address, address);`. This allows us to set off-chain error codes, and pass through all relevant information and comparisons that caused the revert(protocol, two amounts to compare, two addresses to compare).

A comprehensive overview of all our errors is available in the `errors.txt` file in each contract's folder.


## Important Note:

#### Input Sanitization

When it comes to input sanitization, assuming there are no externalities, we err on the side of having external interfaces validate their input, rather than socializing costs to do checks such as:

Checking for address(0)
Checking for input amounts of 0
Any similar input sanitization

#### Admin Priveleges 

We strive to ensure users can feel comfortable that there will not be rugs of their funds. We also feel strongly that there also need to be training wheels with new launches, especially when it comes to the integration of numeruous external protocols. 

That said, we retain multiple methods for approvals / withdrawals / fees / pausing gated behind admin methods to ensure the protocol can effectively safeguard user funds during the early operation of the protocol. For the most part these methods have delays to give time for users to exit. Further, the admin will always be a multi-sig.

With all this established, we are likely contesting / rejecting most admin centralization issues, unless there are remediations which do not break the ethos of our early / safeguarded launch.


# Smart Contracts 
| **Contracts**    | **Link** | **LOC** | **LIBS** | **External** |
|--------------|------|------|------|------|
| Swivel       |[Link](https://github.com/code-423n4/2022-07-swivel/blob/main/Swivel/Swivel.sol)| 765 | [Interfaces.sol](https://github.com/code-423n4/2022-07-swivel/blob/main/Swivel/Interfaces.sol), [Hash.sol](https://github.com/code-423n4/2022-07-swivel/blob/main/Swivel/Hash.sol), [Sig.sol](https://github.com/code-423n4/2022-07-swivel/blob/main/Swivel/Sig.sol), [Safe.sol](https://github.com/code-423n4/2022-07-swivel/blob/main/Swivel/Safe.sol) | [CToken.sol](https://github.com/compound-finance/compound-protocol/blob/master/contracts/CToken.sol), [AToken.sol](https://github.com/aave/protocol-v2/blob/master/contracts/protocol/tokenization/AToken.sol), [EToken.sol](https://github.com/euler-xyz/euler-contracts/blob/master/contracts/modules/EToken.sol), [yToken.sol](https://github.com/yearn/yearn-vaults/blob/main/contracts/yToken.sol), [ERC-4626](https://github.com/Rari-Capital/solmate/blob/main/src/mixins/ERC4626.sol)  |
| Marketplace  |[Link](https://github.com/code-423n4/2022-07-swivel/blob/main/Marketplace/MarketPlace.sol)| 346 | [Interfaces.sol](https://github.com/code-423n4/2022-07-swivel/blob/main/Marketplace/Interfaces.sol), [Compounding.sol](https://github.com/code-423n4/2022-07-swivel/blob/main/Marketplace/Compounding.sol), [LibCompound.sol](https://github.com/code-423n4/2022-07-swivel/blob/main/Marketplace/LibCompound.sol), [LibFuse.sol](https://github.com/code-423n4/2022-07-swivel/blob/main/Marketplace/LibFuse.sol) | Same as Swivel.sol |
| VaultTracker |[Link](https://github.com/code-423n4/2022-07-swivel/blob/main/VaultTracker/VaultTracker.sol)| 252 | Same as Marketplace.sol | Same as Swivel.sol |
| Creator |[Link](https://github.com/code-423n4/2022-07-swivel/blob/main/Creator/Creator.sol)| 66 | None | None | 
| ZcToken |[Link](https://github.com/code-423n4/2022-07-swivel/blob/main/Creator/ZcToken.sol)| 66 | None | None | 

## **Swivel:**
Swivel.sol handles all fund custody, and most all user interaction methods are on Swivel.sol (`initiate`,`exit`,`splitUnderying`,`combineTokens`, `redeemZcTokens`, `redeemVaultInterest`). We categorize all order interactions as either `payingPremium` or `receivingPremium` depending on the params (`vault` & `exit`) of an order filled, and whether a user calls `initiate` or `exit`. 

For example, if `vault` = true, the maker of an order is interacting with their vault, and if `exit` = true, they are selling notional (nTokens) and would be `receivingPremium`. Alternatively, if `vault` = false, and `exit` = false, the maker is initiating a fixed yield, and thus also splitting underlying and selling nTokens, `receivingPremium`. 

A warden, @ItsmeSTYJ was kind enough to organize a matrix which might help understand the potential interactions: 

<img src="https://user-images.githubusercontent.com/62613746/178210948-a09a3bb0-9100-462b-85df-91242e1ee82d.png" width="400">


Outside of this sorting, the basic order interaction logic is:
1. Check Signatures, Cancellations, Fill availability for order validity
2. Calculate either principalFilled or premiumFilled depending on whether the order is paying/receivingPremium
3. Calculate fee
4. Deposit/Withdraw from compound and/or exchange/mint/burn zcTokens and nTokens through marketplace.sol
5. Transfer fees

Other methods (`splitUnderying`,`combineTokens`, `redeemZcTokens`, `redeemVaultInterest`) largely just handle fund custody from underlying protocols, and shoot burn/mint commands to marketplace.sol.

## **Marketplace:**
Marketplace.sol acts as the central hub for tracking all markets (defined as an asset-matury pair). Markets are stored in a mapping and admins are the only ones that can create markets.

Any orderbook interactions that require zcToken or nToken transfers are handled through marketplace burn/mints in order to avoid requiring approvals.

If a user wants to transfer nTokens are without using our orderbook, they do so directly through the marketplace.sol contract.

## **VaultTracker:**
VaultTracker.sol acts as a contract to track the interest generated by each user in each given market. All of the data necessary for these calculations are called a user's `vault`.

A user's vault has three properties, `notional` (nToken balance), `redeemable` (underlying accrued to redeem), and `exchangeRate` (compound exchangeRate of last vault interaction).

When a user takes on a floating position and purchases nTokens (vault initiate), they increase the notional balance of their vault (`vault.notional`). Opposingly, if they sell nTokens, this balance decreases.

Every time a user either increases/decreases their nToken balance (`vault.notional`), the marginal interest since the user's last vault interaction is calculated + added to `vault.redeemable`, and a new `vault.exchangeRate` is set.

## **Creator:**
Creator.sol is a contract to eat the bytecode load of new ZcToken and VaultTracker market deployment. 

Creator has one method for the creation of new markets, which can only be called by `Marketplace.sol`.


# Areas of Concern:
There are a few primary targets for concern:
1. Ensuring the new `Compounding.sol` library properly calculates the exchangeRate for each external protocol.
2. Ensuring the new `withdraw` and `deposit` methods on `Swivel.sol` properly encapsulate external protocol interactions.
3. Ensuring maturity is handled properly across the Marketplace, VaultTracker, and ZcToken.

# Areas To Ignore:
While already noted, there are a couple areas to ignore:
1. Non-Impactful or automatically reverting input sanitization. 
2. Non-Impactful and/or already delayed admin functionality.
3. Non-Compliance with 100% of EIP-5095 (it is still a draft)

