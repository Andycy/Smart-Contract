pragma solidity ^0.4.24;

import "./openzeppelin-solidity/contracts/token/ERC20/StandardBurnableToken.sol";
import "./openzeppelin-solidity/contracts/ownership/Ownable.sol";
import "./openzeppelin-solidity/contracts/token/ERC20/SafeERC20.sol";

contract StrayToken is StandardBurnableToken, Ownable {
	using SafeERC20 for ERC20;
	
	uint256 public INITIAL_SUPPLY = 1000000000;
	
	string public name = "Stray";
	string public symbol = "ST";
	uint8 public decimals = 18;

	address public companyWallet;
	address public privateWallet;
	
	constructor(address _companyWallet, address _privateWallet) public {
		require(_companyWallet != address(0));
		require(_privateWallet != address(0));
		
		totalSupply_ = INITIAL_SUPPLY * (10 ** uint256(decimals));
		companyWallet = _companyWallet;
		privateWallet = _privateWallet;
		
		// 15% of tokens for company reserved.
		_preSale(companyWallet, totalSupply_.mul(15).div(100));
		
		// 25% of tokens for private funding.
		_preSale(privateWallet, totalSupply_.mul(25).div(100));
		
		// 60% of tokens for crowdsale.
		uint256 saled = balances[companyWallet].add(balances[privateWallet]);
	    balances[msg.sender] = totalSupply_ - saled;
	    emit Transfer(address(0), msg.sender, balances[msg.sender]);
	}
	
	function _preSale(address _to, uint256 _value) internal onlyOwner {
		balances[_to] = _value;
		emit Transfer(address(0), _to, _value);
	}
	
}