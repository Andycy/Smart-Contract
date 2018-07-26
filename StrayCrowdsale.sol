pragma solidity ^0.4.24;

import "./openzeppelin-solidity/contracts/crowdsale/distribution/FinalizableCrowdsale.sol";
import "./openzeppelin-solidity/contracts/crowdsale/distribution/utils/RefundVault.sol";
import "./StrayToken.sol";

/**
 * @title StrayCrowdsale
 * @dev Crowdsale with soft cap, hard cap, and two bonus time window. Investors 
 * can get a refund if the soft cap in not met. 
 * Uses a RefundVault as the crowdsale's vault.
 * We use a fixed exchange rate from USD to Token, so the exchange rate between
 * ETH and Token is floating. 
 */
contract StrayCrowdsale is FinalizableCrowdsale {
    using SafeMath for uint256;
    
    // Soft cap and hard cap in distributed token.
    uint256 public softCapInToken;
    uint256 public hardCapInToken;
    uint256 public soldToken = 0;
    
    // Bouns stage time.
    uint256 public bonusClosingTime0;
    uint256 public bonusClosingTime1;
    
    // Bouns rate.
    uint256 public bonusRateInPercent0 = 33;
    uint256 public bonusRateInPercent1 = 20;
    
    // Mininum contribute: 100 USD.
    uint256 public mininumContributeUSD = 100;
    
    // The floating exchange rate from external API.
    uint256 public decimalsETHToUSD;
    uint256 public exchangeRateETHToUSD;
   
   // The mininum purchase token quantity.
    uint256 public mininumPurchaseTokenQuantity;
    
    // The calculated mininum contribute Wei.
    uint256 public mininumContributeWei;
    
    // The exchange rate from USD to Token.
    // 1 USD => 100 Token (0.01 USD => 1 Token).
    uint256 public exchangeRateUSDToToken = 100;
    
    // Stray token contract.
    StrayToken public strayToken;
    
    // Refund vault used to hold funds while crowdsale is running
    RefundVault public vault;
    
    // Event 
    event RateUpdated(uint256 rate, uint256 mininumContributeWei);
    
    /**
     * @param _softCapInUSD Minimal funds to be collected.
     * @param _hardCapInUSD Maximal funds to be collected.
     * @param _fund The Stray DAICO fund contract address.
     * @param _token Stray ERC20 contract.
     * @param _openingTime Crowdsale opening time.
     * @param _closingTime Crowdsale closing time.
     * @param _bonusClosingTime0 Bonus stage0 closing time.
     * @param _bonusClosingTime1 Bonus stage1 closing time.
     */
    constructor(uint256 _softCapInUSD
        , uint256 _hardCapInUSD
        , address _fund
        , ERC20 _token
        , uint256 _openingTime
        , uint256 _closingTime
        , uint256 _bonusClosingTime0
        , uint256 _bonusClosingTime1
        ) 
        Crowdsale(1, _fund, _token)
        TimedCrowdsale(_openingTime, _closingTime)
        public 
    {
        // Validate ico stage time.
        require(_bonusClosingTime0 >= _openingTime);
        require(_bonusClosingTime1 >= _bonusClosingTime0);
        require(_closingTime >= _bonusClosingTime1);
        
        bonusClosingTime0 = _bonusClosingTime0;
        bonusClosingTime1 = _bonusClosingTime1;
        
        // Create the token.
        strayToken = StrayToken(token);
        
        // Set soft cap and hard cap.
        require(_softCapInUSD > 0 && _softCapInUSD <= _hardCapInUSD);
        
        softCapInToken = _softCapInUSD * exchangeRateUSDToToken * (10 ** uint256(strayToken.decimals()));
        hardCapInToken = _hardCapInUSD * exchangeRateUSDToToken * (10 ** uint256(strayToken.decimals()));
        
        require(strayToken.balanceOf(owner) >= hardCapInToken);
        
        // Create the refund vault.
        vault = new RefundVault(_fund);
        
        // Calculate mininum purchase token.
        mininumPurchaseTokenQuantity = exchangeRateUSDToToken * mininumContributeUSD 
            * (10 ** (uint256(strayToken.decimals())));
        
        // Set default exchange rate ETH => USD: 400.00
        setExchangeRateETHToUSD(40000, 2);
    }
    
    /**
     * @dev Set the exchange rate from ETH to USD.
     * @param _rate The exchange rate.
     * @param _decimals The decimals of input rate.
     */
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
        rate = _rate.mul(exchangeRateUSDToToken);
        if (uint256(strayToken.decimals()) >= _decimals.add(18)) {
            rate = rate.mul(10 ** (uint256(strayToken.decimals()).sub(18).sub(_decimals)));
        } else {
            rate = rate.div(10 ** (_decimals.add(18).sub(uint256(strayToken.decimals()))));
        }
        
        mininumContributeWei = mininumPurchaseTokenQuantity.div(rate); 
        
        // Avoid rounding error.
        if (mininumContributeWei * rate < mininumPurchaseTokenQuantity)
            mininumContributeWei += 1;
            
        emit RateUpdated(rate, mininumContributeWei);
    }
    
    /**
     * @dev Investors can claim refunds here if crowdsale is unsuccessful
     */
    function claimRefund() public {
        require(isFinalized);
        require(!softCapReached());

        vault.refund(msg.sender);
    }
    
    /**
     * @dev Checks whether funding goal was reached.
     * @return Whether funding goal was reached
     */
    function softCapReached() public view returns (bool) {
        return soldToken >= softCapInToken;
    }
    
    /**
     * @dev Validate if it is in ICO stage 1.
     */
    function isInStage1() view public returns (bool) {
        return now <= bonusClosingTime0 && now >= openingTime;
    }
    
    /**
     * @dev Validate if it is in ICO stage 2.
     */
    function isInStage2() view public returns (bool) {
        return now <= bonusClosingTime1 && now > bonusClosingTime0;
    }
    
    /**
     * @dev Validate if crowdsale has started.
     */
    function hasStarted() view public returns (bool) {
        return now >= openingTime;
    }
    
    /**
     * @dev Validate the mininum contribution requirement.
     */
    function _preValidatePurchase(address _beneficiary, uint256 _weiAmount)
        internal
    {
        super._preValidatePurchase(_beneficiary, _weiAmount);
        require(_weiAmount >= mininumContributeWei);
    }
    
    /**
     * @dev Executed when a purchase has been validated and is ready to be executed. Not necessarily emits/sends tokens.
     * @param _beneficiary Address receiving the tokens
     * @param _tokenAmount Number of tokens to be purchased
     */
    function _processPurchase(address _beneficiary, uint256 _tokenAmount) internal {
        soldToken = soldToken.add(_tokenAmount);
        require(soldToken <= hardCapInToken);
        
       _tokenAmount = _addBonus(_tokenAmount);
        
        super._processPurchase(_beneficiary, _tokenAmount);
    }
    
    /**
     * @dev Finalization task, called when owner calls finalize()
     */
    function finalization() internal {
        if (softCapReached()) {
            vault.close();
        } else {
            vault.enableRefunds();
        }
        
        // Burn all the unsold token.
        strayToken.burn(token.balanceOf(address(this)));
        
        super.finalization();
    }

    /**
     * @dev Overrides Crowdsale fund forwarding, sending funds to vault.
     */
    function _forwardFunds() internal {
        vault.deposit.value(msg.value)(msg.sender);
    }
    
    /**
     * @dev Calculate the token amount and add bonus if needed.
     */
    function _addBonus(uint256 _tokenAmount) internal view returns (uint256) {
        if (bonusClosingTime0 >= now) {
            _tokenAmount = _tokenAmount.mul(100 + bonusRateInPercent0).div(100);
        } else if (bonusClosingTime1 >= now) {
            _tokenAmount = _tokenAmount.mul(100 + bonusRateInPercent1).div(100);
        }
        
        require(_tokenAmount <= token.balanceOf(address(this)));
        
        return _tokenAmount;
    }
}