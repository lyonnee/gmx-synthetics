// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.0;

import "./AutoCancelUtils.sol";
import "../data/DataStore.sol";
import "../data/Keys.sol";

import "./Order.sol";
import "./OrderVault.sol";
import "./OrderStoreUtils.sol";
import "./OrderEventUtils.sol";

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

// @title OrderUtils
// @dev Library for order functions
library OrderUtils {
    using Order for Order.Props;
    using Position for Position.Props;
    using Price for Price.Props;
    using Array for uint256[];

    struct CancelOrderParams {
        DataStore dataStore;
        EventEmitter eventEmitter;
        OrderVault orderVault;
        bytes32 key;
        address keeper;
        uint256 startingGas;
        bool isExternalCall;
        string reason;
        bytes reasonBytes;
    }

    // @dev creates an order in the order store
    // @param dataStore DataStore
    // @param eventEmitter EventEmitter
    // @param orderVault OrderVault
    // @param account the order account
    // @param params IBaseOrderUtils.CreateOrderParams
    function createOrder(
        DataStore dataStore,
        EventEmitter eventEmitter,
        OrderVault orderVault,
        IReferralStorage referralStorage,
        address account,
        IBaseOrderUtils.CreateOrderParams memory params
    ) external returns (bytes32) {
        // 1. 账户验证
        AccountUtils.validateAccount(account);
        // 2. 设置推荐人
        ReferralUtils.setTraderReferralCode(referralStorage, account, params.referralCode);

        // 3. 获取和处理不同订单类型的保证金, 并校验执行费
        uint256 initialCollateralDeltaAmount;
        // wnt 代表 WNT（Wrapped Native Token，如 WETH），GMX 交易系统使用 WNT 处理原生代币。
        address wnt = TokenUtils.wnt(dataStore);
        // 用于标记是否需要单独转移 executionFee（执行费用）
        bool shouldRecordSeparateExecutionFeeTransfer = true;

        // 处理不同订单类型的保证金
        if (
            params.orderType == Order.OrderType.MarketSwap ||
            params.orderType == Order.OrderType.LimitSwap ||
            params.orderType == Order.OrderType.MarketIncrease ||
            params.orderType == Order.OrderType.LimitIncrease
        ) {
            // 对于 Swap 和 Increase 订单，保证金来自 orderVault, 资金从 orderVault 中获取，确保用户已经存入抵押金
            // sendWnt() 会将用户保证金(抵押品), 存入到orderVault中
            initialCollateralDeltaAmount = orderVault.recordTransferIn(params.addresses.initialCollateralToken);
            // 如果保证金类型是包装的原生代币类型, 则需要先校验并扣除executionFee
            if (params.addresses.initialCollateralToken == wnt) {
                if (initialCollateralDeltaAmount < params.numbers.executionFee) {
                    revert Errors.InsufficientWntAmountForExecutionFee(initialCollateralDeltaAmount, params.numbers.executionFee);
                }
                // 保证金为扣除执行费后的金额
                initialCollateralDeltaAmount -= params.numbers.executionFee;
                // 不再需要单独处理转移保证金
                shouldRecordSeparateExecutionFeeTransfer = false;
            }
        } else if (
            params.orderType == Order.OrderType.MarketDecrease ||
            params.orderType == Order.OrderType.LimitDecrease ||
            params.orderType == Order.OrderType.StopLossDecrease
        ) {
            // 如果是 减仓/平仓/止盈/止损订单, 保证金直接使用传参的指
            initialCollateralDeltaAmount = params.numbers.initialCollateralDeltaAmount;
        } else {
            revert Errors.OrderTypeCannotBeCreated(uint256(params.orderType));
        }

        // 如果需要单独处理执行费, 即用户的保证金不是原声代币
        if (shouldRecordSeparateExecutionFeeTransfer) {
            // 从orderVault取出用户传入的原生代币
            uint256 wntAmount = orderVault.recordTransferIn(wnt);
            // 校验执行费用
            if (wntAmount < params.numbers.executionFee) {
                revert Errors.InsufficientWntAmountForExecutionFee(wntAmount, params.numbers.executionFee);
            }

            params.numbers.executionFee = wntAmount;
        }

        // 4. 校验交易对是否支持合约交易, 验证 swap 路径是否正确
        // 如果是合约交易
        if (BaseOrderUtils.isPositionOrder(params.orderType)) {
            // 判断该交易对是否支持合约交易
            MarketUtils.validatePositionMarket(dataStore, params.addresses.market);
        }

        // 验证 swap 路径是否正确
        MarketUtils.validateSwapPath(dataStore, params.addresses.swapPath);

        // 5. 构建订单对象
        Order.Props memory order;

        order.setAccount(account);
        order.setReceiver(params.addresses.receiver);
        order.setCancellationReceiver(params.addresses.cancellationReceiver);
        order.setCallbackContract(params.addresses.callbackContract);
        order.setMarket(params.addresses.market);
        order.setInitialCollateralToken(params.addresses.initialCollateralToken);
        order.setUiFeeReceiver(params.addresses.uiFeeReceiver);
        order.setSwapPath(params.addresses.swapPath);
        order.setOrderType(params.orderType);
        order.setDecreasePositionSwapType(params.decreasePositionSwapType);
        order.setSizeDeltaUsd(params.numbers.sizeDeltaUsd);
        order.setInitialCollateralDeltaAmount(initialCollateralDeltaAmount);
        order.setTriggerPrice(params.numbers.triggerPrice);
        order.setAcceptablePrice(params.numbers.acceptablePrice);
        order.setExecutionFee(params.numbers.executionFee);
        order.setCallbackGasLimit(params.numbers.callbackGasLimit);
        order.setMinOutputAmount(params.numbers.minOutputAmount);
        order.setIsLong(params.isLong);
        order.setShouldUnwrapNativeToken(params.shouldUnwrapNativeToken);
        order.setAutoCancel(params.autoCancel);

        // 6. 校验接收者地址
        AccountUtils.validateReceiver(order.receiver());
        if (order.cancellationReceiver() == address(orderVault)) {
            // revert as funds cannot be sent back to the order vault
            revert Errors.InvalidReceiver(order.cancellationReceiver());
        }

        // 7. 校验gas限制和执行费是否足够
        CallbackUtils.validateCallbackGasLimit(dataStore, order.callbackGasLimit());

        uint256 estimatedGasLimit = GasUtils.estimateExecuteOrderGasLimit(dataStore, order);
        uint256 oraclePriceCount = GasUtils.estimateOrderOraclePriceCount(params.addresses.swapPath.length);
        GasUtils.validateExecutionFee(dataStore, estimatedGasLimit, order.executionFee(), oraclePriceCount);

        // 8. 生成订单 Key 并存入OrderStore
        bytes32 key = NonceUtils.getNextKey(dataStore);

        // 记录生成订单的区块高度和时间戳
        order.touch();

        BaseOrderUtils.validateNonEmptyOrder(order);
        // 存入OrderStore
        OrderStoreUtils.set(dataStore, key, order);

        // 9. 注册订单到自动取消列表
        updateAutoCancelList(dataStore, key, order, order.autoCancel());
        // 校验自动取消时的回调函数执行gas限制
        validateTotalCallbackGasLimitForAutoCancelOrders(dataStore, order);

        // 10. 触发创建订单事件
        OrderEventUtils.emitOrderCreated(eventEmitter, key, order);

        return key;
    }

    function cancelOrder(CancelOrderParams memory params) public {
        // 63/64 gas is forwarded to external calls, reduce the startingGas to account for this
        if (params.isExternalCall) {
            params.startingGas -= gasleft() / 63;
        }

        uint256 gas = gasleft();
        uint256 minHandleExecutionErrorGas = GasUtils.getMinHandleExecutionErrorGas(params.dataStore);

        if (gas < minHandleExecutionErrorGas) {
            revert Errors.InsufficientGasForCancellation(gas, minHandleExecutionErrorGas);
        }

        Order.Props memory order = OrderStoreUtils.get(params.dataStore, params.key);
        BaseOrderUtils.validateNonEmptyOrder(order);

        OrderStoreUtils.remove(params.dataStore, params.key, order.account());

        if (BaseOrderUtils.isIncreaseOrder(order.orderType()) || BaseOrderUtils.isSwapOrder(order.orderType())) {
            if (order.initialCollateralDeltaAmount() > 0) {
                address cancellationReceiver = order.cancellationReceiver();
                if (cancellationReceiver == address(0)) {
                    cancellationReceiver = order.account();
                }

                params.orderVault.transferOut(
                    order.initialCollateralToken(),
                    cancellationReceiver,
                    order.initialCollateralDeltaAmount(),
                    order.shouldUnwrapNativeToken()
                );
            }
        }

        updateAutoCancelList(params.dataStore, params.key, order, false);

        OrderEventUtils.emitOrderCancelled(
            params.eventEmitter,
            params.key,
            order.account(),
            params.reason,
            params.reasonBytes
        );

        address executionFeeReceiver = order.cancellationReceiver();

        if (executionFeeReceiver == address(0)) {
            executionFeeReceiver = order.receiver();
        }

        EventUtils.EventLogData memory eventData;
        CallbackUtils.afterOrderCancellation(params.key, order, eventData);

        GasUtils.payExecutionFee(
            params.dataStore,
            params.eventEmitter,
            params.orderVault,
            params.key,
            order.callbackContract(),
            order.executionFee(),
            params.startingGas,
            GasUtils.estimateOrderOraclePriceCount(order.swapPath().length),
            params.keeper,
            executionFeeReceiver
        );
    }

    // @dev freezes an order
    // @param dataStore DataStore
    // @param eventEmitter EventEmitter
    // @param orderVault OrderVault
    // @param key the key of the order to freeze
    // @param keeper the keeper sending the transaction
    // @param startingGas the starting gas of the transaction
    // @param reason the reason the order was frozen
    function freezeOrder(
        DataStore dataStore,
        EventEmitter eventEmitter,
        OrderVault orderVault,
        bytes32 key,
        address keeper,
        uint256 startingGas,
        string memory reason,
        bytes memory reasonBytes
    ) external {
        // 63/64 gas is forwarded to external calls, reduce the startingGas to account for this
        startingGas -= gasleft() / 63;

        Order.Props memory order = OrderStoreUtils.get(dataStore, key);
        BaseOrderUtils.validateNonEmptyOrder(order);

        if (order.isFrozen()) {
            revert Errors.OrderAlreadyFrozen();
        }

        order.setExecutionFee(0);
        order.setIsFrozen(true);
        OrderStoreUtils.set(dataStore, key, order);

        OrderEventUtils.emitOrderFrozen(
            eventEmitter,
            key,
            order.account(),
            reason,
            reasonBytes
        );

        EventUtils.EventLogData memory eventData;
        CallbackUtils.afterOrderFrozen(key, order, eventData);

        GasUtils.payExecutionFee(
            dataStore,
            eventEmitter,
            orderVault,
            key,
            order.callbackContract(),
            order.executionFee(),
            startingGas,
            GasUtils.estimateOrderOraclePriceCount(order.swapPath().length),
            keeper,
            order.receiver()
        );
    }

    function clearAutoCancelOrders(
        DataStore dataStore,
        EventEmitter eventEmitter,
        OrderVault orderVault,
        bytes32 positionKey,
        address keeper
    ) internal {
        bytes32[] memory orderKeys = AutoCancelUtils.getAutoCancelOrderKeys(dataStore, positionKey);

        for (uint256 i; i < orderKeys.length; i++) {
            cancelOrder(
                CancelOrderParams(
                    dataStore,
                    eventEmitter,
                    orderVault,
                    orderKeys[i],
                    keeper, // keeper
                    gasleft(), // startingGas
                    false, // isExternalCall
                    "AUTO_CANCEL", // reason
                    "" // reasonBytes
                )
            );
        }
    }

    function updateAutoCancelList(DataStore dataStore, bytes32 orderKey, Order.Props memory order, bool shouldAdd) internal {
        if (
            order.orderType() != Order.OrderType.LimitDecrease &&
            order.orderType() != Order.OrderType.StopLossDecrease
        ) {
            return;
        }

        bytes32 positionKey = BaseOrderUtils.getPositionKey(order);

        if (shouldAdd) {
            AutoCancelUtils.addAutoCancelOrderKey(dataStore, positionKey, orderKey);
        } else {
            AutoCancelUtils.removeAutoCancelOrderKey(dataStore, positionKey, orderKey);
        }
    }

    function validateTotalCallbackGasLimitForAutoCancelOrders(DataStore dataStore, Order.Props memory order) internal view {
        if (
            order.orderType() != Order.OrderType.LimitDecrease &&
            order.orderType() != Order.OrderType.StopLossDecrease
        ) {
            return;
        }

        bytes32 positionKey = BaseOrderUtils.getPositionKey(order);
        uint256 maxTotal = dataStore.getUint(Keys.MAX_TOTAL_CALLBACK_GAS_LIMIT_FOR_AUTO_CANCEL_ORDERS);
        uint256 total = getTotalCallbackGasLimitForAutoCancelOrders(dataStore, positionKey);

        if (total > maxTotal) {
            revert Errors.MaxTotalCallbackGasLimitForAutoCancelOrdersExceeded(total, maxTotal);
        }
    }

    function getTotalCallbackGasLimitForAutoCancelOrders(DataStore dataStore, bytes32 positionKey) internal view returns (uint256) {
        bytes32[] memory orderKeys = AutoCancelUtils.getAutoCancelOrderKeys(dataStore, positionKey);

        uint256 total;

        for (uint256 i; i < orderKeys.length; i++) {
            total += dataStore.getUint(
                keccak256(abi.encode(orderKeys[i], OrderStoreUtils.CALLBACK_GAS_LIMIT))
            );
        }

        return total;
    }
}
