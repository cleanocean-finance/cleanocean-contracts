// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "./libs/IBEP20.sol";
import "./libs/SafeBEP20.sol";
import "./libs/IFSwapReferral.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./FSwapToken.sol";

// MasterChef is the master of FSwap. He can make FSwap and he is a fair guy.
//
// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance smart contract once FSwap is sufficiently
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
        // We do some fancy math here. Basically, any point in time, the amount of FSwaps
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accFSwapPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accFSwapPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IBEP20 lpToken; // Address of LP token contract.
        uint256 allocPoint; // How many allocation points assigned to this pool. FSwaps to distribute per block.
        uint256 lastRewardBlock; // Last block number that FSwaps distribution occurs.
        uint256 accFSwapPerShare; // Accumulated FSwaps per share, times 1e12. See below.
        uint16 depositFeeBP; // Deposit fee in basis points
        uint256 harvestInterval; // Harvest interval in seconds
    }

    // The FSWAP TOKEN!
    FSwapToken public fswap;
    // Dev address.
    address public devAddress;
    // Deposit Fee address
    address public feeAddress;
    // FSWAP tokens created per block.
    uint256 public fswapPerBlock;
    // Bonus muliplier for early fswap makers.
    uint256 public constant BONUS_MULTIPLIER = 1;
    // Max harvest interval: 14 days.
    uint256 public constant MAXIMUM_HARVEST_INTERVAL = 14 days;

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    // Token addresses that has tax rate
    mapping(address => uint16) private _taxableTokens;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block number when FSWAP mining starts.
    uint256 public startBlock;
    // Total locked up rewards
    uint256 public totalLockedUpRewards;

    // FSWAO referral contract address.
    IFSwapReferral public fswapReferral;
    // Referral commission rate in basis points.
    uint16 public referralCommissionRate = 0;
    // Max referral commission rate: 10%.
    uint16 public constant MAXIMUM_REFERRAL_COMMISSION_RATE = 1000;
    // Max deposit fee: 10%
    uint16 public constant MAXIMUM_DEPOSIT_FEE = 1000;
    // Max tax rate of deflationary tokens
    uint16 public constant MAXIMUM_TAX_RATE = 2000;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(
        address indexed user,
        uint256 indexed pid,
        uint256 amount
    );
    event EmissionRateUpdated(
        address indexed caller,
        uint256 previousAmount,
        uint256 newAmount
    );
    event ReferralCommissionPaid(
        address indexed user,
        address indexed referrer,
        uint256 commissionAmount
    );
    event RewardLockedUp(
        address indexed user,
        uint256 indexed pid,
        uint256 amountLockedUp
    );

    constructor(
        FSwapToken _fswap,
        uint256 _startBlock,
        uint256 _fswapPerBlock
    ) public {
        fswap = _fswap;
        startBlock = _startBlock;
        fswapPerBlock = _fswapPerBlock;

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
        require(
            _depositFeeBP <= MAXIMUM_DEPOSIT_FEE,
            "add: invalid deposit fee basis points"
        );
        require(
            _harvestInterval <= MAXIMUM_HARVEST_INTERVAL,
            "add: invalid harvest interval"
        );
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
                accFSwapPerShare: 0,
                depositFeeBP: _depositFeeBP,
                harvestInterval: _harvestInterval
            })
        );
    }

    // Update the given pool's FSWAP allocation point and deposit fee. Can only be called by the owner.
    function set(
        uint256 _pid,
        uint256 _allocPoint,
        uint16 _depositFeeBP,
        uint256 _harvestInterval,
        bool _withUpdate
    ) public onlyOwner {
        require(
            _depositFeeBP <= MAXIMUM_DEPOSIT_FEE,
            "set: invalid deposit fee basis points"
        );
        require(
            _harvestInterval <= MAXIMUM_HARVEST_INTERVAL,
            "set: invalid harvest interval"
        );
        if (_withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(
            _allocPoint
        );
        poolInfo[_pid].allocPoint = _allocPoint;
        poolInfo[_pid].depositFeeBP = _depositFeeBP;
        poolInfo[_pid].harvestInterval = _harvestInterval;
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to)
        public
        pure
        returns (uint256)
    {
        return _to.sub(_from).mul(BONUS_MULTIPLIER);
    }

    // View function to see pending FSwaps on frontend.
    function pendingFSwap(uint256 _pid, address _user)
        external
        view
        returns (uint256)
    {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accFSwapPerShare = pool.accFSwapPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getMultiplier(
                pool.lastRewardBlock,
                block.number
            );
            uint256 fswapReward = multiplier
            .mul(fswapPerBlock)
            .mul(pool.allocPoint)
            .div(totalAllocPoint);
            accFSwapPerShare = accFSwapPerShare.add(
                fswapReward.mul(1e12).div(lpSupply)
            );
        }
        uint256 pending = user.amount.mul(accFSwapPerShare).div(1e12).sub(
            user.rewardDebt
        );
        return pending.add(user.rewardLockedUp);
    }

    // View function to see if user can harvest FSwaps.
    function canHarvest(uint256 _pid, address _user)
        public
        view
        returns (bool)
    {
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
        uint256 fswapReward = multiplier
        .mul(fswapPerBlock)
        .mul(pool.allocPoint)
        .div(totalAllocPoint);
        fswap.mint(devAddress, fswapReward.div(10));
        fswap.mint(address(this), fswapReward);
        pool.accFSwapPerShare = pool.accFSwapPerShare.add(
            fswapReward.mul(1e12).div(lpSupply)
        );
        pool.lastRewardBlock = block.number;
    }

    // Deposit LP tokens to MasterChef for FSWAP allocation.
    function deposit(
        uint256 _pid,
        uint256 _amount,
        address _referrer
    ) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        if (
            _amount > 0 &&
            address(fswapReferral) != address(0) &&
            _referrer != address(0) &&
            _referrer != msg.sender
        ) {
            fswapReferral.recordReferral(msg.sender, _referrer);
        }
        payOrLockupPendingFSwap(_pid);
        if (_amount > 0) {
            pool.lpToken.safeTransferFrom(
                address(msg.sender),
                address(this),
                _amount
            );
            if (address(pool.lpToken) == address(fswap)) {
                uint256 transferTax = _amount.mul(fswap.transferTaxRate()).div(
                    10000
                );
                _amount = _amount.sub(transferTax);
            } else if (tokenTaxRate(address(pool.lpToken)) > 0) {
                // For other non-governance defitionary tokens
                uint256 transferTax = _amount
                .mul(tokenTaxRate(address(pool.lpToken)))
                .div(10000);
                _amount = _amount.sub(transferTax);
            }

            if (pool.depositFeeBP > 0) {
                uint256 depositFee = _amount.mul(pool.depositFeeBP).div(10000);
                pool.lpToken.safeTransfer(feeAddress, depositFee);
                user.amount = user.amount.add(_amount).sub(depositFee);
            } else {
                user.amount = user.amount.add(_amount);
            }
        }
        user.rewardDebt = user.amount.mul(pool.accFSwapPerShare).div(1e12);
        emit Deposit(msg.sender, _pid, _amount);
    }

    // Withdraw LP tokens from MasterChef.
    function withdraw(uint256 _pid, uint256 _amount) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid);
        payOrLockupPendingFSwap(_pid);
        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.lpToken.safeTransfer(address(msg.sender), _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accFSwapPerShare).div(1e12);
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

    // Pay or lockup pending FSwaps.
    function payOrLockupPendingFSwap(uint256 _pid) internal {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        if (user.nextHarvestUntil == 0) {
            user.nextHarvestUntil = block.timestamp.add(pool.harvestInterval);
        }

        uint256 pending = user.amount.mul(pool.accFSwapPerShare).div(1e12).sub(
            user.rewardDebt
        );
        if (canHarvest(_pid, msg.sender)) {
            if (pending > 0 || user.rewardLockedUp > 0) {
                uint256 totalRewards = pending.add(user.rewardLockedUp);

                // reset lockup
                totalLockedUpRewards = totalLockedUpRewards.sub(
                    user.rewardLockedUp
                );
                user.rewardLockedUp = 0;
                user.nextHarvestUntil = block.timestamp.add(
                    pool.harvestInterval
                );

                // send rewards
                safeFSwapTransfer(msg.sender, totalRewards);
                payReferralCommission(msg.sender, totalRewards);
            }
        } else if (pending > 0) {
            user.rewardLockedUp = user.rewardLockedUp.add(pending);
            totalLockedUpRewards = totalLockedUpRewards.add(pending);
            emit RewardLockedUp(msg.sender, _pid, pending);
        }
    }

    // Safe fswap transfer function, just in case if rounding error causes pool to not have enough FSwaps.
    function safeFSwapTransfer(address _to, uint256 _amount) internal {
        uint256 fswapBal = fswap.balanceOf(address(this));
        if (_amount > fswapBal) {
            fswap.transfer(_to, fswapBal);
        } else {
            fswap.transfer(_to, _amount);
        }
    }

    // Update dev address by the previous dev.
    function setDevAddress(address _devAddress) public {
        require(msg.sender == devAddress, "setDevAddress: FORBIDDEN");
        require(_devAddress != address(0), "setDevAddress: ZERO");
        devAddress = _devAddress;
    }

    function setFeeAddress(address _feeAddress) public {
        require(msg.sender == feeAddress, "setFeeAddress: FORBIDDEN");
        require(_feeAddress != address(0), "setFeeAddress: ZERO");
        feeAddress = _feeAddress;
    }

    /**
     * @dev Returns the tax rate of the token address.
     */
    function tokenTaxRate(address _address) public view returns (uint16) {
        return _taxableTokens[_address];
    }

    /**
     * @dev Set tax rate of token.
     * Do not forget to add the tax rate for the defitionary tokens
     * Can only be called by the owner.
     */
    function setTokenTaxRate(address _address, uint16 _taxRate)
        public
        onlyOwner
    {
        require(_taxRate <= MAXIMUM_TAX_RATE, "setTokenTaxRate:: too much tax rate for the token");
        _taxableTokens[_address] = _taxRate;
    }

    // Pancake has to add hidden dummy pools in order to alter the emission, here we make it simple and transparent to all.
    function updateEmissionRate(uint256 _fswapPerBlock) public onlyOwner {
        massUpdatePools();
        emit EmissionRateUpdated(msg.sender, fswapPerBlock, _fswapPerBlock);
        fswapPerBlock = _fswapPerBlock;
    }

    // Update the fswap referral contract address by the owner
    function setFSwapReferral(IFSwapReferral _fswapReferral) public onlyOwner {
        fswapReferral = _fswapReferral;
    }

    // Update referral commission rate by the owner
    function setReferralCommissionRate(uint16 _referralCommissionRate)
        public
        onlyOwner
    {
        require(
            _referralCommissionRate <= MAXIMUM_REFERRAL_COMMISSION_RATE,
            "setReferralCommissionRate: invalid referral commission rate basis points"
        );
        referralCommissionRate = _referralCommissionRate;
    }

    // Pay referral commission to the referrer who referred this user.
    function payReferralCommission(address _user, uint256 _pending) internal {
        if (
            address(fswapReferral) != address(0) && referralCommissionRate > 0
        ) {
            address referrer = fswapReferral.getReferrer(_user);
            uint256 commissionAmount = _pending.mul(referralCommissionRate).div(
                10000
            );

            if (referrer != address(0) && commissionAmount > 0) {
                fswap.mint(referrer, commissionAmount);
                fswapReferral.recordReferralCommission(
                    referrer,
                    commissionAmount
                );
                emit ReferralCommissionPaid(_user, referrer, commissionAmount);
            }
        }
    }
}
