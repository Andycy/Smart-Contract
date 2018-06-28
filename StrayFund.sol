pragma solidity ^0.4.24;

import "./openzeppelin-solidity/contracts/math/SafeMath.sol";
import "./openzeppelin-solidity/contracts/token/ERC20/ERC20Basic.sol";
import "./CrowdsaleFund.sol";

contract StrayFund is CrowdsaleFund {
	using SafeMath for uint256;
	
	enum FundState { NotReady, TeamWithdraw, Refunding, Closed }
	enum ProposalType { TapFromTokenHolder, TapFromCompany, Refund }
	
	uint256 NON_UINT256 = (2 ** 256) - 1;
	
	struct Vote {
		address tokeHolder;
		bool inSupport;
	}
	
	struct Proposal {
	    ProposalType proposalType;
	    address sponsor;
	    uint256 openingTime;
	    uint256 closingTime;
	    Vote[] votes;
		mapping (address => bool) voted;
		bool isPassed;
		bool isFinialized;
		uint256 tapRate;
	}
	
	struct TappedWithdrawPlan {
	    uint256 proposalId;
	    uint256 limitInWei;
	    uint256 withdrawnWei;
	    uint256 openingTime;
	    uint256 closingTime;
	}
	
	address public teamWallet;
	FundState public fundState;
	
	ERC20Basic public token;
	
	Proposal[] public proposals;
	TappedWithdrawPlan[] public tappedWithdrawPlans;
	
	uint256 lastRefundProposalId = NON_UINT256;
	uint256 currentWithdrawPlanId;
	
	uint256 public MIN_WITHDRAW_WEI = 1 ether;
	
	uint256 public FIRST_WITHDRAW_RATE = 10;
	uint256 public WITHDRAW_DURATION_PER_PLAN = 90 days;
	uint256 public VOTING_DURATION = 1 weeks;
	uint256 public REFUND_LOCK_DURATION = 30 days;
	uint256 public REFUND_PROPOSAL_LOCK_DURATION = 90 days;
	
	uint256 public refundLockDate = 0;
	
	event TeamWithdrawEnabled();
	event RefundsEnabled();
	event Closed();
	
	event TapVoted(address indexed voter, bool isSupported);
	event TapProposalAdded(uint256 openingTime, uint256 closingTime, uint256 targetRate);
	event TapProposalClosed(uint256 closingTime, uint256 targetRate, bool isPassed);
	
	event RefundVoted(address indexed voter, bool isSupported);
	event RefundProposalAdded(uint256 openingTime, uint256 closingTime);
	event RefundProposalClosed(uint256 closingTime, bool isPassed);
	
	event Withdrew(uint256 weiAmount);
	
	modifier onlyTokenHolders {
		require(token.balanceOf(msg.sender) != 0);
		_;
	}
	
	modifier inWithdrawState {
	    require(fundState == FundState.TeamWithdraw);
	    _;
	}
	
	constructor(address _teamWallet, address _token) public {
		require(_teamWallet != address(0));
		require(_token != address(0));
		
		teamWallet = _teamWallet;
		fundState = FundState.NotReady;
		token = ERC20Basic(_token);
	}
	
	function enableTeamWithdraw() onlyOwner public {
		require(fundState == FundState.NotReady);
		fundState = FundState.TeamWithdraw;
		emit TeamWithdrawEnabled();
		
		tappedWithdrawPlans.length++;
		TappedWithdrawPlan storage plan = tappedWithdrawPlans[0];
	    plan.proposalId = NON_UINT256;
	    plan.limitInWei = address(this).balance.mul(FIRST_WITHDRAW_RATE).div(100);
	    plan.withdrawnWei = 0;
	    plan.openingTime = now;
	    plan.closingTime = plan.openingTime + WITHDRAW_DURATION_PER_PLAN;
	    
	    currentWithdrawPlanId = 0;
	}
	
	function close() onlyOwner inWithdrawState public {
	    require(address(this).balance < MIN_WITHDRAW_WEI);
	    
		fundState = FundState.Closed;
		emit Closed();
		
		teamWallet.transfer(address(this).balance);
	}
	
	function isThereAnOnGoingProposal() inWithdrawState public view returns (bool) {
	    if (proposals.length == 0) {
	        return false;
	    } else {
	        Proposal storage p = proposals[proposals.length - 1];
	        return now < p.closingTime;
	    }
	}
	
	function isNextWithdrawPlanMade() inWithdrawState public view returns (bool) {
	    return currentWithdrawPlanId != tappedWithdrawPlans.length - 1;
	}
	
	function tryFinializeLastProposal() inWithdrawState public {
	    if (proposals.length == 0) {
	        return;
	    }
	    
	    uint256 id = proposals.length - 1;
	    Proposal storage p = proposals[id];
	    if (now > p.closingTime && !p.isFinialized) {
	        _countVotes(p);
	        if (p.isPassed) {
	            if (p.proposalType == ProposalType.Refund) {
	                _enableRefunds();
	            } else {
	                _makeWithdrawPlan(p, id);
	            }
	        }
	    }
	}
	
	function nextTapFromTokenHoldersProposalTime() 
	    public 
	    view 
	    returns (uint256 startTime, uint256 endTime) 
	{
	    uint256 id = 0;
	    if (isNextWithdrawPlanMade()) {
	        id = tappedWithdrawPlans.length - 1;
	    } else {
	        id = currentWithdrawPlanId;
	    }
	    
	    TappedWithdrawPlan storage p = tappedWithdrawPlans[id];
	    startTime = p.openingTime;
	    endTime = p.closingTime - VOTING_DURATION;
	}
	
	function nextTapFromCompanyProposalStartTime() 
	    public 
	    view 
	    returns (uint256) 
	{
	    if (isNextWithdrawPlanMade()) {
	        return NON_UINT256;
	    } else {
	        TappedWithdrawPlan storage plan = tappedWithdrawPlans[currentWithdrawPlanId];
	        return plan.closingTime - VOTING_DURATION;
	    }
	}
	
	function nextRefundProposalStartTime() 
	    public 
	    view 
	    returns (uint256) 
	{
	    if (lastRefundProposalId >= proposals.length) {
	        return now;
	    } else {
	        Proposal storage p = proposals[lastRefundProposalId];
	        return p.closingTime + REFUND_PROPOSAL_LOCK_DURATION;
	    }
	}
	
	function newTapProposalFromTokenHolders(uint256 targetTapRate)
	    onlyTokenHolders 
	    inWithdrawState 
	    public
	{
	    require(msg.sender != owner);
	    require(msg.sender != teamWallet);
	    
	    tryFinializeLastProposal();
	    require(fundState == FundState.TeamWithdraw);
	    
	    require(!isNextWithdrawPlanMade());
	    require(!isThereAnOnGoingProposal());
	    
	    uint256 startTime;
	    uint256 endTime;
	    (startTime, endTime) = nextTapFromTokenHoldersProposalTime();
		require(now <= endTime && now >= startTime);
		
		uint256 amount = address(this).balance.mul(targetTapRate).div(100);
		require(amount >= MIN_WITHDRAW_WEI);
		
		_newTapProposal(ProposalType.TapFromTokenHolder, targetTapRate);
	}
	
	function newTapProposalFromCompany(uint256 targetTapRate)
	    onlyOwner 
	    inWithdrawState 
	    public
	{
	    tryFinializeLastProposal();
	    require(fundState == FundState.TeamWithdraw);
	    
	    require(!isNextWithdrawPlanMade());
	    require(!isThereAnOnGoingProposal());
	    
	    uint256 startTime = nextTapFromCompanyProposalStartTime();
		require(now >= startTime);
		
		uint256 amount = address(this).balance.mul(targetTapRate).div(100);
		require(amount >= MIN_WITHDRAW_WEI);
		
		_newTapProposal(ProposalType.TapFromCompany, targetTapRate);
	}
	
	function newRefundProposal() onlyTokenHolders inWithdrawState public {
	    tryFinializeLastProposal();
	    require(fundState == FundState.TeamWithdraw);
	    require(!isThereAnOnGoingProposal());
	    require(now >= nextRefundProposalStartTime());
	    
		uint256 id = proposals.length++;
		Proposal storage p = proposals[id];
		p.proposalType = ProposalType.Refund;
		p.sponsor = msg.sender;
		p.openingTime = now;
		p.closingTime = now + VOTING_DURATION;
		p.isPassed = false;
		p.isFinialized = false;
		
		emit RefundProposalAdded(p.openingTime, p.closingTime);
	}
	
	function voteForTap(bool supportsProposal)
	    onlyTokenHolders
	    inWithdrawState
	    public
	{
	    tryFinializeLastProposal();
		require(isThereAnOnGoingProposal());
		
		Proposal storage p = proposals[proposals.length - 1];
		require(p.proposalType != ProposalType.Refund);
		require(true != p.voted[msg.sender]);
		
		uint256 voteId = p.votes.length++;
		p.votes[voteId].tokeHolder = msg.sender;
		p.votes[voteId].inSupport = supportsProposal;
		p.voted[msg.sender] = true;
		
		emit TapVoted(msg.sender, supportsProposal);
	}
	
	function voteForRefund(bool supportsProposal)
	    onlyTokenHolders
	    inWithdrawState
	    public
	{
	    tryFinializeLastProposal();
		require(isThereAnOnGoingProposal());
		
		Proposal storage p = proposals[proposals.length - 1];
		require(p.proposalType == ProposalType.Refund);
		require(true != p.voted[msg.sender]);
		
		uint256 voteId = p.votes.length++;
		p.votes[voteId].tokeHolder = msg.sender;
		p.votes[voteId].inSupport = supportsProposal;
		p.voted[msg.sender] = true;
		
		emit RefundVoted(msg.sender, supportsProposal);
	}
	
	function withdraw(uint256 amount) onlyOwner inWithdrawState public {
	    tryFinializeLastProposal();
	    
	    TappedWithdrawPlan storage currentPlan = tappedWithdrawPlans[currentWithdrawPlanId];
	    if (now > currentPlan.closingTime) {
	        require(isNextWithdrawPlanMade());
	        ++currentWithdrawPlanId;
	        
	       TappedWithdrawPlan storage plan = tappedWithdrawPlans[currentWithdrawPlanId];
	       require(now <= plan.closingTime);
	       require(amount <= plan.limitInWei - plan.withdrawnWei);
	       
	       plan.withdrawnWei += amount;
	       teamWallet.transfer(amount);
	       emit Withdrew(amount);
	    } else {
	        require(amount <= currentPlan.limitInWei - currentPlan.withdrawnWei);
	        
	        currentPlan.withdrawnWei += amount;
	        teamWallet.transfer(amount);
	        emit Withdrew(amount);
	    }
	}
	
	function withdrawOnNoAvailablePlan() onlyOwner inWithdrawState public {
	    require(address(this).balance >= MIN_WITHDRAW_WEI);
	    
	    tryFinializeLastProposal();
	    
	    require(!_isThereAnOnGoingTapProposal());
	    
	    TappedWithdrawPlan storage currentPlan = tappedWithdrawPlans[currentWithdrawPlanId];
	    require(now > currentPlan.closingTime);
	    
	    uint256 planId = tappedWithdrawPlans.length++;
	    TappedWithdrawPlan storage plan = tappedWithdrawPlans[planId];
	    plan.proposalId = NON_UINT256;
	    plan.limitInWei = MIN_WITHDRAW_WEI;
	    plan.withdrawnWei = MIN_WITHDRAW_WEI;
	    plan.openingTime = now;
	    plan.closingTime = now + WITHDRAW_DURATION_PER_PLAN; 
	    
	    teamWallet.transfer(MIN_WITHDRAW_WEI);
	    emit Withdrew(MIN_WITHDRAW_WEI);
	}
	
	function refund() onlyTokenHolders public {
		require(fundState == FundState.Refunding);
		require(now > refundLockDate + REFUND_LOCK_DURATION);
		
		uint256 amount = address(this).balance.mul(token.totalSupply()).div(token.balanceOf(msg.sender));
		msg.sender.transfer(amount);
	}
	
	function _countVotes(Proposal storage p)
	    internal 
	    returns (bool)
	{
	    require(!p.isFinialized);
	    require(now > p.closingTime);
	    
		uint256 yes = 0;
		uint256 no = 0;
		
		for (uint256 i = 0; i < p.votes.length; ++i) {
			Vote storage v = p.votes[i];
			uint256 voteWeight = token.balanceOf(v.tokeHolder);
			if (v.inSupport) {
				yes += voteWeight;
			} else {
				no += voteWeight;
			}
		}
		
		p.isPassed = (yes >= no);
		p.isFinialized = true;
		
		emit TapProposalClosed(p.closingTime
			, p.tapRate
			, p.isPassed);
		
		return p.isPassed;
	}
	
	function _enableRefunds() inWithdrawState internal {
	    fundState = FundState.Refunding;
		emit RefundsEnabled();
		
		refundLockDate = now;
	}
	
	function _makeWithdrawPlan(Proposal storage p, uint256 proposalId) 
	    internal
	{
	    require(p.proposalType != ProposalType.Refund);
	    require(p.isFinialized);
	    require(p.isPassed);
	    require(currentWithdrawPlanId + 1 == tappedWithdrawPlans.length);
	    
	    uint256 planId = tappedWithdrawPlans.length++;
	    TappedWithdrawPlan storage plan = tappedWithdrawPlans[planId];
	    plan.proposalId = proposalId;
	    plan.limitInWei = address(this).balance.mul(p.tapRate).div(100);
	    plan.withdrawnWei = 0;
	    
	    if (p.proposalType == ProposalType.TapFromTokenHolder) {
	        plan.openingTime = tappedWithdrawPlans[currentWithdrawPlanId].closingTime;
	    } else {
	        plan.openingTime = now;
	    }
	    
	    plan.closingTime = plan.openingTime + WITHDRAW_DURATION_PER_PLAN;
	}
	
	function _newTapProposal(ProposalType proposalType, uint256 targetTapRate) internal {
	    uint256 id = proposals.length++;
        Proposal storage p = proposals[id];
        p.proposalType = proposalType;
		p.sponsor = msg.sender;
		p.openingTime = now;
		p.closingTime = now + 1 weeks;
		p.isPassed = false;
		p.isFinialized = false;
		p.tapRate = targetTapRate;
		
		emit TapProposalAdded(p.openingTime
			, p.closingTime
			, p.tapRate);
	}
	
	function _isThereAnOnGoingTapProposal() internal view returns (bool) {
	    if (proposals.length == 0) {
	        return false;
	    } else {
	        Proposal storage p = proposals[proposals.length - 1];
	        return p.proposalType != ProposalType.Refund  && now < p.closingTime;
	    }
	}
	
	function _processClosed() internal {
	    super._processClosed();
	    enableTeamWithdraw();
	}
}