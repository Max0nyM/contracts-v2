// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "./libs/IBEP20.sol";
import "./libs/SafeBEP20.sol";
import "./libs/IDumplingReferral.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./SpaceDumplingToken.sol";

// MasterChef is the master of Dumpling. He can make Dumpling and he is a fair guy.
//
// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance smart contract once DUMP is sufficiently
// distributed and the community can show to govern itself.
//
// Have fun reading it. Hopefully it's bug-free. God bless.
contract MasterChef is Ownable, ReentrancyGuard {
	using SafeMath for uint256;
	using SafeBEP20 for IBEP20;

	// Info of each user.
	struct UserInfo {
		uint256 amount; // How many LP tokens the user has provided.
		uint256 rewardDebt; // Reward debt. See explanation below.
		uint256 rewardLockedUp; // Reward locked up.
		uint256 nextHarvestUntil; // When can the user harvest again.
		//
		// We do some fancy math here. Basically, any point in time, the amount of DUMPs
		// entitled to a user but is pending to be distributed is:
		//
		//   pending reward = (user.amount * pool.accDumplingPerShare) - user.rewardDebt
		//
		// Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
		//   1. The pool's `accDumplingPerShare` (and `lastRewardBlock`) gets updated.
		//   2. User receives the pending reward sent to his/her address.
		//   3. User's `amount` gets updated.
		//   4. User's `rewardDebt` gets updated.
	}

	// Info of each pool.
	struct PoolInfo {
		IBEP20 lpToken; // Address of LP token contract.
		uint256 allocPoint; // How many allocation points assigned to this pool. DUMPs to distribute per block.
		uint256 lastRewardBlock; // Last block number that DUMPs distribution occurs.
		uint256 accDumplingPerShare; // Accumulated DUMPs per share, times 1e12. See below.
		uint16 depositFeeBP; // Deposit fee in basis points
		uint256 harvestInterval; // Harvest interval in seconds
	}

	// The DUMP TOKEN!
	SpaceDumplingToken public dumpling;
	// Dev address.
	address public devAddress;
	// Team address
	address public teamAddress;
	// Dumpler Address
	address public dumplerAddress;
	// Dumpler Mini Address;
	address public dumplerMiniAddress;
	// Is dumplers fee enabled;
	bool public isDumplerFeeEnabled = false;
	// Deposit Fee address
	address public feeAddress;
	// DUMP tokens created per block.
	uint256 public dumplingPerBlock;
	// Bonus muliplier for early dumpling makers.
	uint256 public constant BONUS_MULTIPLIER = 1;
	// Max harvest interval: 14 days.
	uint256 public constant MAXIMUM_HARVEST_INTERVAL = 14 days;

	// Info of each pool.
	PoolInfo[] public poolInfo;
	// Info of each user that stakes LP tokens.
	mapping(uint256 => mapping(address => UserInfo)) public userInfo;
	// Total allocation points. Must be the sum of all allocation points in all pools.
	uint256 public totalAllocPoint = 0;
	// The block number when DUMP mining starts.
	uint256 public startBlock;
	// Total locked up rewards
	uint256 public totalLockedUpRewards;

	// Dumpling referral contract address.
	IDumplingReferral public dumplingReferral;
	// Referral commission rate in basis points.
	uint16 public referralCommissionRate = 100;
	// Max referral commission rate: 10%.
	uint16 public constant MAXIMUM_REFERRAL_COMMISSION_RATE = 1000;

	event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
	event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
	event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
	event EmissionRateUpdated(address indexed caller, uint256 previousAmount, uint256 newAmount);
	event ReferralCommissionPaid(address indexed user, address indexed referrer, uint256 commissionAmount);
	event RewardLockedUp(address indexed user, uint256 indexed pid, uint256 amountLockedUp);

	constructor(
		SpaceDumplingToken _dumpling,
		uint256 _startBlock,
		uint256 _dumplingPerBlock
	) public {
		dumpling = _dumpling;
		startBlock = _startBlock;
		dumplingPerBlock = _dumplingPerBlock;

		devAddress = msg.sender;
		feeAddress = msg.sender;
	}

	function poolLength() external view returns (uint256) {
		return poolInfo.length;
	}

	// Add a new lp to the pool. Can only be called by the owner.
	// XXX DO NOT add the same LP token more than once. Rewards will be messed up if you do.
	function add(
		uint256 _allocPoint,
		IBEP20 _lpToken,
		uint16 _depositFeeBP,
		uint256 _harvestInterval,
		bool _withUpdate
	) public onlyOwner {
		require(_depositFeeBP <= 10000, "add: invalid deposit fee basis points");
		require(_harvestInterval <= MAXIMUM_HARVEST_INTERVAL, "add: invalid harvest interval");
		if (_withUpdate) {
			massUpdatePools();
		}
		uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
		totalAllocPoint = totalAllocPoint.add(_allocPoint);
		poolInfo.push(
			PoolInfo({
				lpToken: _lpToken,
				allocPoint: _allocPoint,
				lastRewardBlock: lastRewardBlock,
				accDumplingPerShare: 0,
				depositFeeBP: _depositFeeBP,
				harvestInterval: _harvestInterval
			})
		);
	}

	// Update the given pool's DUMP allocation point and deposit fee. Can only be called by the owner.
	function set(
		uint256 _pid,
		uint256 _allocPoint,
		uint16 _depositFeeBP,
		uint256 _harvestInterval,
		bool _withUpdate
	) public onlyOwner {
		require(_depositFeeBP <= 10000, "set: invalid deposit fee basis points");
		require(_harvestInterval <= MAXIMUM_HARVEST_INTERVAL, "set: invalid harvest interval");
		if (_withUpdate) {
			massUpdatePools();
		}
		totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
		poolInfo[_pid].allocPoint = _allocPoint;
		poolInfo[_pid].depositFeeBP = _depositFeeBP;
		poolInfo[_pid].harvestInterval = _harvestInterval;
	}

	// Return reward multiplier over the given _from to _to block.
	function getMultiplier(uint256 _from, uint256 _to) public pure returns (uint256) {
		return _to.sub(_from).mul(BONUS_MULTIPLIER);
	}

	// View function to see pending DUMPs on frontend.
	function pendingDumpling(uint256 _pid, address _user) external view returns (uint256) {
		PoolInfo storage pool = poolInfo[_pid];
		UserInfo storage user = userInfo[_pid][_user];
		uint256 accDumplingPerShare = pool.accDumplingPerShare;
		uint256 lpSupply = pool.lpToken.balanceOf(address(this));
		if (block.number > pool.lastRewardBlock && lpSupply != 0) {
			uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
			uint256 dumplingReward = multiplier.mul(dumplingPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
			accDumplingPerShare = accDumplingPerShare.add(dumplingReward.mul(1e12).div(lpSupply));
		}
		uint256 pending = user.amount.mul(accDumplingPerShare).div(1e12).sub(user.rewardDebt);
		return pending.add(user.rewardLockedUp);
	}

	// View function to see if user can harvest DUMPs.
	function canHarvest(uint256 _pid, address _user) public view returns (bool) {
		UserInfo storage user = userInfo[_pid][_user];
		return block.timestamp >= user.nextHarvestUntil;
	}

	// Update reward variables for all pools. Be careful of gas spending!
	function massUpdatePools() public {
		uint256 length = poolInfo.length;
		for (uint256 pid = 0; pid < length; ++pid) {
			updatePool(pid);
		}
	}

	// Update reward variables of the given pool to be up-to-date.
	function updatePool(uint256 _pid) public {
		PoolInfo storage pool = poolInfo[_pid];
		if (block.number <= pool.lastRewardBlock) {
			return;
		}
		uint256 lpSupply = pool.lpToken.balanceOf(address(this));
		if (lpSupply == 0 || pool.allocPoint == 0) {
			pool.lastRewardBlock = block.number;
			return;
		}
		uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
		uint256 dumplingReward = multiplier.mul(dumplingPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
		if (isDumplerFeeEnabled) {
			uint256 totalFee = dumplingReward.div(10);
			uint256 dumplerFee = totalFee.div(10); //1% of the total dev fee
			uint256 dumplerMiniFee = totalFee.div(20); //0.5% of the total dev fee
			uint256 devFee = totalFee.sub(dumplerFee).sub(dumplerMiniFee); //remaining 8.5% to the dev address
			dumpling.mint(dumplerAddress, dumplerFee);
			dumpling.mint(dumplerMiniAddress, dumplerMiniFee);
			dumpling.mint(devAddress, devFee);
		} else {
			dumpling.mint(devAddress, dumplingReward.div(10));
		}
		dumpling.mint(address(this), dumplingReward);
		pool.accDumplingPerShare = pool.accDumplingPerShare.add(dumplingReward.mul(1e12).div(lpSupply));
		pool.lastRewardBlock = block.number;
	}

	// Deposit LP tokens to MasterChef for DUMP allocation.
	function deposit(
		uint256 _pid,
		uint256 _amount,
		address _referrer
	) public nonReentrant {
		PoolInfo storage pool = poolInfo[_pid];
		UserInfo storage user = userInfo[_pid][msg.sender];
		updatePool(_pid);
		if (_amount > 0 && address(dumplingReferral) != address(0) && _referrer != address(0) && _referrer != msg.sender) {
			dumplingReferral.recordReferral(msg.sender, _referrer);
		}
		payOrLockupPendingDumpling(_pid);
		if (_amount > 0) {
			pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
			if (address(pool.lpToken) == address(dumpling)) {
				uint256 transferTax = _amount.mul(dumpling.transferTaxRate()).div(10000);
				_amount = _amount.sub(transferTax);
			}
			if (pool.depositFeeBP > 0) {
				uint256 depositFee = _amount.mul(pool.depositFeeBP).div(10000);
				uint256 teamFee = depositFee.div(20); //5% for the team
				pool.lpToken.safeTransfer(feeAddress, depositFee - teamFee);
				pool.lpToken.safeTransfer(teamAddress, teamFee);
				user.amount = user.amount.add(_amount).sub(depositFee);
			} else {
				user.amount = user.amount.add(_amount);
			}
		}
		user.rewardDebt = user.amount.mul(pool.accDumplingPerShare).div(1e12);
		emit Deposit(msg.sender, _pid, _amount);
	}

	// Withdraw LP tokens from MasterChef.
	function withdraw(uint256 _pid, uint256 _amount) public nonReentrant {
		PoolInfo storage pool = poolInfo[_pid];
		UserInfo storage user = userInfo[_pid][msg.sender];
		require(user.amount >= _amount, "withdraw: not good");
		updatePool(_pid);
		payOrLockupPendingDumpling(_pid);
		if (_amount > 0) {
			user.amount = user.amount.sub(_amount);
			pool.lpToken.safeTransfer(address(msg.sender), _amount);
		}
		user.rewardDebt = user.amount.mul(pool.accDumplingPerShare).div(1e12);
		emit Withdraw(msg.sender, _pid, _amount);
	}

	// Withdraw without caring about rewards. EMERGENCY ONLY.
	function emergencyWithdraw(uint256 _pid) public nonReentrant {
		PoolInfo storage pool = poolInfo[_pid];
		UserInfo storage user = userInfo[_pid][msg.sender];
		uint256 amount = user.amount;
		user.amount = 0;
		user.rewardDebt = 0;
		user.rewardLockedUp = 0;
		user.nextHarvestUntil = 0;
		pool.lpToken.safeTransfer(address(msg.sender), amount);
		emit EmergencyWithdraw(msg.sender, _pid, amount);
	}

	// Pay or lockup pending DUMPs.
	function payOrLockupPendingDumpling(uint256 _pid) internal {
		PoolInfo storage pool = poolInfo[_pid];
		UserInfo storage user = userInfo[_pid][msg.sender];

		if (user.nextHarvestUntil == 0) {
			user.nextHarvestUntil = block.timestamp.add(pool.harvestInterval);
		}

		uint256 pending = user.amount.mul(pool.accDumplingPerShare).div(1e12).sub(user.rewardDebt);
		if (canHarvest(_pid, msg.sender)) {
			if (pending > 0 || user.rewardLockedUp > 0) {
				uint256 totalRewards = pending.add(user.rewardLockedUp);

				// reset lockup
				totalLockedUpRewards = totalLockedUpRewards.sub(user.rewardLockedUp);
				user.rewardLockedUp = 0;
				user.nextHarvestUntil = block.timestamp.add(pool.harvestInterval);

				// send rewards
				safeDumplingTransfer(msg.sender, totalRewards);
				payReferralCommission(msg.sender, totalRewards);
			}
		} else if (pending > 0) {
			user.rewardLockedUp = user.rewardLockedUp.add(pending);
			totalLockedUpRewards = totalLockedUpRewards.add(pending);
			emit RewardLockedUp(msg.sender, _pid, pending);
		}
	}

	// Safe dumpling transfer function, just in case if rounding error causes pool to not have enough DUMPs.
	function safeDumplingTransfer(address _to, uint256 _amount) internal {
		uint256 dumplingBal = dumpling.balanceOf(address(this));
		if (_amount > dumplingBal) {
			dumpling.transfer(_to, dumplingBal);
		} else {
			dumpling.transfer(_to, _amount);
		}
	}

	// Update dev address by the previous dev.
	function setDevAddress(address _devAddress) public {
		require(msg.sender == feeAddress, "setDevAddress: FORBIDDEN");
		require(_devAddress != address(0), "setDevAddress: ZERO");
		devAddress = _devAddress;
	}

	function setFeeAddress(address _feeAddress) public {
		require(msg.sender == feeAddress, "setFeeAddress: FORBIDDEN");
		require(_feeAddress != address(0), "setFeeAddress: ZERO");
		feeAddress = _feeAddress;
	}

	function setTeamAddress(address _teamAddress) public {
		require(msg.sender == feeAddress, "setTeamAddress: FORBIDDEN");
		require(_teamAddress != address(0), "setTeamAddress: ZERO");
		teamAddress = _teamAddress;
	}

	function setDumplerAddress(address _dumplerAddress) public {
		require(msg.sender == feeAddress, "setDumplerAddress: FORBIDDEN");
		require(_dumplerAddress != address(0), "setDumplerAddress: ZERO");
		dumplerAddress = _dumplerAddress;
	}

	function setDumplerMiniAddress(address _dumplerMiniAddress) public {
		require(msg.sender == feeAddress, "setDumplerMiniAddress: FORBIDDEN");
		require(_dumplerMiniAddress != address(0), "setDumplerMiniAddress: ZERO");
		dumplerMiniAddress = _dumplerMiniAddress;
	}

	// Pancake has to add hidden dummy pools in order to alter the emission, here we make it simple and transparent to all.
	function updateEmissionRate(uint256 _dumplingPerBlock) public onlyOwner {
		massUpdatePools();
		emit EmissionRateUpdated(msg.sender, dumplingPerBlock, _dumplingPerBlock);
		dumplingPerBlock = _dumplingPerBlock;
	}

	// Update the dumpling referral contract address by the owner
	function setDumplingReferral(IDumplingReferral _dumplingReferral) public onlyOwner {
		dumplingReferral = _dumplingReferral;
	}

	// Update referral commission rate by the owner
	function setReferralCommissionRate(uint16 _referralCommissionRate) public onlyOwner {
		require(
			_referralCommissionRate <= MAXIMUM_REFERRAL_COMMISSION_RATE,
			"setReferralCommissionRate: invalid referral commission rate basis points"
		);
		referralCommissionRate = _referralCommissionRate;
	}

	// Pay referral commission to the referrer who referred this user.
	function payReferralCommission(address _user, uint256 _pending) internal {
		if (address(dumplingReferral) != address(0) && referralCommissionRate > 0) {
			address referrer = dumplingReferral.getReferrer(_user);
			uint256 commissionAmount = _pending.mul(referralCommissionRate).div(10000);

			if (referrer != address(0) && commissionAmount > 0) {
				dumpling.mint(referrer, commissionAmount);
				dumplingReferral.recordReferralCommission(referrer, commissionAmount);
				emit ReferralCommissionPaid(_user, referrer, commissionAmount);
			}
		}
	}

	function setStartBlock(uint256 _startBlock) external {
		require(block.number < startBlock, "It's too late to postpone mining. It has already started");
		startBlock = _startBlock;
	}

	function setIsDumplerFeeEnabled(bool _isDumplerFeeEnabled) external onlyOwner {
		isDumplerFeeEnabled = _isDumplerFeeEnabled;
	}
}
