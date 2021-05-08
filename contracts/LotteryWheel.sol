pragma solidity 0.6.12;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./libs/SafeBEP20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

interface ISafeRandomGenerator {
	function generateRandomHash() external returns (bytes32);
}

contract LotteryWheel is Ownable, ReentrancyGuard {
	using SafeMath for uint256;
	using SafeMath for uint8;
	using SafeBEP20 for IBEP20;
	using Address for address;

	//-------------------------------------------------------------------------
	// EVENTS
	//-------------------------------------------------------------------------

	event WinningWheel(uint256 indexed result);
	event Buy(address indexed sender, uint256 amount, uint8 color);
	event PlayerWin(address indexed sender, uint256 amount, uint256 color);
	event AmountBurn(uint256 amountBurned);
	event ClaimedRewards(address indexed sender, uint256 amountClaimed);

	//-------------------------------------------------------------------------
	// ADDRESSES
	//-------------------------------------------------------------------------

	address public burn = 0x000000000000000000000000000000000000dEaD;
	ISafeRandomGenerator private _randomGenerator;
	IBEP20 public dumplings;

	//-------------------------------------------------------------------------
	// ATTRIBUTES
	//-------------------------------------------------------------------------

	uint256 public BURN_FEE = 4; // 4%
	uint256 public JACKPOT_FEE = 25;
	uint256 public WHEEL_BANK_FEE = 5;
	uint256 public MAX_BEFORE_SPIN = 300;

	uint256 private constant MIN_COLOR = 1; // 1
	uint256 private constant MAX_COLOR = 3; // 3

	uint256 private constant DECIMAL_MULTIPLIER = 10**18;
	uint256 public DELAY_BEFORE_SPIN = 30 seconds;
	uint256 public spin_timestamp = 0;

	uint256 public totalPot = 0;
	uint256 public MAX_BET_ALLOWED = 50; //100
	uint256 public MIN_BET_ALLOWED = 1; //1

	uint256 public wheelBank = 0;
	uint256 public jackpot = 0;

	uint256 public amountBurned = 0;

	uint256 public totalRedPot;
	uint256 public totalGreenPot;
	uint256 public totalBlackPot;

	uint256[] private winNumbersHistory;

	mapping(address => uint256) public greenBet;
	address[] private greenPlayers;

	mapping(address => uint256) public redBet;
	address[] private redPlayers;

	mapping(address => uint256) public blackBet;
	address[] private blackPlayers;

	mapping(address => uint256) public rewards;

	//-------------------------------------------------------------------------
	// MODIFIERS
	//-------------------------------------------------------------------------

	modifier notContract() {
		require(!address(msg.sender).isContract(), "contract not allowed");
		require(msg.sender == tx.origin, "proxy contract not allowed");
		_;
	}

	constructor(IBEP20 _dumplings, uint256 _amountBurned) public {
		dumplings = _dumplings;
		amountBurned = _amountBurned;
	}

	function bet(uint256 amount, uint8 color) public nonReentrant notContract() {
		require(spin_timestamp + DELAY_BEFORE_SPIN < block.timestamp, "BET: 30 seconds between each spin");
		require(amount <= MAX_BET_ALLOWED, "BET: Amount exceed MAX BET Allowed");
		require(color <= MAX_COLOR && color >= MIN_COLOR, "BET: Wrong color");
		require(totalPot.add(amount) <= MAX_BEFORE_SPIN, "BET: Exceeded limit");

		if (color == 1) {
			_betOnColor(redBet, amount, redPlayers);
			totalRedPot += amount;
		} else if (color == 2) {
			_betOnColor(blackBet, amount, blackPlayers);
			totalBlackPot += amount;
		} else {
			_betOnColor(greenBet, amount, greenPlayers);
			totalGreenPot += amount;
		}

		dumplings.safeTransferFrom(msg.sender, address(this), amount.mul(DECIMAL_MULTIPLIER));
		emit Buy(msg.sender, amount, color);

		totalPot += amount;

		if (totalPot == MAX_BEFORE_SPIN) {
			_spinWheel(msg.sender);
		}
	}

	function _betOnColor(
		mapping(address => uint256) storage betters,
		uint256 amount,
		address[] storage players
	) private {
		bool contain = false;

		uint256 depositedAmount = betters[msg.sender];
		require(depositedAmount < MAX_BET_ALLOWED, "BET: MAX_BET");

		betters[msg.sender] += amount;

		for (uint256 i = 0; i < players.length; i++) {
			if (players[i] == msg.sender) {
				contain = true;
			}
		}

		if (!contain) {
			players.push(msg.sender);
		}
	}

	function _generateRandomNumber(address sender) private returns (uint256) {
		uint256 randomHash =
			uint256(keccak256(abi.encodePacked(blockhash(block.number - 1), now + uint256(sender), _randomGenerator.generateRandomHash()))).mod(100);
		return randomHash;
	}

	function _spinWheel(address sender) private returns (uint8) {
		require(totalPot > 0);

		uint256 result = _generateRandomNumber(sender);
		winNumbersHistory.push(result);

		emit WinningWheel(result);

		// Burn 4% of the totalPot
		uint256 dumplingstoBurn = totalPot.mul(BURN_FEE).div(100).mul(DECIMAL_MULTIPLIER);
		amountBurned += dumplingstoBurn;
		dumplings.safeTransfer(burn, dumplingstoBurn);
		emit AmountBurn(dumplingstoBurn);

		totalPot = totalPot.sub(totalPot.mul(BURN_FEE).div(100));
		uint256 totalPottmp = totalPot;

		if (result < 4 && totalGreenPot > 0) {
			uint256 jackpotToBurn = jackpot.mul(JACKPOT_FEE).div(100);
			dumplings.safeTransfer(burn, jackpotToBurn.mul(DECIMAL_MULTIPLIER));
			amountBurned += jackpotToBurn.mul(DECIMAL_MULTIPLIER);

			uint256 jackpotToBank = jackpot.mul(WHEEL_BANK_FEE).div(100);
			wheelBank += jackpotToBank;

			jackpot -= (jackpotToBurn + jackpotToBank);
			uint256 totalJackpot = jackpot;

			for (uint256 i = 0; i < greenPlayers.length; i++) {
				address player = greenPlayers[i];
				uint256 weight = greenBet[player].mul(100).div(totalGreenPot);

				uint256 totalPotClaimed = totalPottmp.mul(weight).div(100);
				uint256 jackpotClaimed = totalJackpot.mul(weight).div(100);
				uint256 reward = totalPotClaimed + jackpotClaimed;

				totalPot -= totalPotClaimed;
				jackpot -= jackpotClaimed;

				rewards[player] += reward;

				emit PlayerWin(player, reward, 3);
			}

			jackpot = 0;
		} else if (result > 3 && result.mod(2) == 0 && totalRedPot > 0) {
			for (uint256 i = 0; i < redPlayers.length; i++) {
				address player = redPlayers[i];
				uint256 weight = redBet[player].mul(100).div(totalRedPot);
				uint256 reward = totalPottmp.sub(totalGreenPot).mul(weight).div(100);

				if (reward < redBet[player]) {
					uint256 difference = redBet[player].mul(10) - reward.mul(10);
					reward = redBet[player];
					wheelBank -= difference.div(10);
					totalPot += difference.div(10);
				}

				totalPot -= reward;
				rewards[player] += reward;

				emit PlayerWin(player, reward, 1);
			}
		} else if (result > 3 && result.mod(2) != 0 && totalBlackPot > 0) {
			for (uint256 i = 0; i < blackPlayers.length; i++) {
				address player = blackPlayers[i];
				uint256 weight = blackBet[player].mul(100).div(totalBlackPot);
				uint256 reward = totalPottmp.sub(totalGreenPot).mul(weight).div(100);

				if (reward < blackBet[player]) {
					uint256 difference = blackBet[player].mul(10) - reward.mul(10);
					reward = blackBet[player];
					wheelBank -= difference.div(10);
					totalPot += difference.div(10);
				}

				totalPot -= reward;
				rewards[player] += reward;
				emit PlayerWin(player, reward, 2);
			}
		}

		if (totalPot > 0) {
			jackpot += totalPot;
		}
		_resetGame();
	}

	function _resetGame() private returns (bool) {
		for (uint256 i = 0; i < redPlayers.length; i++) {
			redBet[redPlayers[i]] = 0;
		}
		for (uint256 i = 0; i < blackPlayers.length; i++) {
			blackBet[blackPlayers[i]] = 0;
		}
		for (uint256 i = 0; i < greenPlayers.length; i++) {
			greenBet[greenPlayers[i]] = 0;
		}

		delete redPlayers;
		delete blackPlayers;
		delete greenPlayers;

		totalBlackPot = 0;
		totalRedPot = 0;
		totalGreenPot = 0;
		totalPot = 0;

		spin_timestamp = block.timestamp;
	}

	//-------------------------------------------------------------------------
	// GETTERS & SETTERS
	//-------------------------------------------------------------------------

	function getHistoryNumbers() external view returns (uint256[] memory) {
		return winNumbersHistory;
	}

	function getRedBetters() external view returns (address[] memory) {
		return redPlayers;
	}

	function getGreenBetters() external view returns (address[] memory) {
		return greenPlayers;
	}

	function getBlackBetters() external view returns (address[] memory) {
		return blackPlayers;
	}

	function setDelay(uint256 delay) external onlyOwner {
		DELAY_BEFORE_SPIN = delay;
	}

	function setLimit(uint256 limit) external onlyOwner {
		MAX_BEFORE_SPIN = limit;
	}

	function setMinBet(uint256 minBet) external onlyOwner {
		MIN_BET_ALLOWED = minBet;
	}

	function setMAXBet(uint256 maxBet) external onlyOwner {
		MAX_BET_ALLOWED = maxBet;
	}

	function addJackpot(uint256 amount) external nonReentrant onlyOwner {
		jackpot += amount;
		dumplings.safeTransferFrom(msg.sender, address(this), amount.mul(DECIMAL_MULTIPLIER));
	}

	function addWheelBank(uint256 amount) external nonReentrant onlyOwner {
		wheelBank += amount;
		dumplings.safeTransferFrom(msg.sender, address(this), amount.mul(DECIMAL_MULTIPLIER));
	}

	function setRandomGenerator(address randomGenerator) external onlyOwner {
		_randomGenerator = ISafeRandomGenerator(randomGenerator);
	}

	function resetWinHistoryNumbers() external onlyOwner {
		delete winNumbersHistory;
	}

	function setBurnFees(uint256 newFee) external onlyOwner {
		BURN_FEE = newFee;
	}

	//-------------------------------------------------------------------------
	// REWARDS/UTILS FUNCTION
	//-------------------------------------------------------------------------

	function claimRewards() public nonReentrant notContract() returns (bool) {
		require(rewards[msg.sender] > 0);
		uint256 amountClaimed = rewards[msg.sender];
		rewards[msg.sender] = 0;
		dumplings.safeTransfer(msg.sender, amountClaimed.mul(DECIMAL_MULTIPLIER));
		emit ClaimedRewards(msg.sender, amountClaimed);
	}

	function safeTransferToV2(uint256 amount) external nonReentrant onlyOwner {
		dumplings.safeTransfer(msg.sender, amount.mul(DECIMAL_MULTIPLIER));
		wheelBank = 0;
		jackpot = 0;
		_resetGame();
	}
}
