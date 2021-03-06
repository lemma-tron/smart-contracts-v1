// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

import "@pancakeswap/pancake-swap-lib/contracts/math/SafeMath.sol";
import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/IBEP20.sol";
import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/SafeBEP20.sol";
import "@pancakeswap/pancake-swap-lib/contracts/access/Ownable.sol";

import "./LemaToken.sol";

// Master Contract of Lemmatron
contract LemaChef is Ownable {
    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;

    // Info of each user.
    struct UserInfo {
        uint256 amount; // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        uint256 lastStakedDate; // last staked timestamp
        uint256 lastDeposited; // last deposited timestamp
        uint256 lastDepositedAmount; // last deposited amount
        //
        // We do some fancy math here. Basically, any point in time, the amount of LEMAs
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accLEMAPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accLEMAPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IBEP20 lpToken; // Address of LP token contract.
        uint256 allocPoint; // How many allocation points assigned to this pool. LEMAs to distribute per block.
        uint256 lastRewardBlock; // Last block number that LEMAs distribution occurs.
        uint256 accLEMAPerShare; // Accumulated LEMAs per share, times 1e12. See below.
    }

    string public name = "Lema Chef";

    LemaToken public lemaToken;

    // Lema tokens created per block.
    uint256 public lemaPerBlock;
    // Bonus muliplier for early Lema makers.
    uint256 public bonusMultiplier = 1;

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block number when mining starts.
    uint256 public startBlock;

    // penalty fee when withdrawing reward within 4 weeks of last deposit and after 4 weeks
    uint256 public penaltyFeeRate1 = 20; // withdraw penalty fee if last deposited is < 4 weeks
    uint256 public penaltyFeeRate2 = 15; // fee if last deposited is > 4 weeks (always implemented)
    // Penalties period
    uint256 public penaltyPeriod = 4 weeks;
    // Treasury address
    address public treasury;

    // keep track of validators
    address[] public validators;
    mapping(address => bool) public validatorExists;
    uint256 public numberOfValidators = 0;
    uint256 public numberOfValidatorAllowed = 10;
    uint256 public validatorMinStake = 200;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(
        address indexed user,
        uint256 indexed pid,
        uint256 amount
    );

    constructor(
        LemaToken _lemaToken,
        address _treasury,
        uint256 _lemaPerBlock,
        uint256 _startBlock
    ) public {
        lemaToken = _lemaToken;
        treasury = _treasury;
        lemaPerBlock = _lemaPerBlock;
        startBlock = _startBlock;

        // staking pool
        poolInfo.push(
            PoolInfo({
                lpToken: _lemaToken,
                allocPoint: 1000,
                lastRewardBlock: startBlock,
                accLEMAPerShare: 0
            })
        );
        totalAllocPoint = 1000;
    }

    function updateMultiplier(uint256 multiplierNumber) public onlyOwner {
        require(multiplierNumber > 0, "Multipler is too less");
        bonusMultiplier = multiplierNumber;
        //determining the Lema tokens allocated to each farm
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
        //Determine how many pools we have
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to)
        internal
        view
        returns (uint256)
    {
        return _to.sub(_from).mul(bonusMultiplier);
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) internal {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        if (block.number <= startBlock) {
            return;
        }
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (lpSupply == 0 || pool.allocPoint == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 lemaReward = multiplier
            .mul(lemaPerBlock)
            .mul(pool.allocPoint)
            .div(totalAllocPoint);

        pool.accLEMAPerShare = pool.accLEMAPerShare.add(
            lemaReward.mul(1e12).div(lpSupply)
        );
        pool.lastRewardBlock = block.number;
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() internal {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Add a new lp to the pool. Can only be called by the owner.
    // XXX DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    function add(
        uint256 _allocPoint,
        IBEP20 _lpToken,
        bool _withUpdate
    ) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlock = block.number > startBlock
            ? block.number
            : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(
            PoolInfo({
                lpToken: _lpToken,
                allocPoint: _allocPoint,
                lastRewardBlock: lastRewardBlock,
                accLEMAPerShare: 0
            })
        );

        updateStakingPool();
    }

    // Update the given pool's Lema allocation point. Can only be called by the owner.
    function set(
        uint256 _pid,
        uint256 _allocPoint,
        bool _withUpdate
    ) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 prevAllocPoint = poolInfo[_pid].allocPoint;
        poolInfo[_pid].allocPoint = _allocPoint;
        if (prevAllocPoint != _allocPoint) {
            totalAllocPoint = totalAllocPoint.sub(prevAllocPoint).add(
                _allocPoint
            );
            updateStakingPool();
        }
    }

    function updateStakingPool() internal {
        uint256 length = poolInfo.length;
        uint256 points = 0;
        for (uint256 pid = 1; pid < length; ++pid) {
            points = points.add(poolInfo[pid].allocPoint);
        }
        if (points != 0) {
            points = points.div(3);
            totalAllocPoint = totalAllocPoint.sub(poolInfo[0].allocPoint).add(
                points
            );
            poolInfo[0].allocPoint = points; //setting first pool allocation points to total pool allocation/3
        }
    }

    // View function to see pending Rewards.
    function pendingReward(uint256 _pid, address _user)
        external
        view
        returns (uint256)
    {
        PoolInfo storage pool = poolInfo[_pid]; //getting the specific pool with it id
        UserInfo storage user = userInfo[_pid][_user]; //getting user belongs to that pool
        uint256 accLEMAPerShare = pool.accLEMAPerShare; //getting the accumulated lema per share in that pool
        uint256 lpSupply = pool.lpToken.balanceOf(address(this)); //how many lptokens are there in that pool
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getMultiplier(
                pool.lastRewardBlock,
                block.number
            );
            uint256 lemaReward = multiplier
                .mul(lemaPerBlock)
                .mul(pool.allocPoint)
                .div(totalAllocPoint); //calculating the Lema reward
            accLEMAPerShare = accLEMAPerShare.add(
                lemaReward.mul(1e12).div(lpSupply)
            ); //accumulated Lema per each share
        }
        return user.amount.mul(accLEMAPerShare).div(1e12).sub(user.rewardDebt); //get the pending LEMAs which are rewarded to us to harvest
    }

    // Safe Lema transfer function, just in case if rounding error causes pool to not have enough LEMAs.
    function safeLEMATransfer(address _to, uint256 _amount) internal {
        uint256 lemaBal = lemaToken.balanceOf(address(this));
        if (_amount > lemaBal) {
            lemaToken.transfer(_to, lemaBal);
        } else {
            lemaToken.transfer(_to, _amount);
        }
    }

    // calculates last deposit timestamp for fair withdraw fee
    function getLastDepositTimestamp(uint256 lastDepositedTimestamp, uint256 lastDepositedAmount, uint256 currentAmount) internal view returns (uint256) {
        if(lastDepositedTimestamp <= 0) {
            return block.timestamp;
        } else {
            uint256 currentTimestamp = block.timestamp;
            uint256 multiplier = currentAmount.div((lastDepositedAmount.add(currentAmount)));
            return currentTimestamp.sub(lastDepositedTimestamp).mul(multiplier).add(lastDepositedTimestamp);
        }
    }

    // to fetch staked amount in given pool of given user
    // this can be used to know if user has staked or not
    function getStakedAmountInPool(uint256 _pid, address _user) public view returns (uint256) {
        UserInfo memory user = userInfo[_pid][_user];
        return user.amount;
    }

    // to fetch last staked date in given pool of given user
    function getLastStakedDateInPool(uint256 _pid, address _user) public view returns (uint256) {
        UserInfo memory user = userInfo[_pid][_user];
        return user.lastStakedDate;
    }

    function transferRewardWithWithdrawFee(uint256 userLastDeposited, uint256 pending) internal {
        uint256 withdrawFee = 0;
        uint256 currentTimestamp = block.timestamp;
        if (currentTimestamp < userLastDeposited.add(penaltyPeriod)) {
            withdrawFee = getWithdrawFee(pending, penaltyFeeRate1);
        } else {
            withdrawFee = getWithdrawFee(pending, penaltyFeeRate2);
        }

        uint256 rewardAmount = pending.sub(withdrawFee);

        require(pending == withdrawFee + rewardAmount, "Lema::transfer: withdrawfee invalid");

        safeLEMATransfer(treasury, withdrawFee);
        safeLEMATransfer(msg.sender, rewardAmount);
    }

    // Deposit LP tokens to LemaChef for Lema allocation.
    function deposit(uint256 _pid, uint256 _amount) public {
        require(_pid != 0, "deposit Lema by staking");
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        if (user.amount > 0) {
            uint256 pending = user
                .amount
                .mul(pool.accLEMAPerShare)
                .div(1e12)
                .sub(user.rewardDebt);
            if (pending > 0) {
                transferRewardWithWithdrawFee(user.lastDeposited, pending);
            }
        }
        if (_amount > 0) {
            pool.lpToken.safeTransferFrom(
                address(msg.sender),
                address(this),
                _amount
            );
            user.amount = user.amount.add(_amount);
            user.lastStakedDate = getLastDepositTimestamp(user.lastDeposited, user.lastDepositedAmount, _amount);
            user.lastDeposited = block.timestamp;
            user.lastDepositedAmount = _amount;
        }

        user.rewardDebt = user.amount.mul(pool.accLEMAPerShare).div(1e12);
        emit Deposit(msg.sender, _pid, _amount);
    }

    // Withdraw LP tokens from LemaChef.
    function withdraw(uint256 _pid, uint256 _amount) public {
        require(_pid != 0, "withdraw Lema by unstaking");
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid);
        uint256 pending = user.amount.mul(pool.accLEMAPerShare).div(1e12).sub(
            user.rewardDebt
        );
        if (pending > 0) {
            transferRewardWithWithdrawFee(user.lastDeposited, pending);
        }
        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.lpToken.safeTransfer(
                address(msg.sender),
                _amount
            );
        }
        user.rewardDebt = user.amount.mul(pool.accLEMAPerShare).div(1e12);
        emit Withdraw(msg.sender, _pid, _amount);
    }

    // Get Withdraw fee
    function getWithdrawFee(uint256 _amount, uint256 _penaltyFeeRate) internal pure returns (uint256) {
        return _amount.mul(_penaltyFeeRate).div(100);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        pool.lpToken.safeTransfer(address(msg.sender), amount);
        emit EmergencyWithdraw(msg.sender, _pid, amount);
    }

    // Update treasury address by the previous treasury address holder.
    function updateTreasuryAddress(address _treasury) public {
        require(msg.sender == treasury, "Updating Treasury Forbidden !");
        treasury = _treasury;
    }

    //Update start reward block
    function updateStartBlock(uint256 _startBlock) public onlyOwner {
        startBlock = _startBlock;
    }

    // update lema per block
    function updateLemaPerBlock(uint256 _lemaPerBlock) public onlyOwner {
        lemaPerBlock = _lemaPerBlock;
    }

    // update validator min stake
    function updateValidatorMinStake(uint256 _validatorMinStake) public onlyOwner {
        validatorMinStake = _validatorMinStake;
    }

    // get list of validators
    function listOfValidators() public view returns (address[] memory) {
        address[] memory validValidators = new address[](numberOfValidators);
        uint256 counter = 0;
        for (uint256 i = 0; i < validators.length; i++) {
            address user = validators[i];
            if(validatorExists[user]) {
                validValidators[counter++] = user;
            }
        }
        return validValidators;
    }

    // apply for validator
    function applyForValidator(address _user) public {
        require(numberOfValidators <= numberOfValidatorAllowed, "Validators allowed exceeded");
        uint256 lemaStaked = getStakedAmountInPool(0, _user);
        require(lemaStaked >= validatorMinStake, "Stake not enough to become validator");
        validatorExists[_user] = true;
        validators.push(_user);
        numberOfValidators += 1;
    }

    // remove for validator
    function removeFromValidator(address _user) public {
        require(validatorExists[_user], "Validator does not exist");
        validatorExists[_user] = false;
        numberOfValidators -= 1;
    }

    // update numberOfValidatorAllowed
    function updateNumberOfValidatorAllowed(uint256 _numberOfValidatorAllowed) public onlyOwner {
        numberOfValidatorAllowed = _numberOfValidatorAllowed;
    }
 
    // Stake Lema tokens to LemaChef
    function enterStaking(uint256 _amount) public {
        PoolInfo storage pool = poolInfo[0];
        UserInfo storage user = userInfo[0][msg.sender];
        updatePool(0);
        if (user.amount > 0) {
            uint256 pending = user
                .amount
                .mul(pool.accLEMAPerShare)
                .div(1e12)
                .sub(user.rewardDebt);
            if (pending > 0) {
                transferRewardWithWithdrawFee(user.lastDeposited, pending);
            }
        }
        if (_amount > 0) {
            pool.lpToken.safeTransferFrom(
                address(msg.sender),
                address(this),
                _amount
            );
            user.amount = user.amount.add(_amount);
            user.lastStakedDate = getLastDepositTimestamp(user.lastDeposited, user.lastDepositedAmount, _amount);
            user.lastDeposited = block.timestamp;
            user.lastDepositedAmount = _amount;

        }
        user.rewardDebt = user.amount.mul(pool.accLEMAPerShare).div(1e12);
        emit Deposit(msg.sender, 0, _amount);
    }

    // Withdraw Lema tokens from STAKING.
    function leaveStaking(uint256 _amount) public {
        PoolInfo storage pool = poolInfo[0];
        UserInfo storage user = userInfo[0][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(0);
        uint256 pending = user.amount.mul(pool.accLEMAPerShare).div(1e12).sub(
            user.rewardDebt
        );
        if (pending > 0) {
            transferRewardWithWithdrawFee(user.lastDeposited, pending);
        }
        if (_amount > 0) {

            // check for validator
            if(_amount > validatorMinStake) {
                removeFromValidator(msg.sender);
            }

            user.amount = user.amount.sub(_amount);
            pool.lpToken.safeTransfer(
                address(msg.sender),
                _amount
            );
        }
        user.rewardDebt = user.amount.mul(pool.accLEMAPerShare).div(1e12);
        emit Withdraw(msg.sender, 0, _amount);
    }
}
