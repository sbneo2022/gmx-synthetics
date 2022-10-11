// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.0;

import "./OrderUtils.sol";

library DecreaseOrderUtils {
    using Order for Order.Props;

    function processOrder(OrderUtils.ExecuteOrderParams memory params) external {
        Order.Props memory order = params.order;
        MarketUtils.validateNonEmptyMarket(params.market);

        bytes32 positionKey = PositionUtils.getPositionKey(order.account(), order.market(), order.initialCollateralToken(), order.isLong());
        Position.Props memory position = params.positionStore.get(positionKey);
        PositionUtils.validateNonEmptyPosition(position);

        OrderUtils.validateOracleBlockNumbersForPosition(
            params.oracleBlockNumbers,
            order.orderType(),
            order.updatedAtBlock(),
            position.increasedAtBlock
        );

        (uint256 outputAmount, uint256 adjustedSizeDeltaUsd) = DecreasePositionUtils.decreasePosition(
            DecreasePositionUtils.DecreasePositionParams(
                params.dataStore,
                params.eventEmitter,
                params.positionStore,
                params.oracle,
                params.feeReceiver,
                params.market,
                order,
                position,
                positionKey,
                order.sizeDeltaUsd()
            )
        );

        if (adjustedSizeDeltaUsd == order.sizeDeltaUsd()) {
            params.orderStore.remove(params.key, order.account());
        } else {
            order.setSizeDeltaUsd(adjustedSizeDeltaUsd);
            // clear execution fee as it would be fully used even for partial fills
            order.setExecutionFee(0);
            order.touch();
            params.orderStore.set(params.key, order);
        }

        if (order.swapPath().length == 0) {
            MarketToken(order.market()).transferOut(
                EthUtils.weth(params.dataStore),
                order.initialCollateralToken(),
                outputAmount,
                order.receiver(),
                order.shouldConvertETH()
            );
        } else {
            SwapUtils.swap(SwapUtils.SwapParams(
                params.dataStore,
                params.eventEmitter,
                params.oracle,
                params.feeReceiver,
                order.initialCollateralToken(),
                order.initialCollateralDeltaAmount(),
                params.swapPathMarkets,
                order.minOutputAmount(),
                order.receiver(),
                order.shouldConvertETH()
            ));
        }
    }
}
