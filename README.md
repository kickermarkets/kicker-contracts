# kicker contracts

redeemable floor pots on robinhood chain (4663) and arc (5042).

a pot is a vault with erc-20 shares (K) holding one core asset: native ETH or a tokenized stock (GLD, NVDA) on robinhood, USDC on arc. coins launched through a pot on the chain's launchpad pay their creator tax onto the pot's floor. shares redeem pro rata for the core asset; floor per share never goes down by design.

## layout

- `src/Kicker.sol` - the pot (minimal-proxy clone): buy / redeem / launch / collect / clip / burn
- `src/KickerFactory.sol` - creates pots, holds the platform and keeper addresses and the registry of trusted factories
- `src/TaxSplit.sol` - per-token tax split for launches with terms (launcher share, buyback share, platform 10%, rest to the floor)
- `src/KickerBuyer.sol` - platform recipient: converts platform shares to GLD and buys and burns KICKER
- `src/FeeRouter.sol` - routes an asset into a pot whose core it is
- `src/arc/ArcPot.sol` - the arc variant: USDC floor, launches through the argus portal
- `test/` - fork tests (53 on robinhood, 9 on arc)

## build and test

```
forge build
forge test --fork-url $PONS_RPC              # robinhood chain fork
forge test --fork-url $ARC_RPC --match-contract ArcPot
```

solc 0.8.26 · optimizer 200 · via-ir · cancun

## deployments

see [DEPLOYMENTS.md](DEPLOYMENTS.md). sources are verified on sourcify.

## security

two rounds of adversarial review per version, fork tests for every finding. no external audit.
