pragma solidity ^0.4.24;

import "./openzeppelin-solidity/contracts/token/ERC20/StandardToken.sol";
import "./openzeppelin-solidity/contracts/token/ERC20/BurnableToken.sol";
import "./openzeppelin-solidity/contracts/ownership/Ownable.sol";
import "./openzeppelin-solidity/contracts/token/ERC20/SafeERC20.sol";

/**
 * @title StrayToken
 * @dev Stray ERC20 token supports the DAICO. The DAICO fund contract 
 * will burn all user's token after the user took its refund.
 */
contract StrayToken is StandardToken, BurnableToken, Ownable {
	using SafeERC20 for ERC20;
	
	uint256 public INITIAL_SUPPLY = 1000000000;
	
	string public name = "Stray";
	string public symbol = "ST";
	uint8 public decimals = 18;

	address public companyWallet;
	address public privateWallet;
	address public fund;
	
	/**
	 * @param _companyWallet The company wallet which reserves 15% of the token.
	 * @param _privateWallet Private wallet which reservers 25% of the token.
	 */
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
	
	/**
	 * @param _fund The DAICO fund contract address.
	 */
	function setFundContract(address _fund) onlyOwner public {
	    require(_fund != address(0));
	    //require(_fund != owner);
	    //require(_fund != msg.sender);
	    require(_fund != address(this));
	    
	    fund = _fund;
	}
	
	/**
	 * @dev The DAICO fund contract calls this function to burn the user's token
	 * to avoid over refund.
	 * @param _from The address which just took its refund.
	 */
	function burnAll(address _from) public {
	    require(fund == msg.sender);
	    require(0 != balances[_from]);
	    
	    _burn(_from, balances[_from]);
	}
	
	/**
	 * @param _to The address which will get the token.
	 * @param _value The token amount.
	 */
	function _preSale(address _to, uint256 _value) internal onlyOwner {
		balances[_to] = _value;
		emit Transfer(address(0), _to, _value);
	}
	
}