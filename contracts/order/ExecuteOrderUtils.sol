// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.0;

import "./AutoCancelUtils.sol";
import "../data/DataStore.sol";
import "../data/Keys.sol";

import "./Order.sol";
import "./OrderVault.sol";
import "./OrderStoreUtils.sol";
import "./OrderEventUtils.sol";
import "./OrderUtils.sol";

import "../nonce/NonceUtils.sol";
import "../oracle/Oracle.sol";
import "../oracle/OracleUtils.sol";
import "../event/EventEmitter.sol";

import "./IncreaseOrderUtils.sol";
import "./DecreaseOrderUtils.sol";
import "./SwapOrderUtils.sol";
import "./BaseOrderUtils.sol";

import "../swap/SwapUtils.sol";

import "../gas/GasUtils.sol";
import "../callback/CallbackUtils.sol";

import "../utils/Array.sol";
import "../utils/AccountUtils.sol";
import "../referral/ReferralUtils.sol";

library ExecuteOrderUtils {
    using Order for Order.Props;
    using Position for Position.Props;
    using Price for Price.Props;
    using Array for uint256[];

    // @dev executes an order
    // @param params BaseOrderUtils.ExecuteOrderParams
    function executeOrder(BaseOrderUtils.ExecuteOrderParams memory params) external {
        // 63/64 gas is forwarded to external calls, reduce the startingGas to account for this
        params.startingGas -= gasleft() / 63;

        // 从orderStore移除(未执行)订单
        OrderStoreUtils.remove(params.contracts.dataStore, params.key, params.order.account());

        // 校验订单不为空
        BaseOrderUtils.validateNonEmptyOrder(params.order);
 
        // 判断当前价格是否满足触发订单执行
        BaseOrderUtils.validateOrderTriggerPrice(
            params.contracts.oracle,
            params.market.indexToken,
            params.order.orderType(),
            params.order.triggerPrice(),
            params.order.isLong()
        );

<<<<<<< HEAD
=======
        // 验证订单有效时间(超时处理)
        BaseOrderUtils.validateOrderValidFromTime(
            params.order.orderType(),
            params.order.validFromTime()
        );

        // 获取当前市场价, 包括多空抵押币,和索引代币的价格
>>>>>>> 327596be (执行订单相关流程代码注释)
        MarketUtils.MarketPrices memory prices = MarketUtils.getMarketPrices(
            params.contracts.oracle,
            params.market
        );

        // 分配 Position Impact Pool（仓位影响池）中的资金
        // 用于补偿交易滑点影响
        MarketUtils.distributePositionImpactPool(
            params.contracts.dataStore,
            params.contracts.eventEmitter,
            params.market.marketToken
        );

        // 更新资金费率（Funding Rate）和借贷费率（Borrowing Rate）
        PositionUtils.updateFundingAndBorrowingState(
            params.contracts.dataStore,
            params.contracts.eventEmitter,
            params.market,
            prices
        );

        // 根据订单类型调用相应的处理函数
        // 增/减仓位 或执行 swap
        EventUtils.EventLogData memory eventData = processOrder(params);

        // validate that internal state changes are correct before calling
        // external callbacks
        // if the native token was transferred to the receiver in a swap
        // it may be possible to invoke external contracts before the validations
        // are called
        if (params.market.marketToken != address(0)) {
            MarketUtils.validateMarketTokenBalance(params.contracts.dataStore, params.market);
        }
        // 确保市场代币余额与交易预期一致
        MarketUtils.validateMarketTokenBalance(params.contracts.dataStore, params.swapPathMarkets);

        // 更新 AutoCancel 订单列表，防止长期未执行的订单积累
        OrderUtils.updateAutoCancelList(params.contracts.dataStore, params.key, params.order, false);

        // 触发订单执行事件
        // 触发 OrderExecuted 事件，通知前端 UI 和 Keepers。
        OrderEventUtils.emitOrderExecuted(
            params.contracts.eventEmitter,
            params.key,
            params.order.account(),
            params.secondaryOrderType
        );

        // 如果订单设置了回调合约，执行外部回调
        CallbackUtils.afterOrderExecution(params.key, params.order, eventData);

        // the order.executionFee for liquidation / adl orders is zero
        // gas costs for liquidations / adl is subsidised by the treasury
        // 计算 Keeper 需要的 Gas 费用，并支付执行费。
        GasUtils.payExecutionFee(
            params.contracts.dataStore,
            params.contracts.eventEmitter,
            params.contracts.orderVault,
            params.key,
            params.order.callbackContract(),
            params.order.executionFee(),
            params.startingGas,
            GasUtils.estimateOrderOraclePriceCount(params.order.swapPath().length),
            params.keeper,
            params.order.receiver()
        );

        // clearAutoCancelOrders should be called after the main execution fee
        // is called
        // this is because clearAutoCancelOrders loops through each order for
        // the associated position and calls cancelOrder, which pays the keeper
        // based on the gas usage for each cancel order
        // 减/平仓订单, 判断仓位是否完全关闭. 
        // 如果仓位已清零，并自动清理 AutoCancel 订单
        if (BaseOrderUtils.isDecreaseOrder(params.order.orderType())) {
            bytes32 positionKey = BaseOrderUtils.getPositionKey(params.order);
            uint256 sizeInUsd = params.contracts.dataStore.getUint(
                keccak256(abi.encode(positionKey, PositionStoreUtils.SIZE_IN_USD))
            );
            if (sizeInUsd == 0) {
                OrderUtils.clearAutoCancelOrders(
                    params.contracts.dataStore,
                    params.contracts.eventEmitter,
                    params.contracts.orderVault,
                    positionKey,
                    params.keeper
                );
            }
        }
    }

    // @dev process an order execution
    // @param params BaseOrderUtils.ExecuteOrderParams
    function processOrder(BaseOrderUtils.ExecuteOrderParams memory params) internal returns (EventUtils.EventLogData memory) {
        // 加仓订单处理
        if (BaseOrderUtils.isIncreaseOrder(params.order.orderType())) {
            return IncreaseOrderUtils.processOrder(params);
        }

        // 减仓订单处理
        if (BaseOrderUtils.isDecreaseOrder(params.order.orderType())) {
            return DecreaseOrderUtils.processOrder(params);
        }

        // swap处理
        if (BaseOrderUtils.isSwapOrder(params.order.orderType())) {
            return SwapOrderUtils.processOrder(params);
        }

        revert Errors.UnsupportedOrderType(uint256(params.order.orderType()));
    }
}
