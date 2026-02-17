// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;
 
import {BaseHook} from "v4-hooks-public/src/base/BaseHook.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
 
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
 
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
 
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
 
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
 
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";

/**
 * @dev To keep things relatively simple, we'll make some assumptions and skip over certain cases (which should be resolved in a     production-ready hook):

    1. We are going to try and fulfill every order that exists within the range the tick moved after a swap, with zero consideration for the fact that this will increase gas costs for the original swapper - Bob. Realistically, there should be some sort of limit here probably - especially if deploying to L1 mainnet - to keep costs reasonable and not punish Bob because he happened to use a pool with this hook attached.

    2. We will not consider slippage for placed orders, and allow infinite slippage. In practice, makers of the order should also be able to set some slippage limit for fulfilling their order.

    3. We will not support pools with native ETH as one of the tokens in the pair. No reason not to apart from it just makes the code a bit longer and we don't really need that just to explain how this logic works. It should be fairly simple to add support for native ETH to the hook afterwards if you'd like. 
 */
 
contract TakeProfitsHook is BaseHook, ERC1155 {
	// StateLibrary is new here and we haven't seen that before
	// It's used to add helper functions to the PoolManager to read
	// storage values.
	// In this case, we use it for accessing `currentTick` values
	// from the pool manager
	using StateLibrary for IPoolManager;
 
	// Used for helpful math operations like `mulDiv`
    using FixedPointMathLib for uint256;
 
    // Errors
    error InvalidOrder();
    error NothingToClaim();
    error NotEnoughToClaim();

    // we need is to create a mapping to store pending orders. We'll do a nested mapping for this, which can identify their position
    mapping(PoolId poolId =>
        mapping(int24 tickToSellAt =>
            mapping(bool zeroForOne => uint256 inputAmount)))
                public pendingOrders;

    // We also need to keep track of the total supply of these claim tokens we have given out.
    mapping(uint256 orderId => uint256 claimsSupply)
        public claimTokensSupply;

    mapping(uint256 orderId => uint256 outputClaimable)
        public claimableOutputTokens;
 
	// Constructor
    constructor(
        IPoolManager _manager,
        string memory _uri
    ) BaseHook(_manager) ERC1155(_uri) {}
 
	// BaseHook Functions
    // We use afterSwap for executing orders since executing the order will further move the tick in some direction. Doing it in beforeSwap would affect the swap Bob wanted to execute - and we don't want that. We want Bob's trade to go through normally, and execute any pending orders after his trade is done.
    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: true,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: false,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }
 
    function _afterInitialize(
        address,
        PoolKey calldata key,
        uint160,
        int24 tick
    ) internal override returns (bytes4) {
		// TODO
        return this.afterInitialize.selector;
    }

    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
		// TODO
        return (this.afterSwap.selector, 0);
    }
 
    /**
     * 
     * @dev The first functionality we will build is the ability to place orders. Let's think about this conceptually:

        1. Users specify which pool to place the order for, what tick to sell their tokens at, which direction the swap is happening, and how many tokens to sell
        2. Since users may specify any arbitrary tick, we'll pick the closest actual usable tick based on the tick spacing of the pool - rounding down by default.
        3. We save their order in storage - some sort of mapping
        4. We mint them some "claim" tokens they can use to claim output tokens later on that uniquely represent their order parameters
        5. We transfer the input tokens from their wallet to the hook contract
     */

    // getting the closest lower tick that is actually usable, given an arbitrary tick value - first. Basically if tickSpacing is something like 60, we can only actually do swaps at ticks that are a multiple of 60 - e.g. -120, -60, 0, 60, 120, etc.
    // If the user says they want to place their order to sell at tick 100, we round down to closest usable tick which is 60. If they want to sell at tick -100, we round down to closest usable tick that is -120.
    function getLowerUsableTick(
        int24 tick,
        int24 tickSpacing
    ) private pure returns (int24) {
        // E.g. tickSpacing = 60, tick = -100
        // closest usable tick rounded-down will be -120
    
        // intervals = -100/60 = -1 (integer division)
        int24 intervals = tick / tickSpacing;
    
        // since tick < 0, we round `intervals` down to -2
        // if tick > 0, `intervals` is fine as it is
        if (tick < 0 && tick % tickSpacing != 0) intervals--; // round towards negative infinity
    
        // actual usable tick, then, is intervals * tickSpacing
        // i.e. -2 * 60 = -120
        return intervals * tickSpacing;
    }

    // we need to be able to represent this position as a uint256 to use it as the Token ID for ERC-1155 claim tokens we issue to the order maker
    function getOrderId(
        PoolKey calldata key,
        int24 tick,
        bool zeroForOne
    ) public pure returns (uint256) {
        return uint256(keccak256(abi.encode(key.toId(), tick, zeroForOne)));
    }

    function placeOrder(
        PoolKey calldata key,
        int24 tickToSellAt,
        bool zeroForOne,
        uint256 inputAmount
    ) external returns (int24) {
        // Get lower actually usable tick given `tickToSellAt`
        int24 tick = getLowerUsableTick(tickToSellAt, key.tickSpacing);
        // Create a pending order
        pendingOrders[key.toId()][tick][zeroForOne] += inputAmount;
    
        // Mint claim tokens to user equal to their `inputAmount`
        uint256 orderId = getOrderId(key, tick, zeroForOne);
        claimTokensSupply[orderId] += inputAmount;
        _mint(msg.sender, orderId, inputAmount, "");
    
        // Depending on direction of swap, we select the proper input token
        // and request a transfer of those tokens to the hook contract
        address sellToken = zeroForOne
            ? Currency.unwrap(key.currency0)
            : Currency.unwrap(key.currency1);
        IERC20(sellToken).transferFrom(msg.sender, address(this), inputAmount);
    
        // Return the tick at which the order was actually placed
        return tick;
    }

    // We delete the pending order from the mapping, burn the claim tokens, reduce the claim token total supply, and send their input tokens back to them.
    function cancelOrder(
        PoolKey calldata key,
        int24 tickToSellAt,
        bool zeroForOne,
        uint256 amountToCancel
    ) external {
        // Get lower actually usable tick for their order
        int24 tick = getLowerUsableTick(tickToSellAt, key.tickSpacing);
        uint256 orderId = getOrderId(key, tick, zeroForOne);
    
        // Check how many claim tokens they have for this position
        uint256 positionTokens = balanceOf(msg.sender, orderId);
        if (positionTokens < amountToCancel) revert NotEnoughToClaim();
    
        // Remove their `amountToCancel` worth of position from pending orders
        pendingOrders[key.toId()][tick][zeroForOne] -= amountToCancel;
        // Reduce claim token total supply and burn their share
        claimTokensSupply[orderId] -= amountToCancel;
        _burn(msg.sender, orderId, amountToCancel);
    
        // Send them their input token
        Currency token = zeroForOne ? key.currency0 : key.currency1;
        token.transfer(msg.sender, amountToCancel);
    }

    /**
     * @dev Assuming we can somehow fulfill the orders that were placed, what does it look like to redeem output tokens back out?

        1. We need to store the amount of output tokens that are redeemable a specific position
        2. The user has claim tokens equivalent to their input amount
        3. We calculate their share of output tokens
        4. Reduce that amount from the redeemable output tokens storage value
        5. Burn their claim tokens
        6. Transfer their output tokens to them
     */

    function redeem(
        PoolKey calldata key,
        int24 tickToSellAt,
        bool zeroForOne,
        uint256 inputAmountToClaimFor
    ) external {
        // Get lower actually usable tick for their order
        int24 tick = getLowerUsableTick(tickToSellAt, key.tickSpacing);
        uint256 orderId = getOrderId(key, tick, zeroForOne);
    
        // If no output tokens can be claimed yet i.e. order hasn't been filled
        // throw error
        if (claimableOutputTokens[orderId] == 0) revert NothingToClaim();
    
        // they must have claim tokens >= inputAmountToClaimFor
        uint256 claimTokens = balanceOf(msg.sender, orderId);
        if (claimTokens < inputAmountToClaimFor) revert NotEnoughToClaim();
    
        uint256 totalClaimableForPosition = claimableOutputTokens[orderId];
        uint256 totalInputAmountForPosition = claimTokensSupply[orderId];
    
        // outputAmount = (inputAmountToClaimFor * totalClaimableForPosition) / (totalInputAmountForPosition)
        uint256 outputAmount = inputAmountToClaimFor.mulDivDown(
            totalClaimableForPosition,
            totalInputAmountForPosition
        );
    
        // Reduce claimable output tokens amount
        // Reduce claim token total supply for position
        // Burn claim tokens
        claimableOutputTokens[orderId] -= outputAmount;
        claimTokensSupply[orderId] -= inputAmountToClaimFor;
        _burn(msg.sender, orderId, inputAmountToClaimFor);
    
        // Transfer output tokens
        Currency token = zeroForOne ? key.currency1 : key.currency0;
        token.transfer(msg.sender, outputAmount);
    }

    /**
     * @dev So, let's think about what's needed to execute an order. Assuming the order information is provided to us by a higher-level function (afterSwap):

        1. Call poolManager.swap to conduct the actual swap. This will return a BalanceDelta
        2. Settle all balances with the pool manager
        3. Remove the swapped amount of input tokens from the pendingOrders mapping
        4. Increase the amount of output tokens now claimable for this position in the claimableOutputTokens mapping
     */

    // This function will simply take in the pool key and the SwapParams and just call the Pool Manager and then settle balances.
    function swapAndSettleBalances(
        PoolKey calldata key,
        SwapParams memory params
    ) internal returns (BalanceDelta) {
        // Conduct the swap inside the Pool Manager
        BalanceDelta delta = poolManager.swap(key, params, "");
    
        // If we just did a zeroForOne swap
        // We need to send Token 0 to PM, and receive Token 1 from PM
        if (params.zeroForOne) {
            // Negative Value => Money leaving user's wallet
            // Settle with PoolManager
            if (delta.amount0() < 0) {
                _settle(key.currency0, uint128(-delta.amount0()));
            }
    
            // Positive Value => Money coming into user's wallet
            // Take from PM
            if (delta.amount1() > 0) {
                _take(key.currency1, uint128(delta.amount1()));
            }
        } else {
            if (delta.amount1() < 0) {
                _settle(key.currency1, uint128(-delta.amount1()));
            }
    
            if (delta.amount0() > 0) {
                _take(key.currency0, uint128(delta.amount0()));
            }
        }
    
        return delta;
    }
    
    function _settle(Currency currency, uint128 amount) internal {
        // Transfer tokens to PM and let it know
        poolManager.sync(currency);
        currency.transfer(address(poolManager), amount);
        poolManager.settle();
    }
    
    function _take(Currency currency, uint128 amount) internal {
        // Take tokens out of PM to our hook contract
        poolManager.take(currency, address(this), amount);
    }

    // executeOrder function - which given details about a specific pending order will do the swap, settle balances, and update all mappings as required
    function executeOrder(
        PoolKey calldata key,
        int24 tick,
        bool zeroForOne,
        uint256 inputAmount
    ) internal {
        // Do the actual swap and settle all balances
        BalanceDelta delta = swapAndSettleBalances(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                // We provide a negative value here to signify an "exact input for output" swap
                amountSpecified: -int256(inputAmount),
                // No slippage limits (maximum slippage possible)
                sqrtPriceLimitX96: zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            })
        );
    
        // `inputAmount` has been deducted from this position
        pendingOrders[key.toId()][tick][zeroForOne] -= inputAmount;
        uint256 orderId = getOrderId(key, tick, zeroForOne);
        uint256 outputAmount = zeroForOne
            ? uint256(int256(delta.amount1()))
            : uint256(int256(delta.amount0()));
    
        // `outputAmount` worth of tokens now can be claimed/redeemed by position holders
        claimableOutputTokens[orderId] += outputAmount;
    }
}