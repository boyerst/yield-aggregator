pragma solidity ^0.5.16;

import "openzeppelin-solidity/contracts/math/SafeMath.sol";

// 🟠 DAI: Interface for ERC20 DAI contract
interface DAI {
    function approve(address, uint256) external returns (bool);

    function transfer(address, uint256) external returns (bool);

    function transferFrom(
        address,
        address,
        uint256
    ) external returns (bool);

    function balanceOf(address) external view returns (uint256);
}

// 🟠 COMPOUND: Interface for Compound's cDAI contract
  // cTokens are just ERC20 tokens that represent an underlying position in the Compound protocol
  // We mint cDAI which is an interest bearing token
  // With Compound you interact with cDAI directly via the following functions:
interface cDAI {
    function mint(uint256) external returns (uint256);

    function redeem(uint256) external returns (uint256);

    function supplyRatePerBlock() external returns (uint256);
    // This is the balanceOf the smart contract
    function balanceOf(address) external view returns (uint256);
}

 // aTokens are just ERC20 tokens that represent an underlying position in the Aave protocol
  // With Aave you use a lending pool for deposit, withdraw and getReserveData + then use aDAI to check balanceOf
interface aDAI {
    // This is the balanceOf the smart contract
    function balanceOf(address) external view returns (uint256);
}

// 🟠 AAVE: Interface for Aave's lending pool contract
  // This is a skeleton interface for the contract since we don't need all of the internals, only certain functions
    // For example, we don't need to know exactly what happens inside of the deposit function as the deployed smart contract to the mainnet will take care of that logic
    // For deposit(), we only need to know...
      // 1. That it exists
      // 2. That it is external
      // 3. The arguments it takes
      // 4. The data types of the arguments
interface AaveLendingPool {
    function deposit(
        address asset,
        uint256 amount,
        address onBehalfOf,
        uint16 referralCode
    ) external;

    function withdraw(
        address asset,
        uint256 amount,
        address to
    ) external;

