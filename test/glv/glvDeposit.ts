import { expect } from "chai";
import { ethers } from "hardhat";

import { createGlvDeposit, getGlvDepositCount, getGlvDepositKeys, handleGlvDeposit } from "../../utils/glv";
import { deployFixture } from "../../utils/fixture";
import { expandDecimals } from "../../utils/math";
import { getBalanceOf } from "../../utils/token";
import { errorsContract } from "../../utils/error";
import * as keys from "../../utils/keys";
import { increaseTime } from "../../utils/time";
import { printGasUsage } from "../../utils/gas";

describe("glv deposits", () => {
  const { provider } = ethers;
  const { AddressZero } = ethers.constants;

  let fixture;
  let user0, user1, user2;
  let reader, dataStore, ethUsdMarket, btcUsdMarket, wnt, usdc, glvRouter, ethUsdGlvAddress;

  beforeEach(async () => {
    fixture = await deployFixture();

    ({ user0, user1, user2 } = fixture.accounts);
    ({ reader, dataStore, ethUsdMarket, btcUsdMarket, wnt, usdc, glvRouter, ethUsdGlvAddress } = fixture.contracts);
  });

  describe("create glv deposit, validations", () => {
    let params;
    const badAddress = ethers.constants.AddressZero.slice(0, -1) + "1";

    beforeEach(async () => {
      params = {
        glv: ethUsdGlvAddress,
        receiver: user1,
        callbackContract: user2,
        market: ethUsdMarket,
        initialLongToken: ethUsdMarket.longToken,
        initialShortToken: ethUsdMarket.shortToken,
        longTokenSwapPath: [],
        shortTokenSwapPath: [],
        minGlvTokens: 100,
        shouldUnwrapNativeToken: true,
        executionFee: "0",
        callbackGasLimit: "200000",
        gasUsageLabel: "createGlvDeposit",
      };
    });

    it("EmptyAccount", async () => {
      await expect(
        createGlvDeposit(fixture, { ...params, account: { address: ethers.constants.AddressZero } })
      ).to.be.revertedWithCustomError(errorsContract, "EmptyAccount");
    });

    it("EmptyGlv", async () => {
      await expect(createGlvDeposit(fixture, { ...params, glv: badAddress }))
        .to.be.revertedWithCustomError(errorsContract, "EmptyGlv")
        .withArgs(badAddress);
    });

    it("GlvUnsupportedMarket", async () => {
      await expect(createGlvDeposit(fixture, { ...params, market: btcUsdMarket }))
        .to.be.revertedWithCustomError(errorsContract, "GlvUnsupportedMarket")
        .withArgs(ethUsdGlvAddress, btcUsdMarket.marketToken);
    });

    // TODO market is not enabled in GLV
    // TODO market is not enabled globally
    // TODO validate swaps

    it("InvalidGlvDepositInitialLongToken", async () => {
      await expect(createGlvDeposit(fixture, { ...params, isMarketTokenDeposit: true }))
        .to.be.revertedWithCustomError(errorsContract, "InvalidGlvDepositInitialLongToken")
        .withArgs(ethUsdMarket.longToken);
    });

    it("InvalidGlvDepositInitialShortToken", async () => {
      await expect(createGlvDeposit(fixture, { ...params, isMarketTokenDeposit: true, initialLongToken: AddressZero }))
        .to.be.revertedWithCustomError(errorsContract, "InvalidGlvDepositInitialShortToken")
        .withArgs(ethUsdMarket.shortToken);
    });

    it("InvalidGlvDepositSwapPath", async () => {
      await expect(
        createGlvDeposit(fixture, {
          ...params,
          isMarketTokenDeposit: true,
          initialLongToken: AddressZero,
          initialShortToken: AddressZero,
          longTokenSwapPath: [ethUsdMarket.marketToken],
          shortTokenSwapPath: [ethUsdMarket.marketToken, btcUsdMarket.marketToken],
        })
      )
        .to.be.revertedWithCustomError(errorsContract, "InvalidGlvDepositSwapPath")
        .withArgs(1, 2);
    });
  });

  it("create glv deposit", async () => {
    const params = {
      glv: ethUsdGlvAddress,
      receiver: user1,
      callbackContract: user2,
      market: ethUsdMarket,
      initialLongToken: ethUsdMarket.longToken,
      initialShortToken: ethUsdMarket.shortToken,
      longTokenSwapPath: [],
      shortTokenSwapPath: [],
      minGlvTokens: 100,
      longTokenAmount: expandDecimals(10, 18),
      shortTokenAmount: expandDecimals(10 * 5000, 6),
      executionFee: "500",
      shouldUnwrapNativeToken: true,
      callbackGasLimit: "200000",
      gasUsageLabel: "createGlvDeposit",
    };

    await createGlvDeposit(fixture, params);

    const block = await provider.getBlock("latest");
    const glvDepositKeys = await getGlvDepositKeys(dataStore, 0, 1);
    const glvDeposit = await reader.getGlvDeposit(dataStore.address, glvDepositKeys[0]);

    expect(glvDeposit.glv).eq(ethUsdGlvAddress);
    expect(glvDeposit.account).eq(user0.address);
    expect(glvDeposit.receiver).eq(user1.address);
    expect(glvDeposit.callbackContract).eq(user2.address);
    expect(glvDeposit.market).eq(ethUsdMarket.marketToken);
    expect(glvDeposit.initialLongToken).eq(ethUsdMarket.longToken);
    expect(glvDeposit.initialShortToken).eq(ethUsdMarket.shortToken);
    expect(glvDeposit.longTokenSwapPath).deep.eq([]);
    expect(glvDeposit.shortTokenSwapPath).deep.eq([]);
    expect(glvDeposit.initialLongTokenAmount).eq(expandDecimals(10, 18));
    expect(glvDeposit.initialShortTokenAmount).eq(expandDecimals(10 * 5000, 6));
    expect(glvDeposit.minGlvTokens).eq(100);
    expect(glvDeposit.updatedAtBlock).eq(block.number);
    expect(glvDeposit.executionFee).eq("500");
    expect(glvDeposit.callbackGasLimit).eq("200000");
    expect(glvDeposit.shouldUnwrapNativeToken).eq(true);
  });

  it("create glv deposit, market tokens", async () => {
    const params = {
      glv: ethUsdGlvAddress,
      receiver: user1,
      callbackContract: user2,
      market: ethUsdMarket,
      initialLongToken: AddressZero,
      initialShortToken: AddressZero,
      longTokenSwapPath: [],
      shortTokenSwapPath: [],
      minGlvTokens: 100,
      marketTokenAmount: expandDecimals(15, 18),
      executionFee: "500",
      shouldUnwrapNativeToken: true,
      callbackGasLimit: "200000",
      gasUsageLabel: "createGlvDeposit",
      isMarketTokenDeposit: true,
    };

    await createGlvDeposit(fixture, params);

    const block = await provider.getBlock("latest");
    const glvDepositKeys = await getGlvDepositKeys(dataStore, 0, 1);
    const glvDeposit = await reader.getGlvDeposit(dataStore.address, glvDepositKeys[0]);

    expect(glvDeposit.glv).eq(ethUsdGlvAddress);
    expect(glvDeposit.account).eq(user0.address);
    expect(glvDeposit.receiver).eq(user1.address);
    expect(glvDeposit.callbackContract).eq(user2.address);
    expect(glvDeposit.market).eq(ethUsdMarket.marketToken);
    expect(glvDeposit.initialLongToken).eq(AddressZero);
    expect(glvDeposit.initialShortToken).eq(AddressZero);
    expect(glvDeposit.longTokenSwapPath).deep.eq([]);
    expect(glvDeposit.shortTokenSwapPath).deep.eq([]);
    expect(glvDeposit.initialLongTokenAmount).eq(0);
    expect(glvDeposit.initialShortTokenAmount).eq(0);
    expect(glvDeposit.marketTokenAmount).eq(expandDecimals(15, 18));
    expect(glvDeposit.minGlvTokens).eq(100);
    expect(glvDeposit.updatedAtBlock).eq(block.number);
    expect(glvDeposit.executionFee).eq("500");
    expect(glvDeposit.callbackGasLimit).eq("200000");
    expect(glvDeposit.shouldUnwrapNativeToken).eq(true);
    expect(glvDeposit.isMarketTokenDeposit).eq(true);
  });

  it("execute glv deposit", async () => {
    expect(await getBalanceOf(ethUsdGlvAddress, user0.address)).eq(0);

    await handleGlvDeposit(fixture, {
      create: {
        longTokenAmount: expandDecimals(10, 18),
        shortTokenAmount: expandDecimals(9 * 5000, 6),
      },
    });

    const userBalance = await getBalanceOf(ethUsdGlvAddress, user0.address);
    expect(userBalance).to.be.eq(expandDecimals(95000, 18));

    const marketTokenBalance = await getBalanceOf(ethUsdMarket.marketToken, ethUsdGlvAddress);
    expect(marketTokenBalance).to.be.eq(expandDecimals(95000, 18));

    // expect(await getBalanceOf(ethUsdMarket.marketToken, user0.address)).eq(expandDecimals(95000, 18));

    // await handleDeposit(fixture, {
    //   create: {
    //     initialLongToken: usdc.address,
    //     longTokenAmount: expandDecimals(9 * 5000, 6),
    //     initialShortToken: wnt.address,
    //     shortTokenAmount: expandDecimals(10, 18),
    //     longTokenSwapPath: [ethUsdMarket.marketToken],
    //     shortTokenSwapPath: [ethUsdMarket.marketToken],
    //   },
    // });

    // expect(await getBalanceOf(ethUsdMarket.marketToken, user0.address)).eq(expandDecimals(190000, 18));

    // await handleDeposit(fixture, {
    //   create: {
    //     account: user1,
    //     market: btcUsdMarket,
    //     longTokenAmount: expandDecimals(2, 8),
    //     shortTokenAmount: expandDecimals(10, 18),
    //   },
    //   execute: getExecuteParams(fixture, { tokens: [usdc, wbtc] }),
    // });

    // expect(await getBalanceOf(ethUsdMarket.marketToken, user0.address)).eq(expandDecimals(190000, 18));

    // await handleDeposit(fixture, {
    //   create: {
    //     initialLongToken: usdc.address,
    //     longTokenAmount: expandDecimals(9 * 5000, 6),
    //     initialShortToken: wnt.address,
    //     shortTokenAmount: expandDecimals(10, 18),
    //     longTokenSwapPath: [btcUsdMarket.marketToken],
    //     shortTokenSwapPath: [ethUsdMarket.marketToken],
    //   },
    //   execute: {
    //     ...getExecuteParams(fixture, { tokens: [wnt, usdc, wbtc] }),
    //     expectedCancellationReason: "InvalidSwapOutputToken",
    //   },
    // });

    // expect(await getBalanceOf(ethUsdMarket.marketToken, user0.address)).eq(expandDecimals(190000, 18));

    // await handleDeposit(fixture, {
    //   create: {
    //     longTokenAmount: expandDecimals(10, 18),
    //     shortTokenAmount: expandDecimals(9 * 5000, 6),
    //     minMarketTokens: expandDecimals(500000, 18),
    //   },
    //   execute: {
    //     expectedCancellationReason: "MinMarketTokens",
    //   },
    // });

    // expect(await getBalanceOf(ethUsdMarket.marketToken, user0.address)).eq(expandDecimals(190000, 18));
  });

  it("cancel glv deposit", async () => {
    await dataStore.setUint(keys.REQUEST_EXPIRATION_TIME, 300);

    const params = {
      glv: ethUsdGlvAddress,
      receiver: user1,
      market: ethUsdMarket,
      callbackContract: user2,
      initialLongToken: ethUsdMarket.longToken,
      initialShortToken: ethUsdMarket.shortToken,
      longTokenSwapPath: [],
      shortTokenSwapPath: [],
      minGlvTokens: 100,
      longTokenAmount: expandDecimals(10, 18),
      shortTokenAmount: expandDecimals(10 * 5000, 6),
      executionFee: "500",
      shouldUnwrapNativeToken: false,
      callbackGasLimit: "200000",
      gasUsageLabel: "createGlvDeposit",
    };

    await createGlvDeposit(fixture, params);

    const block = await provider.getBlock("latest");
    const glvDepositKeys = await getGlvDepositKeys(dataStore, 0, 1);
    let glvDeposit = await reader.getGlvDeposit(dataStore.address, glvDepositKeys[0]);

    expect(glvDeposit.glv).eq(ethUsdGlvAddress);
    expect(glvDeposit.account).eq(user0.address);
    expect(glvDeposit.receiver).eq(user1.address);
    expect(glvDeposit.callbackContract).eq(user2.address);
    expect(glvDeposit.market).eq(ethUsdMarket.marketToken);
    expect(glvDeposit.initialLongToken).eq(ethUsdMarket.longToken);
    expect(glvDeposit.initialShortToken).eq(ethUsdMarket.shortToken);
    expect(glvDeposit.longTokenSwapPath).deep.eq([]);
    expect(glvDeposit.shortTokenSwapPath).deep.eq([]);
    expect(glvDeposit.initialLongTokenAmount).eq(expandDecimals(10, 18));
    expect(glvDeposit.initialShortTokenAmount).eq(expandDecimals(10 * 5000, 6));
    expect(glvDeposit.minGlvTokens).eq(100);
    expect(glvDeposit.updatedAtBlock).eq(block.number);
    expect(glvDeposit.executionFee).eq("500");
    expect(glvDeposit.callbackGasLimit).eq("200000");
    expect(glvDeposit.shouldUnwrapNativeToken).eq(false);

    await expect(glvRouter.connect(user1).cancelGlvDeposit(glvDepositKeys[0]))
      .to.be.revertedWithCustomError(errorsContract, "Unauthorized")
      .withArgs(user1.address, "account for cancelGlvDeposit");

    expect(await getGlvDepositCount(dataStore)).eq(1);

    await expect(glvRouter.connect(user0).cancelGlvDeposit(glvDepositKeys[0])).to.be.revertedWithCustomError(
      errorsContract,
      "RequestNotYetCancellable"
    );

    expect(await getGlvDepositCount(dataStore)).eq(1);

    const refTime = (await ethers.provider.getBlock("latest")).timestamp;
    await increaseTime(refTime, 300);

    expect(await wnt.balanceOf(user0.address)).eq(0);
    expect(await usdc.balanceOf(user0.address)).eq(0);

    const txn = await glvRouter.connect(user0).cancelGlvDeposit(glvDepositKeys[0]);

    expect(await wnt.balanceOf(user0.address)).eq(expandDecimals(10, 18));
    expect(await usdc.balanceOf(user0.address)).eq(expandDecimals(10 * 5000, 6));

    glvDeposit = await reader.getGlvDeposit(dataStore.address, glvDepositKeys[0]);

    expect(glvDeposit.glv).eq(AddressZero);
    expect(glvDeposit.account).eq(AddressZero);
    expect(glvDeposit.receiver).eq(AddressZero);
    expect(glvDeposit.callbackContract).eq(AddressZero);
    expect(glvDeposit.market).eq(AddressZero);
    expect(glvDeposit.initialLongToken).eq(AddressZero);
    expect(glvDeposit.initialShortToken).eq(AddressZero);
    expect(glvDeposit.longTokenSwapPath).deep.eq([]);
    expect(glvDeposit.shortTokenSwapPath).deep.eq([]);
    expect(glvDeposit.initialLongTokenAmount).eq(0);
    expect(glvDeposit.initialShortTokenAmount).eq(0);
    expect(glvDeposit.minGlvTokens).eq(0);
    expect(glvDeposit.updatedAtBlock).eq(0);
    expect(glvDeposit.executionFee).eq(0);
    expect(glvDeposit.callbackGasLimit).eq(0);
    expect(glvDeposit.shouldUnwrapNativeToken).eq(false);

    await printGasUsage(provider, txn, "cancelGlvDeposit");
    expect(await getGlvDepositCount(dataStore)).eq(0);

    await expect(glvRouter.connect(user0).cancelGlvDeposit(glvDepositKeys[0])).to.be.revertedWithCustomError(
      errorsContract,
      "EmptyGlvDeposit"
    );
  });
});
