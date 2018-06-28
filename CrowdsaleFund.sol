pragma solidity ^0.4.24;

import "./openzeppelin-solidity/contracts/math/SafeMath.sol";
import "./openzeppelin-solidity/contracts/ownership/Ownable.sol";

/**
 * @title CrowdsaleFund
 * @dev This contract is used for storing funds in the crowdsale stage. Supports
 * refunding if the crowdsale was failed. Developers can override `_processClosed`
 * function to define the operation if the crowdsale was successed.
 */
contract CrowdsaleFund is Ownable {
    using SafeMath for uint256;

    enum CrowdsaleState { NotReady, Active, Refunding, Closed }

	mapping (address => uint256) public deposited;
	CrowdsaleState public crowdsaleState;
	
	event ActiveEnabled();
	event Closed();
	event RefundsEnabled();
	event Refunded(address indexed beneficiary, uint256 weiAmount);
	
	constructor() public {
	    crowdsaleState = CrowdsaleState.NotReady;
	}
	
	function setCrowdsale(address _crowdsale) onlyOwner public {
		require(_crowdsale != address(0));
		require(_crowdsale != address(this));
		require(_crowdsale != owner);
	    
	    transferOwnership(_crowdsale);
	    crowdsaleState = CrowdsaleState.Active;
	    emit ActiveEnabled();
	}
	
	/**
	 * @param investor The investor address.
	 */
	function deposit(address investor) onlyOwner public payable {
		require(crowdsaleState == CrowdsaleState.Active);
		deposited[investor] = deposited[investor].add(msg.value);
	}
	
	function onCrowdsaleEnd(address _newOwner, bool isCrowdsaleSuccess) public onlyOwner {
	    require(_newOwner != address(0));
	    require(_newOwner != address(this));
	    require(_newOwner != owner);
	    require(crowdsaleState == CrowdsaleState.Active);
	    
	    if (isCrowdsaleSuccess) {
	        _processClosed();
	    } else {
	        crowdsaleState = CrowdsaleState.Refunding;
            emit RefundsEnabled();
	    }
	    
	    transferOwnership(_newOwner);
	}

    /**
     * @param investor Investor address
     */
    function crowdsaleRefund(address investor) public {
        require(crowdsaleState == CrowdsaleState.Refunding);
        uint256 depositedValue = deposited[investor];
        deposited[investor] = 0;
        investor.transfer(depositedValue);
        emit Refunded(investor, depositedValue);
    }    
	
	function _processClosed() internal {
	    crowdsaleState = CrowdsaleState.Closed;
	}
}