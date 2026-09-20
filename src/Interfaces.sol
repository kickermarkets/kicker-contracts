// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
}
interface IERC20Meta { function name() external view returns (string memory); }

// pons v2 curve (docs.ponsfamily.com/v2)
interface IPonsEscrow {
    function claim() external;
    function claimToken(address token) external;
}

interface IPonsHook {
    /// after graduation fees accrue on the hook; swept by the pons operator, or by the creator side when no internal swap is needed
    function sweepPoolFees(bytes32 poolId, uint256 minConversionQuoteOut, uint256 minBuybackTokensOut) external;
}

interface IPonsCurve {
    function buy(uint256 quoteIn, uint256 minTokensOut, address recipient) external payable returns (uint256);
    function sell(uint256 tokensIn, uint256 minQuoteOut, address recipient) external returns (uint256);
    function getReserves() external view returns (uint256 quoteReserve, uint256 tokenReserve);
    function graduated() external view returns (bool);
    function readyToGraduate() external view returns (bool);
    function isNativeQuote() external view returns (bool);
    function pairToken() external view returns (address);
    function feeBps() external view returns (uint256);
    function creatorTaxBps() external view returns (uint256);
    function sweepFees(uint256 minBuybackTokensOut) external;
    function graduationThreshold() external view returns (uint256);
    function realQuoteReserve() external view returns (uint256);
}

interface IPonsFactory {
    struct Socials { string twitter; string telegram; string discord; string website; string farcaster; }
    struct TokenParams { string name; string symbol; string logo; string description; Socials socials; address creatorFeeRecipient; uint16 creatorTaxBps; bool buybackEnabled; bytes32 expectedEconomics; bytes32 salt; }
    function launchToken(TokenParams calldata params, uint256 launchConfigId, address pairToken) external payable returns (address token, address curve);
    /// move the fee recipient: only the current recipient may call; what is already accrued does not move
    function transferCreatorFeeRecipient(address token, address newRecipient) external;
    function previewLaunchEconomics(uint256 launchConfigId, address pairToken) external view returns (bytes32);
    function launchFee() external view returns (uint256);
    struct LaunchedToken {
        address token; address curve; address deployer; address creatorFeeRecipient; address pairToken;
        uint256 graduationThreshold; uint24 poolFee; int24 tickSpacing; uint16 creatorTaxBps;
        bool buybackEnabled; uint8 phase; uint256 sweptQuote; uint256 sweptTokens; uint256 sweptAt; bool exists;
    }
    function getLaunchedToken(address token) external view returns (LaunchedToken memory);
}

// uniswap v4 core, minimal
struct PoolKey { address currency0; address currency1; uint24 fee; int24 tickSpacing; address hooks; }
struct SwapParams { bool zeroForOne; int256 amountSpecified; uint160 sqrtPriceLimitX96; }

interface IPoolManager {
    function unlock(bytes calldata data) external returns (bytes memory);
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData) external returns (int256 delta);
    function sync(address currency) external;
    function settle() external payable returns (uint256);
    function take(address currency, address to, uint256 amount) external;
    function extsload(bytes32 slot) external view returns (bytes32);
}

interface IUnlockCallback {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}
