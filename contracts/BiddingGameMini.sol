//SPDX-License-Identifier: Unlicense
pragma solidity 0.6.12;

import "./libs/IBEP20.sol";
import "./libs/SafeBEP20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract BiddingGameMini is Ownable {
	using SafeBEP20 for IBEP20;

	IBEP20 public token;

	uint256 public lastBidTime;
	address public lastBidder;
	address public secondPlace;
	address public thirdPlace;

	uint256 public minimumBidDivider;

	address public burnAddress = 0x000000000000000000000000000000000000dEaD;

	event OnBid(address indexed author, uint256 amount);
	event OnWin(address indexed author, uint256 amount);
	event OnBurn(uint256 amount);

	uint32 public collapseDelay = 7200; //2 hour

	modifier onlyHuman() {
		require(msg.sender == tx.origin);
		_;
	}

	constructor(address _token) public {
		token = IBEP20(_token);
	}

	function participate(uint256 amount, uint32 slippage) public onlyHuman {
		require(!hasWinner(), "winner, claim first");

		uint256 currentBalance = token.balanceOf(address(this));
		require(amount >= currentBalance / 20, "min 5% bid");

		uint256 burnAmount = amount / 10; //10%
		token.safeTransferFrom(msg.sender, burnAddress, burnAmount);
		token.safeTransferFrom(msg.sender, address(this), amount - burnAmount);

		emit OnBid(msg.sender, amount);
		emit OnBurn(burnAmount);

		if (lastBidTime == 0) {
			lastBidTime = block.timestamp;
		}
		secondPlace = lastBidder;
		thirdPlace = secondPlace;
		lastBidder = msg.sender;
	}

	function hasWinner() public view returns (bool) {
		return lastBidTime != 0 && block.timestamp - lastBidTime >= collapseDelay;
	}

	function claimReward() public {
		require(hasWinner(), "no winner yet");

		uint256 totalBalance = token.balanceOf(address(this));
		uint256 winAmount = totalBalance / 2; //50%
		uint256 firstPlaceAmount = (winAmount / 10) * 6; // 50% of the win amount - first winner
		uint256 secondPlaceAmount = (winAmount / 10) * 3; //30% of the win amount - second winner
		uint256 thirdPlaceAmount = winAmount - firstPlaceAmount - secondPlaceAmount; //30% of the win amount - second winner

		uint256 nextRoundAmount = totalBalance / 10; //10%
		uint256 burnAmount = totalBalance - winAmount - nextRoundAmount; //40%

		token.safeTransfer(lastBidder, firstPlaceAmount);
		token.safeTransfer(secondPlace, secondPlaceAmount);
		token.safeTransfer(thirdPlace, thirdPlaceAmount);

		token.safeTransfer(burnAddress, burnAmount);
		lastBidTime = 0;
		emit OnWin(lastBidder, winAmount);
		emit OnBurn(burnAmount);
	}

	function setCollapseDelay(uint32 delay) public onlyOwner {
		require(delay >= 60, "must be at least a minute");
		collapseDelay = delay;
	}

	function setMinBid(uint32 minBid) public onlyOwner {
		require(minBid >= 100, "must be at less than 100");
		minimumBidDivider = minBid;
	}
}
