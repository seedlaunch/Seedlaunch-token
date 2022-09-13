// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Capped.sol";

contract Seedlaunch is ERC20Capped, Ownable {
  using SafeMath for uint256;

  event TGEPassed();
  event MainnetLaunched();
  event DistributionEpochFinished(AllocationGroup group, uint256 epoch);
  event TokenSaleEnded();

  uint256 public TGETimestamp = 0;
  uint256 public mainnetLaunchTimestamp = 0;

  uint256 private _totalSupply;
  uint8 constant private _decimals = 18;
  uint256 constant public _maxTokens = 300000000 * 10**_decimals;
  string private _symbol;
  string private _name;
  address tokenSale; // Token sale contract

  struct GroupData {
    uint256 cliff; // cliff period
    uint256 unlockDelay; // delay between unlocks
    uint256 unlockPercentage; // unlock percentage
    mapping (address => AccountData) accounts; // whitelisted accounts
    address[] addresses; // whitelisted addresses
    uint256 initialUnlock; // initial unlock percentage
    uint256 currentEpoch; // current epoch
  }

  enum AllocationGroup {
    Team, Ecosystem, Advisor, Liquidity, Marketing, Reserve
  }

  struct AccountData {
    uint256 balance; // total balance
    uint256 unlockedBalance; // unlocked part of balance
    uint256 index;
    uint8 epoch; // account claim epoch
  }

  mapping (AllocationGroup => GroupData) public groups;

  constructor() ERC20('Seedlaunch', 'SLT') ERC20Capped(_maxTokens * 10**18) {

    // Setup data for Team allocation
    groups[AllocationGroup.Team].cliff = 6 * 30 days; // cliff 6 months
    groups[AllocationGroup.Team].unlockDelay = 3 * 30 days; // time between unlocks - 3 months
    groups[AllocationGroup.Team].initialUnlock = 0; // initial unlock 0
    groups[AllocationGroup.Team].unlockPercentage = 1250; // percentage per unlock - 12.5%

    // Setup data for Ecosystem allocation
  groups[AllocationGroup.Ecosystem].cliff = 0; // no cliff
    groups[AllocationGroup.Ecosystem].unlockDelay = 3 * 30 days; // time between unlocks - 3 months
    groups[AllocationGroup.Ecosystem].initialUnlock = 0; // initial unlock 0
    groups[AllocationGroup.Ecosystem].unlockPercentage = 1000; // percentage per unlock - 10%

    // Setup data for Advisor allocation
  groups[AllocationGroup.Advisor].cliff = 6 * 30 days; // cliff 6 months
    groups[AllocationGroup.Advisor].unlockDelay = 30 days; // time between unlocks - 1 month
    groups[AllocationGroup.Advisor].initialUnlock = 0; // initial unlock 0
    groups[AllocationGroup.Advisor].unlockPercentage = 1000; // percentage per unlock - 10%

    groups[AllocationGroup.Liquidity].cliff = 0; // no cliff
    groups[AllocationGroup.Liquidity].unlockDelay = 2 * 30 days; // time between unlocks - 2 months
    groups[AllocationGroup.Liquidity].initialUnlock = 20; // initial unlock percentage - 20%
    groups[AllocationGroup.Liquidity].unlockPercentage = 1000; // percentage per unlock - 10%

    groups[AllocationGroup.Marketing].cliff = 0; // no cliff
    groups[AllocationGroup.Marketing].unlockDelay = 2 * 30 days; // time between unlocks - 2 months
    groups[AllocationGroup.Marketing].initialUnlock = 10; // initial unlock percentage - 10%
    groups[AllocationGroup.Marketing].unlockPercentage = 375; // percentage per unlock - 3.75%

    groups[AllocationGroup.Reserve].cliff = 365 days; // cliff - 1 year
    groups[AllocationGroup.Reserve].unlockDelay = 3 * 30 days; // time between unlocks 3 months
    groups[AllocationGroup.Reserve].initialUnlock = 0; // initial unlock 0
    groups[AllocationGroup.Reserve].unlockPercentage = 2500; // percentage per unlock

  }

  // Adds group participants
  function addParticipants(AllocationGroup group, address[] memory participants, uint256[] memory balances) public onlyOwner{
    require(TGETimestamp == 0, "Tokens were already allocated");
    require(participants.length == balances.length, "Participants and balances should have the same length");
    require(participants.length != 0, "There should be at least one participant");

    for (uint256 i=0; i<participants.length; i++) {
      _addParticipant(group, participants[i], balances[i]);
    }
  }

  //get group participants
  function getGroup(AllocationGroup group) external view returns(address[] memory)  {
    return groups[group].addresses;
  }

  // Removes participant`s account data and his address from array of addresses
  function removeParticipant(AllocationGroup group, address account) public onlyOwner {
    require(TGETimestamp == 0, "Tokens were already allocated");

    delete groups[group].addresses[groups[group].accounts[account].index];
    delete groups[group].accounts[account];
  }

  function setTGEPassed() public onlyOwner {
    require(TGETimestamp == 0, "TGE is already passed");
    TGETimestamp = block.timestamp;
    emit TGEPassed();
  }

  // Sets that mainnet was launched
  function setMainnetLaunched() public onlyOwner{
    require(TGETimestamp != 0, "Cannot set mainnet launched before TGE");
    require(mainnetLaunchTimestamp == 0, "Mainnet is already launched");

    mainnetLaunchTimestamp = block.timestamp;

    emit MainnetLaunched();
  }

  // Adds new participant if not exists
  function _addParticipant(AllocationGroup group, address account, uint256 balance) internal {
    if (groups[group].accounts[account].balance == 0) {
      groups[group].accounts[account].balance = balance;
      groups[group].accounts[account].epoch = 0;
      groups[group].accounts[account].index = groups[group].addresses.length;
      groups[group].addresses.push(account);
    }
  }

  function calculateVestingAmount(address account, AllocationGroup group) internal view returns (uint256) {
    uint256 pendingTokens = 0;

    if (groups[group].accounts[account].epoch == 0) {
      // if cliff is passed, unlock initial percentage to account
      pendingTokens = groups[group].accounts[account].balance * groups[group].initialUnlock / 100;
    } else {
      // if not first epoch, unlock default percentage for user
      pendingTokens = groups[group].accounts[account].balance * groups[group].unlockPercentage / 100 / 100;
    }

    return pendingTokens;
  }

  // check if distribution for group is passed
  function isDistributionPassed(AllocationGroup group) internal view returns(bool) {
    // distribution is passed if sum of initial percentage with percentage per epochs is more then 100
    return (groups[group].currentEpoch * groups[group].unlockPercentage / 100 + groups[group].initialUnlock) > 100;
  }

  // check if period for distribution is valid
  function isAvailablePeriod(uint256 epochNumber, uint256 lockPeriod, uint256 initialTimestamp, uint256 delay) internal view returns (bool) {
    // period is available if lockPeriod(cliff) + epoch passed amount * epoch delay is less then current timestamp
    uint256 availableEpochTimestamp = lockPeriod + (delay * epochNumber) + initialTimestamp;
    return block.timestamp > availableEpochTimestamp;
  }

  // distribute tokens for specific group
  function distribute(AllocationGroup group) public {
    // distribution is not started if cliff is not passed
    require(block.timestamp >= (TGETimestamp + groups[group].cliff), "Distribution is not started yet");
    require(!isDistributionPassed(group) , "Distribution is already passed");

    GroupData storage groupData = groups[group];

    require(isAvailablePeriod(
        groupData.currentEpoch,
        groupData.cliff,
          TGETimestamp,
    groupData.unlockDelay
      ), "It's too early for distribution");

    // iterate through whitelisted users and distribute tokens
    for (uint i=0; i<groups[group].addresses.length; i++) {
      // We distribute if user didn't claim his funds already
      address userAddress = groups[group].addresses[i];
      if (groups[group].accounts[userAddress].epoch <= groupData.currentEpoch && userAddress != address(0)) {
        // Calculate and send funds to user
        uint256 vestingAmount = calculateVestingAmount(userAddress, group);
        _mint(userAddress, vestingAmount);

        // Update user epoch
        updateAccountData(userAddress, group, vestingAmount);
      }
    }
    // increase group epoch after distribution
    groupData.currentEpoch += 1;
  }

  // claim tokens for sender
  function claim(AllocationGroup group) public {
    require(canClaim(msg.sender, group), "You cannot claim");

    uint256 vestingAmount = calculateVestingAmount(msg.sender, group);

    _mint(msg.sender, vestingAmount);

    updateAccountData(msg.sender, group, vestingAmount);
  }

  // check if account can claim
  function canClaim(address account, AllocationGroup group) internal view returns (bool) {
    AccountData storage accountData = groups[group].accounts[account];

    // if unlocked balance is bigger or equal initial balance return false
    if (accountData.unlockedBalance >= accountData.balance) return false;

    // check if period for claim is available
    return isAvailablePeriod(accountData.epoch, groups[group].cliff, TGETimestamp, groups[group].unlockDelay);
  }

  function updateAccountData(address account, AllocationGroup group, uint256 vestingAmount) internal {
    AccountData storage accountData = groups[group].accounts[account];
    // if vestingAmount is bigger then available balance, use available balance
    uint256 amountToUpdate = ((accountData.balance >= (accountData.unlockedBalance + vestingAmount))) ? vestingAmount : accountData.balance - accountData.unlockedBalance;

    accountData.unlockedBalance += amountToUpdate; // add unlocked amount to unlocked balance
    accountData.epoch += 1; // increase user epoch
  }

  // send tokens to token sal contract
  function startTokenSale(address _tokenSale) external onlyOwner {
    _mint(_tokenSale, _maxTokens * 12 / 100);
    tokenSale = _tokenSale;
  }

  function endTokenSale() external {
    require(msg.sender == tokenSale, 'unauthorized contract');
    emit TokenSaleEnded();
  }



}
