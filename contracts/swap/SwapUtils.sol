// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.0;

import "../data/DataStore.sol";
import "../events/EventEmitter.sol";
import "../oracle/Oracle.sol";
import "../pricing/SwapPricingUtils.sol";
import "../eth/EthUtils.sol";

library SwapUtils {
    using SafeCast for uint256;
    using Price for Price.Props;

    struct SwapParams {
        DataStore dataStore;
        EventEmitter eventEmitter;
        Oracle oracle;
        FeeReceiver feeReceiver;
        address tokenIn;
        uint256 amountIn;
        Market.Props[] markets;
        uint256 minOutputAmount;
        address receiver;
        bool shouldConvertETH;
    }

    struct _SwapParams {
        Market.Props market;
        address tokenIn;
        uint256 amountIn;
        address receiver;
        bool shouldConvertETH;
    }

    struct _SwapCache {
        address tokenOut;
        Price.Props tokenInPrice;
        Price.Props tokenOutPrice;
        uint256 amountIn;
        uint256 amountOut;
        uint256 poolAmountOut;
    }

    error InsufficientSwapOutputAmount(uint256 outputAmount, uint256 minOutputAmount);

    // returns tokenOut, outputAmount
    function swap(SwapParams memory params) internal returns (address, uint256) {
        address tokenOut = params.tokenIn;
        uint256 outputAmount = params.amountIn;

        for (uint256 i = 0; i < params.markets.length; i++) {
            Market.Props memory market = params.markets[i];
            uint256 nextIndex = i + 1;
            address receiver;
            if (nextIndex < params.markets.length) {
                receiver = params.markets[nextIndex].marketToken;
            } else {
                receiver = params.receiver;
            }

            _SwapParams memory _params = _SwapParams(
                market,
                tokenOut,
                outputAmount,
                receiver,
                i == params.markets.length - 1 ? params.shouldConvertETH : false // only convert ETH on the last swap if needed
            );
            (tokenOut, outputAmount) = _swap(params, _params);
        }

        if (outputAmount < params.minOutputAmount) {
            revert InsufficientSwapOutputAmount(outputAmount, params.minOutputAmount);
        }

        return (tokenOut, outputAmount);
    }

    function _swap(SwapParams memory params, _SwapParams memory _params) internal returns (address, uint256) {
        _SwapCache memory cache;

        cache.tokenOut = MarketUtils.getOutputToken(_params.tokenIn, _params.market);
        cache.tokenInPrice = params.oracle.getLatestPrice(_params.tokenIn);
        cache.tokenOutPrice = params.oracle.getLatestPrice(cache.tokenOut);

        SwapPricingUtils.SwapFees memory fees = SwapPricingUtils.getSwapFees(
            params.dataStore,
            _params.market.marketToken,
            _params.amountIn,
            Keys.FEE_RECEIVER_SWAP_FACTOR
        );

        PricingUtils.transferFees(
            params.feeReceiver,
            _params.market.marketToken,
            _params.tokenIn,
            fees.feeReceiverAmount,
            FeeUtils.SWAP_FEE
        );

        int256 priceImpactUsd = SwapPricingUtils.getPriceImpactUsd(
            SwapPricingUtils.GetPriceImpactUsdParams(
                params.dataStore,
                _params.market.marketToken,
                _params.tokenIn,
                cache.tokenOut,
                cache.tokenInPrice.midPrice(),
                cache.tokenOutPrice.midPrice(),
                (fees.amountAfterFees * cache.tokenInPrice.midPrice()).toInt256(),
                -(fees.amountAfterFees * cache.tokenInPrice.midPrice()).toInt256()
            )
        );

        if (priceImpactUsd > 0) {
            cache.amountIn = fees.amountAfterFees;
            cache.amountOut = cache.amountIn * cache.tokenInPrice.min / cache.tokenOutPrice.max;
            cache.poolAmountOut = cache.amountOut;

            // when there is a positive price impact factor, additional tokens from the swap impact pool
            // are withdrawn for the user
            // for example, if 50,000 USDC is swapped out and there is a positive price impact
            // an additional 100 USDC may be sent to the user
            // the swap impact pool is decreased by the used amount
            uint256 positiveImpactAmount = MarketUtils.applyPositiveSwapImpact(
                params.dataStore,
                params.eventEmitter,
                _params.market.marketToken,
                cache.tokenOut,
                cache.tokenOutPrice,
                priceImpactUsd
            );

            cache.amountOut += positiveImpactAmount;
        } else {
            // when there is a negative price impact factor,
            // less of the input amount is sent to the pool
            // for example, if 10 ETH is swapped in and there is a negative price impact
            // only 9.995 ETH may be swapped in
            // the remaining 0.005 ETH will be stored in the swap impact pool
            uint256 negativeImpactAmount = MarketUtils.applyNegativeSwapImpact(
                params.dataStore,
                params.eventEmitter,
                _params.market.marketToken,
                _params.tokenIn,
                cache.tokenInPrice,
                priceImpactUsd
            );

            cache.amountIn = fees.amountAfterFees - negativeImpactAmount;
            cache.amountOut = cache.amountIn * cache.tokenInPrice.min / cache.tokenOutPrice.max;
            cache.poolAmountOut = cache.amountOut;
        }

        if (_params.receiver != address(0)) {
            MarketToken(payable(_params.market.marketToken)).transferOut(
                EthUtils.weth(params.dataStore),
                cache.tokenOut,
                cache.poolAmountOut,
                _params.receiver,
                _params.shouldConvertETH
            );
        }

        MarketUtils.increasePoolAmount(
            params.dataStore,
            params.eventEmitter,
            _params.market.marketToken,
            _params.tokenIn,
            cache.amountIn + fees.feesForPool
        );
        MarketUtils.decreasePoolAmount(
            params.dataStore,
            params.eventEmitter,
            _params.market.marketToken,
            cache.tokenOut,
            cache.poolAmountOut
        );
        MarketUtils.validateReserve(
            params.dataStore,
            _params.market,
            MarketUtils.MarketPrices(
                params.oracle.getLatestPrice(_params.market.indexToken),
                _params.tokenIn == _params.market.longToken ? cache.tokenInPrice : cache.tokenOutPrice,
                _params.tokenIn == _params.market.shortToken ? cache.tokenInPrice : cache.tokenOutPrice
            ),
            cache.tokenOut == _params.market.longToken
        );

        params.eventEmitter.emitSwapFeesCollected(keccak256(abi.encode("swap")), fees);

        return (cache.tokenOut, cache.amountOut);
    }
}
