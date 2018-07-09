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
    
    uint256 public softCapInToken;
    uint256 public hardCapInToken;
    
    uint256 public bonusClosingTime0;
    uint256 public bonusClosingTime1;
    uint256 public bonusRateInPercent0 = 33;
    uint256 public bonusRateInPercent1 = 20;
    
    uint256 public mininumContributeUSD = 100;
    uint256 public decimalsUSDToToken = 5; 
    uint256 public exchangeRateUSDToToken = 100 * (10 ** decimalsUSDToToken);
    uint256 public decimalsETHToUSD;
    uint256 public exchangeRateETHToUSD;
   
    
    uint256 public mininumPurchaseTokenQuantity;
    uint256 public mininumContributeWei;
    
    CrowdsaleFund public fund;
    StrayToken strayToken;
    
    /**
     * @param _fund Address where collected funds will be forwared to.
     * @param _token Address of the token being sold.
     * @param _softCapInToken Minimal funds to be collected.
     * @param _openingTime Crowdsale opening time.
     * @param _closingTime Crowdsale closing time.
     * @param _bonusClosingTime0 Bonus stage0 closing time.
     * @param _bonusClosingTime1 Bonus stage1 closing time.
     */
    constructor(address _fund
        , ERC20 _token
        , uint256 _softCapInToken
        , uint256 _openingTime
        , uint256 _closingTime
        , uint256 _bonusClosingTime0
        , uint256 _bonusClosingTime1
        )
        public 
        Crowdsale(1, _fund, _token)
        TimedCrowdsale(_openingTime, _closingTime)
        //TimedCrowdsale(now, now + 1 days)
    {
        /*
        uint256 _bonusClosingTime0 = now + 10 minutes;
        uint256 _bonusClosingTime1 = now + 11 minutes;
        uint256 _openingTime = now;
        uint256 _closingTime = now + 1 days;
        */
        
        require(_bonusClosingTime0 >= _openingTime);
        require(_bonusClosingTime1 >= _bonusClosingTime0);
        require(_closingTime >= _bonusClosingTime1);
        
        strayToken = StrayToken(_token);
        require(msg.sender == strayToken.owner());
        
        softCapInToken = _softCapInToken * (10 ** uint256(strayToken.decimals()));
        hardCapInToken = strayToken.balanceOf(msg.sender);
        
        require(softCapInToken > 0 && softCapInToken < hardCapInToken);
        
        fund = CrowdsaleFund(wallet);
        
        bonusClosingTime0 = _bonusClosingTime0;
        bonusClosingTime1 = _bonusClosingTime1;
        
        mininumPurchaseTokenQuantity = exchangeRateUSDToToken * mininumContributeUSD 
            * (10 ** (uint256(strayToken.decimals()) - decimalsUSDToToken));
        
        setExchangeRateETHToUSD(40000, 2);
    }
    
    function setExchangeRateETHToUSD(uint256 _rate, uint256 _decimals) onlyOwner public {
        // wei * 1e-18 * _rate * 1e(-_decimals) * 1e2          = amount * 1e(-token.decimals);
        // -----------   ----------------------   -------------
        // Wei => ETH      ETH => USD             USD => Token
        //
        // If _rate = 1, wei = 1,
        // Then  amount = 1e(token.decimals + 2 - 18 - _decimals).
        // We need amount >= 1 to ensure the precision.
        
        require(uint256(strayToken.decimals()).add(2) >= _decimals.add(18));
        
        exchangeRateETHToUSD = _rate;
        decimalsETHToUSD = _decimals;
        rate = _rate * exchangeRateUSDToToken 
            * (10 ** (uint256(strayToken.decimals()) + decimalsUSDToToken - 18 - _decimals));
        
        mininumContributeWei = mininumPurchaseTokenQuantity.div(rate); 
        
        // Avoid rounding error.
        if (mininumContributeWei * rate < mininumPurchaseTokenQuantity)
            mininumContributeWei += 1;
    }
    
    function currentRasiedToken() view public returns (uint256) {
        return hardCapInToken.sub(token.balanceOf(address(this)));
    }
    
    function _preValidatePurchase(address _beneficiary, uint256 _weiAmount)
        internal
    {
        super._preValidatePurchase(_beneficiary, _weiAmount);
        require(_weiAmount >= mininumContributeWei);
    }
    
    function _getTokenAmount(uint256 _weiAmount) internal view returns (uint256)
    {
        uint256 noBonus = super._getTokenAmount(_weiAmount);
        uint256 amount;
        if (bonusClosingTime0 >= now) {
            amount = noBonus.mul(100 + bonusRateInPercent0).div(100);
        } else if (bonusClosingTime1 >= now) {
            amount = noBonus.mul(100 + bonusRateInPercent1).div(100);
        } else {
            amount = noBonus;
        }
        
        require(amount <= token.balanceOf(address(this)));
        
        return amount;
    }
    
    function _forwardFunds() internal {
        fund.deposit.value(msg.value)(msg.sender);
    }
    
    function finalization() internal {
        bool isSuccess = currentRasiedToken() >= softCapInToken;
        fund.onCrowdsaleEnd(owner, isSuccess);
        
        strayToken.burn(token.balanceOf(address(this)));
        
        super.finalization();
    }
}