// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

import "../BorrowerOperations.sol";
import "../TroveManager.sol";
import "../StabilityPool.sol";
import "../HintHelpers.sol";
import "../LQTY/LQTYStaking.sol";

contract E2E {

    using SafeMath for uint;
    uint256 internal mintedLUSD;

    address internal bo = 0xbe0037eAf2d64fe5529BCa93c18C9702D3930376;
    address internal hh = 0x07f96Aa816C1F244CbC6ef114bB2b023Ba54a2EB;
    address internal ap = address(BorrowerOperations(bo).activePool());
    address internal dp = address(BorrowerOperations(bo).defaultPool());
    address internal sp = address(TroveManager(address(BorrowerOperations(bo).troveManager())).stabilityPool());
    address internal st = address(TroveManager(address(BorrowerOperations(bo).troveManager())).sortedTroves());
    address internal t =  address(BorrowerOperations(bo).lusdToken());
    address internal zAddr = address(0);

    function checkInvariants() internal view {
        assert(BorrowerOperations(bo).troveManager().getTroveOwnersCount() >= 1 && ISortedTroves(st).getSize() >= 1);
        assert(ap.balance == IPool(ap).getETH());
        assert(dp.balance == IPool(dp).getETH());
        assert(sp.balance == IPool(sp).getETH());
        assert(t.balance == 0);
        assert(st.balance == 0);
    }

    function checkMoreInvariants() public {
        uint totalSupply = ILUSDToken(t).totalSupply();
        uint gasPoolBalance = ILUSDToken(t).balanceOf(BorrowerOperations(bo).gasPoolAddress());

        uint activePoolBalance = IPool(ap).getLUSDDebt();
        uint defaultPoolBalance = IPool(dp).getLUSDDebt();
        uint totalStakes = TroveManager(address(BorrowerOperations(bo).troveManager())).totalStakes();

        // totalStakes > 0
        assert(totalStakes > 0);
        // totalStakes does not exceed activePool + defaultPool
        assert(totalStakes <= activePoolBalance.add(defaultPoolBalance));

        assert(ILUSDToken(t).balanceOf(address(this)) <= activePoolBalance.add(defaultPoolBalance));
        assert(totalSupply == activePoolBalance.add(defaultPoolBalance));

        uint stabilityPoolBalance = IStabilityPool(sp).getTotalLUSDDeposits();

        address currentTrove = ISortedTroves(st).getFirst();
        address nextTrove; 

        uint trovesBalance = 0;
        while (currentTrove != address(0)) {
            trovesBalance = trovesBalance.add(ILUSDToken(t).balanceOf(address(currentTrove)));
            currentTrove = ISortedTroves(st).getNext(currentTrove);
        }
        uint lqtyBalance = ILUSDToken(t).balanceOf(BorrowerOperations(bo).lqtyStakingAddress());
        assert (totalSupply >= stabilityPoolBalance.add(trovesBalance).add(gasPoolBalance).add(lqtyBalance));

        currentTrove = ISortedTroves(st).getFirst();
        while (currentTrove != address(0)) {
            // Status
            assert (BorrowerOperations(bo).troveManager().getTroveStatus(currentTrove) == uint256(TroveManager.Status.active));

            // Minimum debt (gas compensation)
            assert(BorrowerOperations(bo).troveManager().getTroveDebt(currentTrove) >= BorrowerOperations(bo).LUSD_GAS_COMPENSATION());

            // Stake > 0
            assert(BorrowerOperations(bo).troveManager().getTroveStake(currentTrove) > 0);
            currentTrove = ISortedTroves(st).getNext(currentTrove);
        }

        currentTrove = ISortedTroves(st).getFirst();
        nextTrove = ISortedTroves(st).getNext(currentTrove);
        uint price = BorrowerOperations(bo).priceFeed().fetchPrice();

        while (currentTrove != address(0) && nextTrove != address(0)) {
            assert (BorrowerOperations(bo).troveManager().getCurrentICR(nextTrove, price) <= BorrowerOperations(bo).troveManager().getCurrentICR(currentTrove, price));
            currentTrove = nextTrove;
            nextTrove = ISortedTroves(st).getNext(currentTrove);
        }

    }

    function getMinETH(uint ratio) internal returns (uint) {
        uint price = BorrowerOperations(bo).priceFeed().fetchPrice();
        uint minETH = ratio.mul(BorrowerOperations(bo).LUSD_GAS_COMPENSATION()).div(price);
        return minETH;
    }

    function getAdjustedLUSD(uint ETH, uint _LUSDAmount, uint ratio) internal returns (uint) {
        uint price = BorrowerOperations(bo).priceFeed().fetchPrice();
        uint LUSDAmount = _LUSDAmount;
        uint compositeDebt = LUSDAmount.add(BorrowerOperations(bo).LUSD_GAS_COMPENSATION());
        uint ICR = LiquityMath._computeCR(ETH, compositeDebt, price);
        if (ICR < ratio) {
            compositeDebt = ETH.mul(price).div(ratio);
            LUSDAmount = compositeDebt.sub(BorrowerOperations(bo).LUSD_GAS_COMPENSATION());
        }
        return LUSDAmount;
    }

    function openTrove_should_not_revert(uint _LUSDAmount) payable public {
        checkInvariants();
        uint256 MIN_NET_DEBT = BorrowerOperations(bo).MIN_NET_DEBT();
        uint price = BorrowerOperations(bo).priceFeed().fetchPrice();
        uint256 _maxFeePercentage = 1000000000000000000;
        if (_LUSDAmount <= MIN_NET_DEBT) 
            _LUSDAmount = MIN_NET_DEBT + 1;

        if (msg.value < getMinETH(BorrowerOperations(bo).CCR())) {
            // should revert if the ether is not enough
            try BorrowerOperations(bo).openTrove{value: msg.value}(_maxFeePercentage, _LUSDAmount, zAddr, zAddr) { assert(false); } catch {} 
            return;
        }

        if (BorrowerOperations(bo).troveManager().getTroveStatus(address(this)) != 0)
            return;

        uint LUSDAmount = getAdjustedLUSD(msg.value, _LUSDAmount, BorrowerOperations(bo).CCR()); 
        require(LUSDAmount >= MIN_NET_DEBT + 1);

        if (BorrowerOperations(bo).troveManager().checkRecoveryMode(price)) {
            // This will revert sometimes, but we don't have a good specification 
            return;
        }

        uint tokensBefore = BorrowerOperations(bo).lusdToken().balanceOf(address(this));

        //(rb,rm) = bo.call{value: msg.value}(abi.encodeWithSignature("openTrove(uint256,address)", LUSDAmount, address(this)));
        try BorrowerOperations(bo).openTrove{value: msg.value}(_maxFeePercentage, LUSDAmount, zAddr, zAddr) {} catch { assert(false); }

        // post conditions
        // should be included in sorted troves
        assert(ISortedTroves(st).contains(address(this)));
        // should be active
        assert(BorrowerOperations(bo).troveManager().getTroveStatus(address(this)) == uint256(TroveManager.Status.active));
        // owner should receive LUSD
        assert(BorrowerOperations(bo).lusdToken().balanceOf(address(this)) == tokensBefore + LUSDAmount);
	mintedLUSD = mintedLUSD + LUSDAmount;
        uint colAfter;
        (,colAfter,,,) = TroveManager(address(BorrowerOperations(bo).troveManager())).Troves(address(this)); 
        // should update collateral
        assert(msg.value == colAfter);
    }

    function addColl_should_not_revert() payable public {
        checkInvariants();
        require(msg.value > 0);

        if (!(BorrowerOperations(bo).troveManager().getTroveStatus(address(this)) == 1)) {
            try BorrowerOperations(bo).addColl{value: msg.value}(zAddr, zAddr) { assert(false); } catch { }
            return;
        }
        
        uint colBefore;
        (,colBefore,,,) = TroveManager(address(BorrowerOperations(bo).troveManager())).Troves(address(this));

        bool pendingRewardsBefore = BorrowerOperations(bo).troveManager().hasPendingRewards(address(this));

        // should not revert
        try BorrowerOperations(bo).addColl{value: msg.value}(zAddr, zAddr) {}
        catch Error (string memory err) {
            if (keccak256(bytes(err)) == keccak256("BorrowerOps: An operation that would result in ICR < MCR is not permitted"))
                return;
	    assert(false);
        } catch { assert(false); }

        // post conditions
        // No pending rewards after call
        bool pendingRewardsAfter = BorrowerOperations(bo).troveManager().hasPendingRewards(address(this));
        assert(!pendingRewardsAfter);

        uint colAfter;
        (,colAfter,,,) = TroveManager(address(BorrowerOperations(bo).troveManager())).Troves(address(this)); 

        // should update collateral depending on the pending rewards
        if (!pendingRewardsBefore)
            assert(colBefore + msg.value == colAfter);
        else
            assert(colBefore + msg.value < colAfter);
    }

    function repayLUSD_should_not_revert(uint256 value) public {
        checkInvariants(); 
        uint256 tokens = BorrowerOperations(bo).lusdToken().balanceOf(address(this));
        require(tokens > 1e18);
        value = value % (tokens + 1);
        if (value < 1e18)
          value = 1e18;

        // it should revert with more tokens
        try BorrowerOperations(bo).repayLUSD(tokens+1, zAddr, zAddr) { assert(false); } catch {}

        // it should not revert with the correct amount of tokens
        try BorrowerOperations(bo).repayLUSD(tokens, zAddr, zAddr) {} 
        catch Error (string memory err) {
            if (keccak256(bytes(err)) == keccak256("BorrowerOps: Trove's net debt must be greater than minimum"))
                return;
            if (keccak256(bytes(err)) == keccak256("BorrowerOps: Caller doesnt have enough LUSD to make repayment"))
                return; 
            if (keccak256(bytes(err)) == keccak256("BorrowerOps: An operation that would result in ICR < MCR is not permitted"))
                return;
            if (keccak256(bytes(err)) == keccak256("SafeMath: subtraction overflow"))
                return;
            if (keccak256(bytes(err)) == keccak256("BorrowerOps: Trove does not exist or is closed"))
                return;
	    assert(false);
        } catch { assert(false); }

        // post conditions
        // it should burn some LUSD from the owner
        assert(BorrowerOperations(bo).lusdToken().balanceOf(address(this)) < tokens);

        // No pending rewards after call
        bool pendingRewardsAfter = BorrowerOperations(bo).troveManager().hasPendingRewards(address(this));
        assert(!pendingRewardsAfter);
    }

    function withdrawLUSD_should_not_revert(uint128 value) public {
        checkInvariants();
        if (value < 1e18)
          value = 1e18; 

        if (!(BorrowerOperations(bo).troveManager().getTroveStatus(address(this)) == 1))
            return; 

        uint256 price = BorrowerOperations(bo).priceFeed().fetchPrice();
        uint256 _maxFeePercentage = 1000000000000000000;

        if (BorrowerOperations(bo).troveManager().checkRecoveryMode(price)) {
            // it should revert in recovery mode
            //try BorrowerOperations(bo).withdrawLUSD(_maxFeePercentage, value, zAddr, zAddr) { assert(false); } catch {}
            return;
        }
        uint tokensBefore = BorrowerOperations(bo).lusdToken().balanceOf(address(this));
        // add tokensBefore > 0 
        // it should not revert
        try BorrowerOperations(bo).withdrawLUSD(_maxFeePercentage, value, zAddr, zAddr) {} 
        catch Error (string memory err) {
            if (keccak256(bytes(err)) == keccak256("BorrowerOps: Caller doesnt have enough LUSD to make repayment"))
              return;
            if (keccak256(bytes(err)) == keccak256("BorrowerOps: An operation that would result in ICR < MCR is not permitted"))
              return;
            assert(false); 
        } catch { 
            assert(false); // this can fail if the price is high?  
        }
        // post conditions
        // token balance should be updated
        uint tokensAfter = BorrowerOperations(bo).lusdToken().balanceOf(address(this));
        assert(tokensBefore + value >= tokensAfter);

        // No pending rewards after call
        bool pendingRewardsAfter = BorrowerOperations(bo).troveManager().hasPendingRewards(address(this));
        assert(!pendingRewardsAfter);
    }

    function closeTrove_should_not_revert() public {
        checkInvariants(); 
        if (!(BorrowerOperations(bo).troveManager().getTroveStatus(address(this)) == 1)) {
            return;
        }

        uint256 price = BorrowerOperations(bo).priceFeed().fetchPrice();

        if (BorrowerOperations(bo).troveManager().checkRecoveryMode(price)) {
            try BorrowerOperations(bo).closeTrove() { assert(false); } catch {}
            return;
        }

        uint debt = BorrowerOperations(bo).troveManager().getTroveDebt(address(this));
        uint tokens = BorrowerOperations(bo).lusdToken().balanceOf(address(this));

        if (tokens < debt.sub(BorrowerOperations(bo).LUSD_GAS_COMPENSATION())) {
            try BorrowerOperations(bo).closeTrove() { assert(false); } catch {} 
            return;
        }

        try BorrowerOperations(bo).closeTrove() {} 
        catch Error (string memory err) {
            if (keccak256(bytes(err)) == keccak256("BorrowerOps: Caller doesnt have enough LUSD to make repayment"))
                return;
	    assert(false);
        } catch { assert(false); }  
        // postconditions
        uint debtAfter;
        uint stakeAfter;

        // debt and stake are zero
        (debtAfter,,stakeAfter,,) = TroveManager(address(BorrowerOperations(bo).troveManager())).Troves(address(this));
        assert(debtAfter == 0);
        assert(stakeAfter == 0);

        // rewards are zero
        uint rs1;
        uint rs2;
        (rs1,rs2) = TroveManager(address(BorrowerOperations(bo).troveManager())).rewardSnapshots(address(this));
        assert(rs1 == 0);
        assert(rs2 == 0); 
        
        // trove is removed
        assert(!ISortedTroves(st).contains(address(this)));

        // trove is closed
        assert(BorrowerOperations(bo).troveManager().getTroveStatus(address(this)) == uint256(TroveManager.Status.closedByOwner));

        // No pending rewards after call
        bool pendingRewardsAfter = BorrowerOperations(bo).troveManager().hasPendingRewards(address(this));
        assert(!pendingRewardsAfter);
    }

    function liquidate_should_not_revert() public {
        checkInvariants(); 

        uint price = BorrowerOperations(bo).priceFeed().fetchPrice();
        uint ICR = BorrowerOperations(bo).troveManager().getCurrentICR(address(this), price);
    
        if (ICR < TroveManager(address(BorrowerOperations(bo).troveManager())).MCR()) {
            try BorrowerOperations(bo).troveManager().liquidate(address(this)) {} 
            catch Error (string memory err) {
                if (keccak256(bytes(err)) == keccak256("TroveManager: nothing to liquidate"))
                    return;
	        assert(false);
            } catch { assert(false); }

            // postconditions
            // same as closing a trove
            uint debtAfter;
            uint stakeAfter;
            (debtAfter,,stakeAfter,,) = TroveManager(address(BorrowerOperations(bo).troveManager())).Troves(address(this));
            assert(debtAfter == 0);
            assert(stakeAfter == 0);

            uint rs1;
            uint rs2;
            (rs1,rs2) = TroveManager(address(BorrowerOperations(bo).troveManager())).rewardSnapshots(address(this));
            assert(rs1 == 0);
            assert(rs2 == 0); 
        
            assert(!ISortedTroves(st).contains(address(this)));
            assert(BorrowerOperations(bo).troveManager().getTroveStatus(address(this)) == uint256(TroveManager.Status.closedByLiquidation));
        }
    }

function liquidateTroves_should_not_revert(uint n) public {
        checkInvariants(); 

        uint price = BorrowerOperations(bo).priceFeed().fetchPrice();
        uint ICR = BorrowerOperations(bo).troveManager().getCurrentICR(address(this), price);
    
        if (ICR < TroveManager(address(BorrowerOperations(bo).troveManager())).MCR()) {
            try BorrowerOperations(bo).troveManager().liquidateTroves(n) {} 
                catch Error (string memory err) {
                if (keccak256(bytes(err)) == keccak256("TroveManager: nothing to liquidate"))
                    return;
	        assert(false);
                } catch { assert(false); } 
        }
    }

    function batchLiquidateTroves_should_not_revert() public {
        checkInvariants();
        address[] memory borrowers = new address[](1);
        borrowers[0] = address(this);

        uint price = BorrowerOperations(bo).priceFeed().fetchPrice();
        uint ICR = BorrowerOperations(bo).troveManager().getCurrentICR(address(this), price);
        uint MCR = TroveManager(address(BorrowerOperations(bo).troveManager())).MCR(); 

        if (ICR < MCR) {

            try BorrowerOperations(bo).troveManager().batchLiquidateTroves(borrowers) {} 
            catch Error (string memory err) {
                if (keccak256(bytes(err)) == keccak256("TroveManager: nothing to liquidate"))
                    return;
	        assert(false);
            } catch { assert(false); }
            // postconditions
            uint debtAfter;
            uint stakeAfter;
            (debtAfter,,stakeAfter,,) = TroveManager(address(BorrowerOperations(bo).troveManager())).Troves(address(this));
            assert(debtAfter == 0);
            assert(stakeAfter == 0);

            uint rs1;
            uint rs2;
            (rs1,rs2) = TroveManager(address(BorrowerOperations(bo).troveManager())).rewardSnapshots(address(this));
            assert(rs1 == 0);
            assert(rs2 == 0); 
        
            assert(!ISortedTroves(st).contains(address(this)));
            assert(BorrowerOperations(bo).troveManager().getTroveStatus(address(this)) == uint256(TroveManager.Status.closedByLiquidation));
        }
    }

    function stake_should_not_revert() public {
        uint tokens = TroveManager(address(BorrowerOperations(bo).troveManager())).lqtyToken().balanceOf(address(this));
        uint staked_old = LQTYStaking(payable(address(TroveManager(address(BorrowerOperations(bo).troveManager())).lqtyStaking()))).stakes(address(this));
        require(tokens > 0);
        try TroveManager(address(BorrowerOperations(bo).troveManager())).lqtyStaking().stake(tokens) {} catch { assert(false); }
        uint staked_new = LQTYStaking(payable(address(TroveManager(address(BorrowerOperations(bo).troveManager())).lqtyStaking()))).stakes(address(this));
        assert(tokens + staked_old == staked_new);
    } 

    function unstake_should_not_revert() public {
        uint staked_old = LQTYStaking(payable(address(TroveManager(address(BorrowerOperations(bo).troveManager())).lqtyStaking()))).stakes(address(this));
        require(staked_old > 0);
        try TroveManager(address(BorrowerOperations(bo).troveManager())).lqtyStaking().unstake(staked_old) {} catch { assert(false); }
        uint staked_new = LQTYStaking(payable(address(TroveManager(address(BorrowerOperations(bo).troveManager())).lqtyStaking()))).stakes(address(this));
        assert(staked_new == 0);
    }

    function provideToSP_should_not_revert() public {
        checkInvariants(); 

        uint tokens = BorrowerOperations(bo).lusdToken().balanceOf(address(this));
        require(tokens > 0);
        
        bool registered = false;
        (, registered) = StabilityPool(payable(sp)).frontEnds(address(this));

        if (registered) {
            // it should revert if caller is registered
            try StabilityPool(payable(sp)).provideToSP(tokens, zAddr) { assert(false); } catch {}
            return;
        }

        // it should revert with more tokens than expected
        try StabilityPool(payable(sp)).provideToSP(tokens+1, zAddr) { assert(false); } catch {}

        // it should not revert
        try StabilityPool(payable(sp)).provideToSP(tokens, zAddr) {}
        catch Error (string memory err) {
            if (keccak256(bytes(err)) == keccak256("StabilityPool: caller must have an active trove to withdraw ETHGain to"))
                return;
	    assert(false);
        } catch { assert(false); }
    }

    function withdrawFromSP_should_not_revert(uint tokens) public {
        checkInvariants(); 

        uint price = BorrowerOperations(bo).priceFeed().fetchPrice();
        uint deposited = 0;
        (deposited,) = StabilityPool(payable(sp)).deposits(address(this));

        if (deposited == 0) {
            try StabilityPool(payable(sp)).withdrawFromSP(tokens) { assert(false); } catch {} 
            return;
        }
        
        try StabilityPool(payable(sp)).withdrawFromSP(deposited) {} 
        catch Error (string memory err) {
            if (keccak256(bytes(err)) == keccak256("StabilityPool: Cannot withdraw while there are troves with ICR < MCR"))
                return;
            if (keccak256(bytes(err)) == keccak256("StabilityPool: caller must have an active trove to withdraw ETHGain to"))
                return;
	    assert(false);
        } catch { assert(false); }

        //post conditions
        // deposited tokens are zero
        (deposited,) = StabilityPool(payable(sp)).deposits(address(this));
        assert(deposited == 0);

        // if stabilityPoolBalance is zero, then epochToScaleToG(0, 0) > 0
        uint stabilityPoolBalance = IStabilityPool(sp).getTotalLUSDDeposits();
        //if (stabilityPoolBalance == 0)
        //    assert(StabilityPool(payable(sp)).epochToScaleToG(0, 0) > 0);
    }

    function withdrawETHGainToTrove_should_not_revert() public {
        checkInvariants(); 
        uint deposited = 0;
        deposited = StabilityPool(payable(sp)).getDepositorETHGain(address(this));

        if (deposited == 0)
            return;

        try StabilityPool(payable(sp)).withdrawETHGainToTrove(zAddr, zAddr) {} 
        catch Error (string memory err) {
            if (keccak256(bytes(err)) == keccak256("BorrowerOps: An operation that would result in ICR < MCR is not permitted"))
              return;
            if (keccak256(bytes(err)) == keccak256("StabilityPool: caller must have an active trove to withdraw ETHGain to"))
              return;
            assert(false);
        } catch {
            assert(false); // this can fail if the price is high?
        }

        // post conditions
        deposited = StabilityPool(payable(sp)).getDepositorETHGain(address(this));
        assert(deposited == 0);
    }

    function withdrawColl_should_revert_if_trove_is_not_active(uint256 col) public {
        checkInvariants(); 
        bool rb = true;
        bytes memory rm;

        if (BorrowerOperations(bo).troveManager().getTroveStatus(address(this)) == 1) {

            uint colBefore;
            (,colBefore,,,) = TroveManager(address(BorrowerOperations(bo).troveManager())).Troves(address(this));
            (rb,rm) = bo.call(abi.encodeWithSignature("withdrawColl(uint256,address)", colBefore+1, address(this)));
            assert(!rb);
            return; 

        }
    
        (rb,rm) = bo.call(abi.encodeWithSignature("withdrawColl(uint256,address)", col, address(this)));
        assert(!rb);
    }

    function withdrawColl_should_revert_if_recovery_mode_is_active(uint256 col) public {
        checkInvariants(); 
        uint price = BorrowerOperations(bo).priceFeed().fetchPrice();

        if (!BorrowerOperations(bo).troveManager().checkRecoveryMode(price))
            return; 
    
        bool rb = true;
        bytes memory rm;

        (rb,rm) = bo.call(abi.encodeWithSignature("withdrawColl(uint256,address)", col, address(this)));
        assert(!rb);
    }
    event LogRevertReason(string);
    event LogNoRevertReason();

    function redeemCollateral_should_not_revert() public {
        checkInvariants(); 
        uint256 _maxFeePercentage = 1000000000000000000;
        uint tokens = BorrowerOperations(bo).lusdToken().balanceOf(address(this));

        uint price = BorrowerOperations(bo).priceFeed().fetchPrice();

        address frh;
        uint prhi;
        (frh, prhi, tokens) = HintHelpers(hh).getRedemptionHints(tokens, price, 0);
        require(tokens > 0);
        address uprh;
        address lprh; 
        (uprh, lprh) = ISortedTroves(st).findInsertPosition(prhi, address(this), address(this));
     
        try BorrowerOperations(bo).troveManager().redeemCollateral(tokens, frh, uprh, lprh, prhi, 3, _maxFeePercentage) {} 
        catch Error (string memory err) {
            if (keccak256(bytes(err)) == keccak256("TroveManager: Unable to redeem any amount"))
                return;
            if (keccak256(bytes(err)) == keccak256("TroveManager: Cannot redeem when TCR < MCR"))
                return;
	    emit LogRevertReason(err);
  	    assert(false);
        } catch {
	    emit LogNoRevertReason();
	    if ( 1000 * tokens / BorrowerOperations(bo).lusdToken().totalSupply() > 100) // 10% of total supply required
	        assert(false);
	} 
    }

    function echidna_optimize_gainedLUSD() public returns (int256) {
        uint256 balance = BorrowerOperations(bo).lusdToken().balanceOf(address(this));
        return int256(balance - mintedLUSD) / 10 ** 18;
    }
   
    event Receive(uint256);
    event Fallback(uint256);

    receive() external payable {
        emit Receive(msg.value);
        //if (msg.sender == address(0x111)) // We do not want ether from the other account
        //  revert();
    }

    fallback() external payable {
        emit Fallback(msg.value);
    }
}