    function getReserveData(address asset)
        external
        returns (
            uint256 configuration,
            uint128 liquidityIndex,
            uint128 variableBorrowIndex,
            uint128 currentLiquidityRate,
            uint128 currentVariableBorrowRate,
            uint128 currentStableBorrowRate,
            uint40 lastUpdateTimestamp,
            address aTokenAddress,
            address stableDebtTokenAddress,
            address variableDebtTokenAddress,
            address interestRateStrategyAddress,
            uint8 id
        );
}
// Main logic for aggregator with Deposit, Rebalance, Withdraw functions
// This contract interfaces with the live Aave and Compound contracts on the mainnet
contract Aggregator {
    using SafeMath for uint256;

    // Variables
    string public name = "Yield Aggregator";
    // Ownable, controlled by you
    address public owner;
    // Keep track of where the user balance is stored
      // The address will either be of the cDAI contract or aDAI contract
    address public locationOfFunds; 
    uint256 public amountDeposited;

    // Keep track of the real protocol addresses from mainnet
    // Why DAI dai, cDAI cDai❓❓❓
    // DAI
    DAI dai = DAI(0x6B175474E89094C44Da98b954EedeAC495271d0F);
    // COMPOUND: We call all functions directly with cDAI
    cDAI cDai = cDAI(0x5d3a536E4D6DbD6114cc1Ead35777bAB948E3643);
    // AAVE: We call balanceOf with aDAI, and the rest of the Aave functions with LendingPool
    aDAI aDai = aDAI(0x028171bCA77440897B824Ca71D1c56caC55b68A3);
    AaveLendingPool aaveLendingPool =
        AaveLendingPool(0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9);

    // Events
    event Deposit(address owner, uint256 amount, address depositTo);
    event Withdraw(address owner, uint256 amount, address withdrawFrom);
    event Rebalance(address owner, uint256 amount, address depositTo);

    modifier onlyOwner() {
        require(msg.sender == owner);
        _;
    }

    // Constructor
      // Run when smart contract is created
      // Owner is set to the deployer of the contract
    constructor() public {
        owner = msg.sender;
    }

    // Functions

    // Contract approval occurs before deposit
    function deposit(
        // The amount of DAI we want to deposit
        uint256 _amount,
        // Ingest the APYs from an API on the frontend
          // Best to implement these directly on chain within the smart contract but for purposes of this app we do here
        uint256 _compAPY,
        uint256 _aaveAPY

    ) public onlyOwner {
        // Ensure deposit amount is valid
        require(_amount > 0);


        // Rebalance checks if the protocol that the user initially had their funds deposited into by the smart contract is indeed still the highest APY 
        if (amountDeposited > 0) {
            rebalance(_compAPY, _aaveAPY);
        }

        // DAI already approved by the time we get here
        // Transfer from user account to the smart contract
        dai.transferFrom(msg.sender, address(this), _amount);
        amountDeposited = amountDeposited.add(_amount);

        // Compare interest rates
        // If compyAPY is greater than aaveAPY, then despoit to Compound
        if (_compAPY > _aaveAPY) {
            // Deposit into Compound
            // "Require the amount deposited into compound is 0"❓❓❓
            require(_depositToCompound(_amount) == 0);

            // Update location of funds
            locationOfFunds = address(cDai);
        } else {
            // Deposit into Aave
            _depositToAave(_amount);

            // Update location of funds
            locationOfFunds = address(aaveLendingPool);
        }

        // Emit Deposit event
        emit Deposit(msg.sender, _amount, locationOfFunds);
    }

    function withdraw() public onlyOwner {
        require(amountDeposited > 0);

        // Determine where the user funds are stored
        // locationOfFunds is set after deposits and stored in global variable
        // So we check if the location of the users funds is currently located in the cDai smart contract
        // If so, then withdraw from compound, else withdraw from aave
        if (locationOfFunds == address(cDai)) {
            require(_withdrawFromCompound() == 0);
        } else {
            // Withdraw from Aave
            _withdrawFromAave();
        }

        // Once we have the funds, transfer back to owner
        uint256 balance = dai.balanceOf(address(this));
        dai.transfer(msg.sender, balance);

        emit Withdraw(msg.sender, amountDeposited, locationOfFunds);

        // Reset user balance
        amountDeposited = 0;
    }

    // APYs are passed via deposit() -> rebalance() function call in deposit() -> to here
    function rebalance(uint256 _compAPY, uint256 _aaveAPY) public onlyOwner {
        // Make sure funds are already deposited...
        require(amountDeposited > 0);

        uint256 balance;

        // Compare interest rates
        // "If compAPY is larger than aaveAPY, and the location of the funds is not in the compound protocol, the withdraw from aave, change the balance, deposit to compound"
        if ((_compAPY > _aaveAPY) && (locationOfFunds != address(cDai))) {
            // If compoundRate is greater than aaveRate, and the current
            // location of user funds is not in compound, then we transfer funds.

            _withdrawFromAave();

            balance = dai.balanceOf(address(this));

            _depositToCompound(balance);

            // Update location
            locationOfFunds = address(cDai);

            emit Rebalance(msg.sender, amountDeposited, locationOfFunds);
        } else if (
            (_aaveAPY > _compAPY) &&
            (locationOfFunds != address(aaveLendingPool))
        ) {
            // If aaveRate is greater than compoundRate, and the current
            // location of user funds is not in aave, then we transfer funds.

            _withdrawFromCompound();

            balance = dai.balanceOf(address(this));

            _depositToAave(balance);

            // Update location
            locationOfFunds = address(aaveLendingPool);

            emit Rebalance(msg.sender, amountDeposited, locationOfFunds);
        }
    }

    // We use DAI to approve the contract and cDAI to mint
    function _depositToCompound(uint256 _amount) internal returns (uint256) {
        // Require users' DAI address & # DAI have been approved to interact with the cDAI contract
        require(dai.approve(address(cDai), _amount));

        uint256 result = cDai.mint(_amount);
        return result;
    }

    // Main function = cDAI.redeem()
    function _withdrawFromCompound() internal returns (uint256) {
        uint256 balance = cDai.balanceOf(address(this));
        uint256 result = cDai.redeem(balance);
        return result;
    }

    // Notice their is not minting involved with Aave 
    function _depositToAave(uint256 _amount) internal returns (uint256) {
        require(dai.approve(address(aaveLendingPool), _amount));
        aaveLendingPool.deposit(address(dai), _amount, address(this), 0);
    }

    function _withdrawFromAave() internal {
        uint256 balance = aDai.balanceOf(address(this));
        aaveLendingPool.withdraw(address(dai), balance, address(this));
    }



    // ---------------------------

    function balanceOfContract() public view returns (uint256) {
        if (locationOfFunds == address(cDai)) {
            return cDai.balanceOf(address(this));
        } else {
            return aDai.balanceOf(address(this));
        }
    }

    function balanceWhere() public view returns (address) {
        return locationOfFunds;
    }
}






