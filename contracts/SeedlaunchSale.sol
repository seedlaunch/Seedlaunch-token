// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "./Seedlaunch.sol";
import "hardhat/console.sol";

library VestingStrategy {
    // calculate vesting amount
    function calculateVesting(uint256 round, uint256 balance, uint256 epoch) public pure returns(uint256) {
        uint256 value;
        if (round == 0 || round == 1) { // first or second round;
            if (epoch == 0) { // initial distribution
                value = balance * 10 / 100;
            } else { // on next months
                value = balance * 9 / 100;
            }
        } else if (round == 2) { // third round
            if (epoch == 0) { // initial distribution
                value = balance * 15 / 100;
            } else if (epoch == 1) { // on second month
                value = balance * 10 / 100;
            } else { // on next months
                value = balance * 75 / 100  / 10;
            }
        } else if (round == 3) { // fourth round
            if (epoch == 0) { // initial distribution
                value = balance * 50 / 100;
            } else { // on next months
                value = balance * 10 / 100;
            }
        }
        return value;
    }
}


contract SeedlaunchSale is ReentrancyGuard, Context, Ownable {

    using SafeMath for uint256;
    uint256 currentRound = 0;

    struct RoundData {
        mapping(address => bool) whitelistedAddresses;
        mapping(address => uint256) boughtBalance; // bought value
        mapping(address => uint256) unlockedBalance; // unlocked value
        mapping(address => uint256) vestingEpoch; // vesting epoch of account
        uint256 cap; // cap of sale tokens
        uint256 price; // price for token
        uint256 tgeTimestamp; // tge timestamp
        uint256 cliff; // cliff period
        uint256 tokenSold; // amount of token sold
    }

    mapping(uint256 => RoundData) roundData;

    Seedlaunch immutable token; // SLT token
    ERC20 immutable payToken; // token for payments

    address payable public wallet; // wallet for payments
    bool isSaleActive;


    constructor (address payable _wallet, ERC20 _payToken, Seedlaunch _token) {
        require(_wallet != address(0), "Wallet is the zero address");
        token = _token; // set SLT token address
        payToken = _payToken; // set token for payments
        wallet = _wallet; // set wallet address for payments

        roundData[0].cap = 4000000 * 10**_token.decimals(); // cap
        roundData[0].price = 3 * 10**_payToken.decimals() / 100; // price $0.03
        roundData[0].cliff = 2 * 30 days; // cliff - 2 months

        roundData[1].cap = 8500000 * 10**_token.decimals(); // cap
        roundData[1].price = 7 * 10**_payToken.decimals() / 100; // price $0.07
        roundData[1].cliff = 2 * 30 days; // cliff period - 2 months

        roundData[2].cap = 21000000 * 10**_token.decimals(); // cap
        roundData[2].price = 9 * 10**token.decimals() / 100; // price $0.09
        roundData[2].cliff = 30 days; // cliff - 1 month

        roundData[3].cap = 2500000 * 10**_token.decimals(); // cap
        roundData[3].price = 158 * 10**token.decimals() / 1000; // price $0.158
        roundData[3].cliff = 0; // no cliff
    }

    // activate sale
    function activeSale() external onlyOwner {
        // can't activate if all rounds are passed
        require(currentRound <= 3, 'token sale is ended');
        isSaleActive = true;
    }

    // buy tokens
    function buy(uint256 amountToBuy, uint256 value) public {
        RoundData storage round = roundData[currentRound];
        require(isSaleActive, 'sale is not active');
        // check if sender whitelisted or it's 4 round and it's public
        require(round.whitelistedAddresses[msg.sender] || currentRound == 3, 'you are not whitelisted');

        // if available amount is lower then passed, buy available amount
        uint256 amount = (round.cap - round.tokenSold) < amountToBuy ? round.cap - round.tokenSold : amountToBuy;
        // calculate needed value
        uint256 neededValue = amount * round.price / 10**payToken.decimals();
        require(value >= neededValue, 'not enough payed');
        bool success = payToken.transferFrom(msg.sender, wallet, neededValue);
        require(success, 'invalid transaction');

        // add tokens to sender bought balance
        round.boughtBalance[msg.sender] += amount;
        // update token sold amount
        round.tokenSold += amount;

        // check if all tokens are sold
        if (round.tokenSold >= round.cap) {
            round.tgeTimestamp = block.timestamp; // set tge timestemp
            currentRound += 1; // move to next round
            isSaleActive = false; // disable sale
        }

        // emit token sale end if passed all rounds
        if (currentRound > 3) {
            token.endTokenSale();
        }
    }

    // whitelist accounts for specific round
    function whitelist(uint256 round, address[] memory addresses) public onlyOwner {
        require(round >= 0 && round <= 2, 'invalid round');
        for (uint i = 0; i < addresses.length; i++) {
            roundData[round].whitelistedAddresses[addresses[i]] =  true;
        }
    }

    // claim tokens
    function claim(uint256 round) public {
        RoundData storage selectedRound = roundData[round];

        require(round >= 0 && round <= 3, 'invalid round');
        require(selectedRound.tgeTimestamp > 0, 'tge is not passed');
        require(selectedRound.boughtBalance[msg.sender] > selectedRound.unlockedBalance[msg.sender], 'your balance is already unlocked');
        require(isAvailablePeriod(round, msg.sender), 'your balance is not unlocked');

        // transfer available tokens to account
        uint256 balanceToClaim = VestingStrategy.calculateVesting(round, selectedRound.boughtBalance[msg.sender], selectedRound.vestingEpoch[msg.sender]);
        bool success = token.transfer(msg.sender, balanceToClaim);
        require(success, 'invalid transfer');

        selectedRound.unlockedBalance[msg.sender] += balanceToClaim; // update unlocked balance
        selectedRound.vestingEpoch[msg.sender] += 1; // increase account vesting epoch
    }

    // get sender locked balance
    function getLockedBalance(uint256 round) public view returns(uint256) {
        require(round >= 0 && round <= 2, 'invalid round');
        require(roundData[round].whitelistedAddresses[msg.sender], 'you are not whitelisted');
        return roundData[round].boughtBalance[msg.sender] - roundData[round].unlockedBalance[msg.sender];
    }

    // check if period is available
    function isAvailablePeriod(uint256 round, address user) internal returns(bool) {
        // check if cliff is passed
        if ((roundData[round].tgeTimestamp + roundData[round].cliff) > block.timestamp) {
            return false;
        }
        // check if next user vesting epoch is available
        if ((roundData[round].tgeTimestamp + roundData[round].cliff + (roundData[round].vestingEpoch[user] * 30 days)) > block.timestamp) {
            return false;
        }
        return true;
    }

}
