// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.0;

import "../data/DataStore.sol";
import "../event/EventEmitter.sol";

import "./DepositVault.sol";
import "./DepositStoreUtils.sol";
import "./DepositEventUtils.sol";

import "../nonce/NonceUtils.sol";

import "../gas/GasUtils.sol";
import "../callback/CallbackUtils.sol";
import "../utils/AccountUtils.sol";

// @title DepositUtils
// @dev Library for deposit functions, to help with the depositing of liquidity
// into a market in return for market tokens
library DepositUtils {
    using SafeCast for uint256;
    using SafeCast for int256;

    using Price for Price.Props;
    using Deposit for Deposit.Props;

    enum DepositType {
        Normal,
        Shift,
        Glv
    }

    // @dev CreateDepositParams struct used in createDeposit to avoid stack
    // too deep errors
    //
    // @param receiver the address to send the market tokens to
    // @param callbackContract the callback contract
    // @param uiFeeReceiver the ui fee receiver
    // @param market the market to deposit into
    // @param minMarketTokens the minimum acceptable number of liquidity tokens
    // @param shouldUnwrapNativeToken whether to unwrap the native token when
    // sending funds back to the user in case the deposit gets cancelled
    // @param executionFee the execution fee for keepers
    // @param callbackGasLimit the gas limit for the callbackContract
    struct CreateDepositParams {
        address receiver;
        address callbackContract;
        address uiFeeReceiver;
        address market;
        address initialLongToken;
        address initialShortToken;
        address[] longTokenSwapPath;
        address[] shortTokenSwapPath;
        uint256 minMarketTokens;
        bool shouldUnwrapNativeToken;
        uint256 executionFee;
        uint256 callbackGasLimit;
    }

    // @dev creates a deposit
    //
    // @param dataStore DataStore
    // @param eventEmitter EventEmitter
    // @param depositVault DepositVault
    // @param account the depositing account
    // @param params CreateDepositParams
    function createDeposit(
        DataStore dataStore,
        EventEmitter eventEmitter,
        DepositVault depositVault,
        address account,
        CreateDepositParams memory params
    ) external returns (bytes32) {
        // 1. 账户验证
        AccountUtils.validateAccount(account);
        // 2. 校验交易对是否已启动, 验证 swap 路径是否正确
        Market.Props memory market = MarketUtils.getEnabledMarket(dataStore, params.market);
        MarketUtils.validateSwapPath(dataStore, params.longTokenSwapPath);
        MarketUtils.validateSwapPath(dataStore, params.shortTokenSwapPath);

        // 3. 记录用户转入的多头代币和空头代币数量
        // 如果 initialLongToken 和 initialShortToken 相同，则只有 initialLongTokenAmount 非零
        uint256 initialLongTokenAmount = depositVault.recordTransferIn(params.initialLongToken);
        uint256 initialShortTokenAmount = depositVault.recordTransferIn(params.initialShortToken);
    
        address wnt = TokenUtils.wnt(dataStore);
        // 4. 处理执行费用,并计算实际存入token数量
        if (params.initialLongToken == wnt) {
            // 如果多头代币是原生代币, 则从存入的多头代币数量中扣除执行费
            initialLongTokenAmount -= params.executionFee;
        } else if (params.initialShortToken == wnt) {
            // 如果空头代币是原生代币, 也要扣掉执行费
            initialShortTokenAmount -= params.executionFee;
        } else {
            // 如果没有存入原生代币提供流动性, 则校验执行费用是否正确
            uint256 wntAmount = depositVault.recordTransferIn(wnt);
            if (wntAmount < params.executionFee) {
                revert Errors.InsufficientWntAmountForExecutionFee(wntAmount, params.executionFee);
            }

            params.executionFee = wntAmount;
        }

        // 校验存入的多头和空头金额, 确认不是 空单
        if (initialLongTokenAmount == 0 && initialShortTokenAmount == 0) {
            revert Errors.EmptyDepositAmounts();
        }

        // 校验流动性证明接收地址
        AccountUtils.validateReceiver(params.receiver);

        // 6. 创建创建添加流动性订单
        Deposit.Props memory deposit = Deposit.Props(
            Deposit.Addresses(
                account,
                params.receiver,
                params.callbackContract,
                params.uiFeeReceiver,
                market.marketToken,
                params.initialLongToken,
                params.initialShortToken,
                params.longTokenSwapPath,
                params.shortTokenSwapPath
            ),
            Deposit.Numbers(
                initialLongTokenAmount,
                initialShortTokenAmount,
                params.minMarketTokens,
                Chain.currentBlockNumber(),
                Chain.currentTimestamp(),
                params.executionFee,
                params.callbackGasLimit
            ),
            Deposit.Flags(
                params.shouldUnwrapNativeToken
            )
        );

        // 7. 校验回调方法和 执行费用
        CallbackUtils.validateCallbackGasLimit(dataStore, deposit.callbackGasLimit());

        uint256 estimatedGasLimit = GasUtils.estimateExecuteDepositGasLimit(dataStore, deposit);
        uint256 oraclePriceCount = GasUtils.estimateDepositOraclePriceCount(
            deposit.longTokenSwapPath().length + deposit.shortTokenSwapPath().length
        );
        GasUtils.validateExecutionFee(dataStore, estimatedGasLimit, params.executionFee, oraclePriceCount);

        // 8. 保存订单到depositVault
        bytes32 key = NonceUtils.getNextKey(dataStore);

        DepositStoreUtils.set(dataStore, key, deposit);

        // 9. 触发事件
        DepositEventUtils.emitDepositCreated(eventEmitter, key, deposit, DepositType.Normal);

        return key;
    }

    // @dev cancels a deposit, funds are sent back to the user
    //
    // @param dataStore DataStore
    // @param eventEmitter EventEmitter
    // @param depositVault DepositVault
    // @param key the key of the deposit to cancel
    // @param keeper the address of the keeper
    // @param startingGas the starting gas amount
    function cancelDeposit(
        DataStore dataStore,
        EventEmitter eventEmitter,
        DepositVault depositVault,
        bytes32 key,
        address keeper,
        uint256 startingGas,
        string memory reason,
        bytes memory reasonBytes
    ) external {
        // 63/64 gas is forwarded to external calls, reduce the startingGas to account for this
        startingGas -= gasleft() / 63;

        Deposit.Props memory deposit = DepositStoreUtils.get(dataStore, key);
        if (deposit.account() == address(0)) {
            revert Errors.EmptyDeposit();
        }

        if (
            deposit.initialLongTokenAmount() == 0 &&
            deposit.initialShortTokenAmount() == 0
        ) {
            revert Errors.EmptyDepositAmounts();
        }

        DepositStoreUtils.remove(dataStore, key, deposit.account());

        if (deposit.initialLongTokenAmount() > 0) {
            depositVault.transferOut(
                deposit.initialLongToken(),
                deposit.account(),
                deposit.initialLongTokenAmount(),
                deposit.shouldUnwrapNativeToken()
            );
        }

        if (deposit.initialShortTokenAmount() > 0) {
            depositVault.transferOut(
                deposit.initialShortToken(),
                deposit.account(),
                deposit.initialShortTokenAmount(),
                deposit.shouldUnwrapNativeToken()
            );
        }

        DepositEventUtils.emitDepositCancelled(
            eventEmitter,
            key,
            deposit.account(),
            reason,
            reasonBytes
        );

        EventUtils.EventLogData memory eventData;
        CallbackUtils.afterDepositCancellation(key, deposit, eventData);

        GasUtils.payExecutionFee(
            dataStore,
            eventEmitter,
            depositVault,
            key,
            deposit.callbackContract(),
            deposit.executionFee(),
            startingGas,
            GasUtils.estimateDepositOraclePriceCount(deposit.longTokenSwapPath().length + deposit.shortTokenSwapPath().length),
            keeper,
            deposit.receiver()
        );
    }
}
