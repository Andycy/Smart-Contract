pragma solidity ^0.4.24;

import "./openzeppelin-solidity/contracts/token/ERC20/StandardBurnableToken.sol";
import "./openzeppelin-solidity/contracts/token/ERC20/PausableToken.sol";
import "./openzeppelin-solidity/contracts/token/ERC20/SafeERC20.sol";

contract StrayToken is StandardBurnableToken, PausableToken {
	using SafeERC20 for ERC20;
	
	uint256 public INITIAL_SUPPLY = 1000000000;
	
	string public name = "Stray";
	string public symbol = "ST";
	uint8 public decimals = 16;

	address public companyWallet;
	address public privateWallet;
	
	constructor(address _companyWallet, address _privateWallet) public {
		require(_companyWallet != address(0));
		require(_privateWallet != address(0));
		
		totalSupply_ = INITIAL_SUPPLY * (10 ** uint256(decimals));
		companyWallet = _companyWallet;
		privateWallet = _privateWallet;
		
		// Pause the token tranfering until a crowdsale has been set.
		pause();
		
		// 15% of tokens for company reserved.
		_preSale(companyWallet, totalSupply_.mul(15).div(100));
		
		// 25% of tokens for private funding.
		_preSale(privateWallet, totalSupply_.mul(25).div(100));
	}
	
	function setCrowdsale(address _crowdsale) public onlyOwner whenPaused {
	    require(_crowdsale != address(0));
	    require(_crowdsale != address(this));
	    require(_crowdsale != owner);
	    
	    uint256 saled = balances[companyWallet].add(balances[privateWallet]);
	    balances[_crowdsale] = totalSupply_ - saled;
	    emit Transfer(address(0), _crowdsale, balances[_crowdsale]);
	    
	    unpause();
	    transferOwnership(_crowdsale);
	}
	
	function onCrowdsaleEnd(address _newOwner, bool isCrowdsaleSuccess) public onlyOwner {
	    require(_newOwner != address(0));
	    require(_newOwner != address(this));
	    require(_newOwner != owner);
	    
	    if (!isCrowdsaleSuccess) {
	        pause();
	    }
	    
	    transferOwnership(_newOwner);
	}
	
	function _preSale(address _to, uint256 _value) internal onlyOwner whenPaused {
		balances[_to] = _value;
		emit Transfer(address(0), _to, _value);
	}
	
}