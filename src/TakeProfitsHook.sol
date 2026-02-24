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
// import {CurrencySettler} from "v4-core/test/utils/CurrencySettler.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
 
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
 
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {toBalanceDelta} from "v4-core/types/BalanceDelta.sol";
 
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

    // using CurrencyLibrary for Currency;
 
    // Errors
    error InvalidOrder();
    error NothingToClaim();
    error NotEnoughToClaim();

    // transient storage slot for balance delta accounting
    bytes32 constant BALANCE_DELTA_SLOT = 0; //keccak256('BALANCE_DELTA_SLOT');

    // we need is to create a mapping to store pending orders. We'll do a nested mapping for this, which can identify their position
    mapping(PoolId poolId =>
        mapping(int24 tickToSellAt =>
            mapping(bool zeroForOne => uint256 inputAmount)))
                public pendingOrders;

    // We also need to keep track of the total supply of these claim tokens we have given out.
    mapping(uint256 orderId => uint256 claimsSupply)
        public claimTokensSupply;

    // Store the claimable output tokens for an orderId
    mapping(uint256 orderId => uint256 outputClaimable)
        public claimableOutputTokens;

    // a mapping to store last known tick values for different pools.
    // maintain the mapping of previous tick value
    mapping(PoolId poolId => int24 lastTick) public lastTicks;
 
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
 
    // when a pool is initialized, it's current tick is set for the first time
    function _afterInitialize(
        address,
        PoolKey calldata key,
        uint160,
        int24 tick
    ) internal override returns (bytes4) {
		lastTicks[key.toId()] = tick;
        return this.afterInitialize.selector;
    }

    function tryExecutingOrders(
        PoolKey calldata key,
        bool executeZeroForOne
    ) internal returns (bool tryMore, int24 newTick) {
        // store the tick
        // get the current tick and last tick of the pool
        (, int24 currentTick, , ) = poolManager.getSlot0(key.toId());
        int24 lastTick = lastTicks[key.toId()];
    
        // Given `currentTick` and `lastTick`, 2 cases are possible:
    
        // Case (1) - Tick has increased, i.e. `currentTick > lastTick`
        // or, Case (2) - Tick has decreased, i.e. `currentTick < lastTick`
    
        // If tick increases => Token 0 price has increased
        // => We should check if we have orders looking to sell Token 0
        // i.e. orders with zeroForOne = true
             
        // ------------
        // Case (1)
        // ------------
    
        // Tick has increased i.e. people bought Token 0 by selling Token 1
        // i.e. Token 0 price has increased
        // e.g. in an ETH/USDC pool, people are buying ETH for USDC causing ETH price to increase
        // We should check if we have any orders looking to sell Token 0
        // at ticks `lastTick` to `currentTick`
        // i.e. check if we have any orders to sell ETH at the new price that ETH is at now because of the increase
        if (currentTick > lastTick) {
            // Loop over all ticks from `lastTick` to `currentTick`
            // and execute orders that are looking to sell Token 0
            for (
                int24 tick = lastTick;
                tick < currentTick;
                tick += key.tickSpacing
            ) {
                uint256 inputAmount = pendingOrders[key.toId()][tick][executeZeroForOne];
                if (inputAmount > 0) {
                    // An order with these parameters can be placed by one or more users
                    // We execute the full order as a single swap
                    // Regardless of how many unique users placed the same order
                    executeOrder(key, tick, executeZeroForOne, inputAmount);
        
                    // Return `tryMore` to true because we may have more orders to execute
                    // from lastTick to new current tick
                    // But we need to iterate again from scratch since our sale of ETH shifted the tick down
                    return (true, currentTick);
                }
            }
        }
    
        // If tick decreases => Token 1 price has increased
        // => We should check if we have orders looking to sell Token 1
        // i.e. orders with zeroForOne = false
    
        // ------------
        // Case (2)
        // ------------

        // Tick has gone down i.e. people bought Token 1 by selling Token 0
        // i.e. Token 1 price has increased
        // e.g. in an ETH/USDC pool, people are selling ETH for USDC causing ETH price to decrease (and USDC to increase)
        // We should check if we have any orders looking to sell Token 1
        // at ticks `currentTick` to `lastTick`
        // i.e. check if we have any orders to buy ETH at the new price that ETH is at now because of the decrease
        else {
            for (
                int24 tick = lastTick;
                tick > currentTick;
                tick -= key.tickSpacing
            ) {
                uint256 inputAmount = pendingOrders[key.toId()][tick][executeZeroForOne];
                if (inputAmount > 0) {
                    executeOrder(key, tick, executeZeroForOne, inputAmount);
                    return (true, currentTick);
                }
            }
        }
    
        // ------
    
        // If no orders were found to be executed, we don't need to try
        // executing any more - return `false` and `currentTick`
        return (false, currentTick);
    }

    // 1. Do not let afterSwap be triggered if it is being executed because of a swap our hook created while fulfilling an order (to prevent deep recursion and re-entrancy issues)
    // 2. Identify tick shift range, find first order that can be fulfilled in that range, fill it - but then update tick shift range and search again if there are any new orders that can be fulfilled in this range or not - ignoring any orders that may have existed within the original tick shift range
    /**
    1. don't want to let aftreswap be triggered if it is being executed because of a swap that our hook created whilst fulfilling an order.
    2. identify tick shift range, find first order that can be fulfilled and fill it. Then update the range and try within the boundraries.
     */
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
		// `sender` is the address which initiated the swap
        // if `sender` is the hook, we don't want to go down the `afterSwap`
        // rabbit hole again
        // if the `sender` is this address, then we are triggered from an order execution
        if (sender == address(this)) return (this.afterSwap.selector, 0);

        // flush our transient storage for balance delta
        _tstore(BalanceDelta.wrap(0));
    
        // Should we try to find and execute orders? True initially
        // should we try and execute order?
        bool tryMore = true;
        int24 currentTick;
    
        while (tryMore) {
            // Try executing pending orders for this pool
    
            // `tryMore` is true if we successfully found and executed an order
            // which shifted the tick value
            // and therefore we need to look again if there are any pending orders
            // within the new tick range
    
            // `tickAfterExecutingOrder` is the tick value of the pool
            // after executing an order
            // if no order was executed, `tickAfterExecutingOrder` will be
            // the same as current tick, and `tryMore` will be false
            (tryMore, currentTick) = tryExecutingOrders(
                key,
                !params.zeroForOne
            );
        }

        // account for swap
        swapAndSettleBalances(key, params);
    
        // New last known tick for this pool is the tick value
        // after our orders are executed
        lastTicks[key.toId()] = currentTick;
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
        return uint256(
            keccak256(
                abi.encode(key.toId(), tick, zeroForOne)
            )
        );
    }

    function placeOrder(
        PoolKey calldata key, // point 1
        int24 tickToSellAt,
        bool zeroForOne,
        uint256 inputAmount
    ) external returns (int24) {
        // Get lower actually usable tick given `tickToSellAt`
        int24 tick = getLowerUsableTick(tickToSellAt, key.tickSpacing); // point 2
        // Create a pending order
        pendingOrders[key.toId()][tick][zeroForOne] += inputAmount; // point 3
    
        // Mint claim tokens to user equal to their `inputAmount`
        // point 4
        uint256 orderId = getOrderId(key, tick, zeroForOne); 
        claimTokensSupply[orderId] += inputAmount;
        _mint(msg.sender, orderId, inputAmount, "");
    
        // Depending on direction of swap, we select the proper input token
        // and request a transfer of those tokens to the hook contract
        // point 5
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
        // address token = Currency.unwrap(zeroForOne ? key.currency0 : key.currency1);
        // IERC20(token).transfer(msg.sender, amountToCancel);
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
        // point 1
        int24 tick = getLowerUsableTick(tickToSellAt, key.tickSpacing);
        uint256 orderId = getOrderId(key, tick, zeroForOne);
    
        // If no output tokens can be claimed yet i.e. order hasn't been filled
        // throw error
        if (claimableOutputTokens[orderId] == 0) revert NothingToClaim();
    
        // they must have claim tokens >= inputAmountToClaimFor
        // point 2
        uint256 claimTokens = balanceOf(msg.sender, orderId);
        if (claimTokens < inputAmountToClaimFor) revert NotEnoughToClaim();

        // point 3
        // given that:
        // claimTokens: amount of claimable input tokens they have for this position (i.e. their share of the order)
        // totalClaimableForPosition: amount of output tokens we have from executing this position (not just from this user)
        // totalInputAmountForPosition: total supply of input tokens for the order

        // claimTokens: 100
        // totalClaimableForPosition: 100
        // totalInputAmountForPosition: 500

        // user % of share of input amount:
        // claimTokens / totalInputAmountForPosition = 100/500 = 20%
        
        // user share of output tokens:
        // totalClaimableForPosition * (claimTokens / totalInputAmountForPosition)
        // (claimTokens * totalClaimableForPosition) / totalInputAmountForPosition
        // 100 * 100 / 500 = 20 output tokens to claim
        uint256 totalClaimableForPosition = claimableOutputTokens[orderId];
        uint256 totalInputAmountForPosition = claimTokensSupply[orderId];
    
        // outputAmount = (inputAmountToClaimFor * totalClaimableForPosition) / (totalInputAmountForPosition)
        uint256 outputAmount = inputAmountToClaimFor.mulDivDown(
            totalClaimableForPosition,
            totalInputAmountForPosition
        );
    
        // Reduce claimable output tokens amount
        // Reduce claim token total supply for position
        // point 4
        claimableOutputTokens[orderId] -= outputAmount;
        claimTokensSupply[orderId] -= inputAmountToClaimFor;

        // Burn claim tokens
        _burn(msg.sender, orderId, inputAmountToClaimFor); // point 5
    
        // Transfer output tokens
        // point 6
        Currency token = zeroForOne ? key.currency1 : key.currency0;
        token.transfer(msg.sender, outputAmount);
        // address token = Currency.unwrap(zeroForOne ? key.currency0 : key.currency1);
        // IERC20(token).transfer(msg.sender, amountToCancel);
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
        // BalanceDelta delta = poolManager.swap(key, params, ""); // point 1
        BalanceDelta delta = _tload();
    
        // point 2
        // If we just did a zeroForOne swap
        // We need to send Token 0 to PM, and receive Token 1 from PM
        if (params.zeroForOne) {
            // Negative Value => Money leaving user's wallet
            // Settle with PoolManager
            if (delta.amount0() < 0) {
                _settle(key.currency0, uint128(-delta.amount0()));
                // key.currency0.settle(manager, address(this), uint128(-delta.amount0()), false);
            }
    
            // Positive Value => Money coming into user's wallet
            // Take from PM
            if (delta.amount1() > 0) {
                _take(key.currency1, uint128(delta.amount1()));
                // key.currency1.take(manager, address(this), uint128(delta.amount1()), false);
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
            })//, 
            // ''
        );

        // get the balancedelta from transient storage
        BalanceDelta existingDelta = _tload();

        // add the new balance delta to the existing one
        existingDelta = existingDelta + delta;

        // update transient storage
        _tstore(existingDelta);
    
        // `inputAmount` has been deducted from this position
        pendingOrders[key.toId()][tick][zeroForOne] -= inputAmount; // point 3
        // `outputAmount` has been added`
        // point 4
        uint256 orderId = getOrderId(key, tick, zeroForOne);
        uint256 outputAmount = zeroForOne
            ? uint256(int256(delta.amount1()))
            : uint256(int256(delta.amount0()));
        // uint outputAmount = uint(int(zeroForOne ? delta.amount1() : delta.amount0()));
    
        // `outputAmount` worth of tokens now can be claimed/redeemed by position holders
        claimableOutputTokens[orderId] += outputAmount;
    }

    function _tstore(BalanceDelta delta) internal {
        int256 deltaStore = BalanceDelta.unwrap(delta);
        assembly {
            sstore(BALANCE_DELTA_SLOT, deltaStore)
        }
    }

    function _tload() internal returns (BalanceDelta delta_) {
        int256 rawDelta;
        assembly {
            rawDelta := sload(BALANCE_DELTA_SLOT)
        }
        return BalanceDelta.wrap(rawDelta);
    }
}