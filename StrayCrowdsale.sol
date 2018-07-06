pragma solidity ^0.4.24;

import "./openzeppelin-solidity/contracts/crowdsale/distribution/FinalizableCrowdsale.sol";
import "./CrowdsaleFund.sol";
import "./StrayToken.sol";

/**
 * @title StrayCrowdsale
 * @dev Crowdsale with soft cap, hard cap, and two bonus time window. 
 */
contract StrayCrowdsale is FinalizableCrowdsale {
    using SafeMath for uint256;
    
    uint256 public softCap;
    uint256 public hardCap;
    
    uint256 public bonusClosingTime0;
    uint256 public bonusClosingTime1;
    uint256 public bonusRateInPercent0 = 33;
    uint256 public bonusRateInPercent1 = 20;
    
    uint256 public minContributeWei = 10 finney;
    
    CrowdsaleFund public fund;
    
    /**
     * @param _fund Address where collected funds will be forwared to.
     * @param _token Address of the token being sold.
     * @param _softCapInEther Minimal funds to be collected.
     * @param _hardCapInEther Maximal funds to be collected.
     * @param _openingTime Crowdsale opening time.
     * @param _closingTime Crowdsale closing time.
     * @param _bonusClosingTime0 Bonus stage0 closing time.
     * @param _bonusClosingTime1 Bonus stage1 closing time.
     */
    constructor(address _fund
        , ERC20 _token
        , uint256 _softCapInEther
        , uint256 _hardCapInEther
        , uint256 _openingTime
        , uint256 _closingTime
        , uint256 _bonusClosingTime0
        , uint256 _bonusClosingTime1
        )
        public 
        Crowdsale(1, _fund, _token)
        TimedCrowdsale(_openingTime, _closingTime)
    {
        require(_softCapInEther > 0 && _softCapInEther < _hardCapInEther);
        require(_bonusClosingTime0 >= _openingTime);
        require(_bonusClosingTime1 >= _bonusClosingTime0);
        require(_closingTime >= _bonusClosingTime1);
        
        fund = CrowdsaleFund(wallet);
        
        softCap = _softCapInEther * 1e18;
        hardCap = _hardCapInEther * 1e18;
        
        bonusClosingTime0 = _bonusClosingTime0;
        bonusClosingTime1 = _bonusClosingTime1;
    }
    
    function _preValidatePurchase(address _beneficiary, uint256 _weiAmount)
        internal
    {
        super._preValidatePurchase(_beneficiary, _weiAmount);
        require(_weiAmount >= minContributeWei);
        require(weiRaised.add(_weiAmount) <= hardCap);
    }
    
    function _getTokenAmount(uint256 _weiAmount) internal view returns (uint256)
    {
        uint256 noBonus = super._getTokenAmount(_weiAmount);
        if (bonusClosingTime0 >= now) {
            return noBonus.mul(100 + bonusRateInPercent0).div(100);
        } else if (bonusClosingTime1 >= now) {
            return noBonus.mul(100 + bonusRateInPercent1).div(100);
        } else {
            return noBonus;
        }
    }
    
    function _forwardFunds() internal {
        fund.deposit.value(msg.value)(msg.sender);
    }
    
    function finalization() internal {
        bool isSuccess = weiRaised >= softCap;
        fund.onCrowdsaleEnd(owner, isSuccess);
        
        StrayToken strayToken = StrayToken(token);
        strayToken.burn(token.balanceOf(address(this)));
        strayToken.onCrowdsaleEnd(owner, isSuccess);
        
        super.finalization();
    } 
}