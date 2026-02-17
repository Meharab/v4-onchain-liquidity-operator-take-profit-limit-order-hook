// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;
 
// Foundry libraries
import {Test} from "forge-std/Test.sol";
 
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
 
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
 
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
 
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
 
import {TakeProfitsHook} from "../src/TakeProfitsHook.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
 
contract TakeProfitsHookTest is Test, Deployers, ERC1155Holder {
    // Use the libraries
    using StateLibrary for IPoolManager;
 
    // The two currencies (tokens) from the pool
    Currency token0;
    Currency token1;
 
    TakeProfitsHook hook;
 
    // Note that we don't really care about computing how many tokens we're adding each time we add liquidity. Not that it's unimportant, more so it's not very relevant for the tests.
	function setUp() public {
        // Deploy v4 core contracts
        deployFreshManagerAndRouters();
    
        // Deploy two test tokens
        (token0, token1) = deployMintAndApprove2Currencies();
    
        // Deploy our hook
        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG
        );
        address hookAddress = address(flags);
        deployCodeTo(
            "TakeProfitsHook.sol",
            abi.encode(manager, ""),
            hookAddress
        );
        hook = TakeProfitsHook(hookAddress);
    
        // Approve our hook address to spend these tokens as well
        MockERC20(Currency.unwrap(token0)).approve(
            address(hook),
            type(uint256).max
        );
        MockERC20(Currency.unwrap(token1)).approve(
            address(hook),
            type(uint256).max
        );
    
        // Initialize a pool with these two tokens
        (key, ) = initPool(token0, token1, hook, 3000, SQRT_PRICE_1_1);
    
        // Add initial liquidity to the pool
    
        // Some liquidity from -60 to +60 tick range
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 10 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        // Some liquidity from -120 to +120 tick range
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: -120,
                tickUpper: 120,
                liquidityDelta: 10 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        // some liquidity for full range
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: 10 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    function test_placeOrder() public {
        // Place a zeroForOne take-profit order
        // for 10e18 token0 tokens
        // at tick 100
        int24 tick = 100;
        uint256 amount = 10e18;
        bool zeroForOne = true;
    
        // Note the original balance of token0 we have
        uint256 originalBalance = token0.balanceOfSelf();
    
        // Place the order
        int24 tickLower = hook.placeOrder(key, tick, zeroForOne, amount);
    
        // Note the new balance of token0 we have
        uint256 newBalance = token0.balanceOfSelf();
    
        // Since we deployed the pool contract with tick spacing = 60
        // i.e. the tick can only be a multiple of 60
        // the tickLower should be 60 since we placed an order at tick 100
        assertEq(tickLower, 60);
    
        // Ensure that our balance of token0 was reduced by `amount` tokens
        assertEq(originalBalance - newBalance, amount);
    
        // Check the balance of ERC-1155 tokens we received
        uint256 orderId = hook.getOrderId(key, tickLower, zeroForOne);
        uint256 tokenBalance = hook.balanceOf(address(this), orderId);
    
        // Ensure that we were, in fact, given ERC-1155 tokens for the order
        // equal to the `amount` of token0 tokens we placed the order for
        assertTrue(orderId != 0);
        assertEq(tokenBalance, amount);
    }

    function test_cancelOrder() public {
        // Place an order as earlier
        int24 tick = 100;
        uint256 amount = 10e18;
        bool zeroForOne = true;
    
        uint256 originalBalance = token0.balanceOfSelf();
        int24 tickLower = hook.placeOrder(key, tick, zeroForOne, amount);
        uint256 newBalance = token0.balanceOfSelf();
    
        assertEq(tickLower, 60);
        assertEq(originalBalance - newBalance, amount);
    
        // Check the balance of ERC-1155 tokens we received
        uint256 orderId = hook.getOrderId(key, tickLower, zeroForOne);
        uint256 tokenBalance = hook.balanceOf(address(this), orderId);
        assertEq(tokenBalance, amount);
    
        // Cancel the order
        hook.cancelOrder(key, tickLower, zeroForOne, amount);
    
        // Check that we received our token0 tokens back, and no longer own any ERC-1155 tokens
        uint256 finalBalance = token0.balanceOfSelf();
        assertEq(finalBalance, originalBalance);
    
        tokenBalance = hook.balanceOf(address(this), orderId);
        assertEq(tokenBalance, 0);
    }
}