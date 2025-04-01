import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

export default buildModule("DeployModule", (m) => {
    const initialSupply = m.getParameter("initialSupply", "1000000000000000000000000"); // 1M tokens

    // Deploy MockToken
    const mockToken = m.contract("MockToken", ["Mock Token", "MTK", 18, initialSupply]);

    // Deploy MockRateOracle
    const rateOracle = m.contract("UniswapV3Oracle");

    // Deploy MockUniswapV3PositionManager
    const positionManager = m.contract("MockUniswapV3PositionManager");

    // Deploy DerivativeVault
    const vault = m.contract("DerivativeVault", [positionManager, rateOracle]);

    return { mockToken, rateOracle, positionManager, vault };
});
