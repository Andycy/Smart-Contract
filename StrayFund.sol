pragma solidity ^0.4.24;

import "./openzeppelin-solidity/contracts/math/SafeMath.sol";
import "./openzeppelin-solidity/contracts/token/ERC20/ERC20Basic.sol";
import "./CrowdsaleFund.sol";
import "./DateTimeUtility.sol";
import "./StrayToken.sol";

contract StrayFund is CrowdsaleFund {
	using SafeMath for uint256;
	using DateTimeUtility for uint256;
	
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
		uint256 targetWei;
	}
	
	struct BudgetPlan {
	    uint256 proposalId;
	    uint256 budgetInWei;
	    uint256 withdrawnWei;
	    uint256 startTime;
	    uint256 endTime;
	    uint256 officalVotingTime;
	}
	
	address public teamWallet;
	FundState public fundState;
	
	StrayToken public token;
	
	Proposal[] public proposals;
	BudgetPlan[] public budgetPlans;
	
	uint256 lastRefundProposalId = NON_UINT256;
	uint256 currentBudgetPlanId;
	
	uint256 public MIN_WITHDRAW_WEI = 1 ether;
	
	uint256 public FIRST_WITHDRAW_RATE = 20;
	uint256 public VOTING_DURATION = 1 weeks;
	uint8 public OFFICAL_VOTING_DAY_OF_MONTH = 23;
	uint256 public REFUND_LOCK_DURATION = 30 days;
	
	uint256 public refundLockDate = 0;
	
	event TeamWithdrawEnabled();
	event RefundsEnabled();
	event Closed();
	
	event TapVoted(address indexed voter, bool isSupported);
	event TapProposalAdded(uint256 openingTime, uint256 closingTime, uint256 targetWei);
	event TapProposalClosed(uint256 closingTime, uint256 targetWei, bool isPassed);
	
	event RefundVoted(address indexed voter, bool isSupported);
	event RefundProposalAdded(uint256 openingTime, uint256 closingTime);
	event RefundProposalClosed(uint256 closingTime, bool isPassed);
	
	event Withdrew(uint256 weiAmount);
	event Refund(address indexed holder, uint256 amount);
	
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
		token = StrayToken(_token);
	}
	
	function enableTeamWithdraw() onlyOwner public {
		require(fundState == FundState.NotReady);
		fundState = FundState.TeamWithdraw;
		emit TeamWithdrawEnabled();
		
		budgetPlans.length++;
		BudgetPlan storage plan = budgetPlans[0];
		
	    plan.proposalId = NON_UINT256;
	    plan.budgetInWei = address(this).balance.mul(FIRST_WITHDRAW_RATE).div(100);
	    plan.withdrawnWei = 0;
	    plan.startTime = now;
	    (plan.endTime, plan.officalVotingTime) = _budgetEndAndOfficalVotingTime(now);
	    
	    currentBudgetPlanId = 0;
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
	
	function isNextBudgetPlanMade() inWithdrawState public view returns (bool) {
	    return currentBudgetPlanId != budgetPlans.length - 1;
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
	                _makeBudgetPlan(p, id);
	            }
	        }
	    }
	}
	
	function newTapProposalFromTokenHolders(uint256 _targetWei)
	    onlyTokenHolders 
	    inWithdrawState 
	    public
	{
	    // Sponsor cannot be stuff of company.
	    require(msg.sender != owner);
	    require(msg.sender != teamWallet);
	    
	    // Check the last result.
	    tryFinializeLastProposal();
	    require(fundState == FundState.TeamWithdraw);
	    
	    // Proposal is disable when the budget plan has been made.
	    require(!isNextBudgetPlanMade());
	    
	    // Proposal voting is exclusive.
	    require(!isThereAnOnGoingProposal());
	    
	    // Validation of time restriction.
	    BudgetPlan storage b = budgetPlans[currentBudgetPlanId];
		require(now <= b.officalVotingTime && now >= b.startTime);
		
		// Sponsor is not allowed to propose repeatly in the same budget period.
		require(!_hasProposed(msg.sender, ProposalType.TapFromTokenHolder));
		
		// The minimum wei requirement.
		require(_targetWei >= MIN_WITHDRAW_WEI);
		
		// Create a new proposal.
		_newTapProposal(ProposalType.TapFromTokenHolder, _targetWei);
	}
	
	function newTapProposalFromCompany(uint256 _targetWei)
	    onlyOwner 
	    inWithdrawState 
	    public
	{
	    // Check the last result.
	    tryFinializeLastProposal();
	    require(fundState == FundState.TeamWithdraw);
	    
	    // Proposal is disable when the budget plan has been made.
	    require(!isNextBudgetPlanMade());
	    
	    // Proposal voting is exclusive.
	    require(!isThereAnOnGoingProposal());
	    
	    // Validation of time restriction.
	    BudgetPlan storage b = budgetPlans[currentBudgetPlanId];
		require(now >= b.officalVotingTime);
		
		// The minimum wei requirement.
		require(_targetWei >= MIN_WITHDRAW_WEI);
		
		// Create a new proposal.
		_newTapProposal(ProposalType.TapFromCompany, _targetWei);
	}
	
	function newRefundProposal() onlyTokenHolders inWithdrawState public {
	    // Check the last result.
	    tryFinializeLastProposal();
	    require(fundState == FundState.TeamWithdraw);
	    
	    // Proposal voting is exclusive.
	    require(!isThereAnOnGoingProposal());
	    
	    // Sponsor is not allowed to propose repeatly in the same budget period.
	    require(!_hasProposed(msg.sender, ProposalType.Refund));
	    
	    // Create proposals.
		uint256 id = proposals.length++;
		Proposal storage p = proposals[id];
		p.proposalType = ProposalType.Refund;
		p.sponsor = msg.sender;
		p.openingTime = now;
		p.closingTime = now + VOTING_DURATION;
		p.isPassed = false;
		p.isFinialized = false;
		
		// Signal the event.
		emit RefundProposalAdded(p.openingTime, p.closingTime);
	}
	
	function voteForTap(bool supportsProposal)
	    onlyTokenHolders
	    inWithdrawState
	    public
	{
	    // Check the last result.
	    tryFinializeLastProposal();
		require(isThereAnOnGoingProposal());
		
		// Check the ongoing proposal's type and reject the voted address.
		Proposal storage p = proposals[proposals.length - 1];
		require(p.proposalType != ProposalType.Refund);
		require(true != p.voted[msg.sender]);
		
		// Record the vote.
		uint256 voteId = p.votes.length++;
		p.votes[voteId].tokeHolder = msg.sender;
		p.votes[voteId].inSupport = supportsProposal;
		p.voted[msg.sender] = true;
		
		// Signal the event.
		emit TapVoted(msg.sender, supportsProposal);
	}
	
	function voteForRefund(bool supportsProposal)
	    onlyTokenHolders
	    inWithdrawState
	    public
	{
	    // Check the last result.
	    tryFinializeLastProposal();
		require(isThereAnOnGoingProposal());
		
		// Check the ongoing proposal's type and reject the voted address.
		Proposal storage p = proposals[proposals.length - 1];
		require(p.proposalType == ProposalType.Refund);
		require(true != p.voted[msg.sender]);
		
		// Record the vote.
		uint256 voteId = p.votes.length++;
		p.votes[voteId].tokeHolder = msg.sender;
		p.votes[voteId].inSupport = supportsProposal;
		p.voted[msg.sender] = true;
		
		// Signal the event.
		emit RefundVoted(msg.sender, supportsProposal);
	}
	
	function withdraw(uint256 _amount) onlyOwner inWithdrawState public {
	    // Check the last result.
	    tryFinializeLastProposal();
	    require(fundState == FundState.TeamWithdraw);
	    
	    // Try to update the budget plans.
	    BudgetPlan storage currentPlan = budgetPlans[currentBudgetPlanId];
	    if (now > currentPlan.endTime) {
	        require(isNextBudgetPlanMade());
	        ++currentBudgetPlanId;
	    }
	    
	    // Withdraw the weis.
	    _withdraw(_amount);
	}
	
	function withdrawOnNoAvailablePlan() onlyOwner inWithdrawState public {
	    require(address(this).balance >= MIN_WITHDRAW_WEI);
	    
	    // Check the last result.
	    tryFinializeLastProposal();
	    require(fundState == FundState.TeamWithdraw);
	    
	    // Check if someone proposed a tap voting.
	    require(!_isThereAnOnGoingTapProposal());
	    
	    // There is no passed budget plan.
	    require(!isNextBudgetPlanMade());
	    
	    // Validate the time.
	    BudgetPlan storage currentPlan = budgetPlans[currentBudgetPlanId];
	    require(now > currentPlan.endTime);
	    
	    // Create plan.
	    uint256 planId = budgetPlans.length++;
	    BudgetPlan storage plan = budgetPlans[planId];
	    plan.proposalId = NON_UINT256;
	    plan.budgetInWei = MIN_WITHDRAW_WEI;
	    plan.withdrawnWei = MIN_WITHDRAW_WEI;
	    plan.startTime = now;
	    (plan.endTime, plan.officalVotingTime) = _budgetEndAndOfficalVotingTime(now);
	    
	    ++currentBudgetPlanId;
	    
	    // Withdraw the weis.
	    _withdraw(MIN_WITHDRAW_WEI);
	}
	
	function refund() onlyTokenHolders public {
	    // Check the state.
		require(fundState == FundState.Refunding);
		
		// Validate the time.
		require(now > refundLockDate + REFUND_LOCK_DURATION);
		
		// Calculate the transfering wei and burn all the token of the refunder.
		uint256 amount = address(this).balance.mul(token.balanceOf(msg.sender)).div(token.totalSupply());
		token.burnAll(msg.sender);
		
		// Signal the event.
		msg.sender.transfer(amount);
	}
	
	function _withdraw(uint256 _amount) internal {
	    BudgetPlan storage plan = budgetPlans[currentBudgetPlanId];
	    
	    // Validate the time.
	    require(now <= plan.endTime);
	    
	    // Check the remaining wei.
	    require(_amount + plan.withdrawnWei <= plan.budgetInWei);
	       
	    // Transfer the wei.
	    plan.withdrawnWei += _amount;
	    teamWallet.transfer(_amount);
	    
	    // Signal the event.
	    emit Withdrew(_amount);
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
			, p.targetWei
			, p.isPassed);
		
		return p.isPassed;
	}
	
	function _enableRefunds() inWithdrawState internal {
	    fundState = FundState.Refunding;
		emit RefundsEnabled();
		
		refundLockDate = now;
	}
	
	function _makeBudgetPlan(Proposal storage p, uint256 proposalId) 
	    internal
	{
	    require(p.proposalType != ProposalType.Refund);
	    require(p.isFinialized);
	    require(p.isPassed);
	    require(!isNextBudgetPlanMade());
	    
	    uint256 planId = budgetPlans.length++;
	    BudgetPlan storage plan = budgetPlans[planId];
	    plan.proposalId = proposalId;
	    plan.budgetInWei = p.targetWei;
	    plan.withdrawnWei = 0;
	    
	    if (now > budgetPlans[currentBudgetPlanId].endTime) {
	        plan.startTime = now;
	        (plan.endTime, plan.officalVotingTime) = _budgetEndAndOfficalVotingTime(now);
	        ++currentBudgetPlanId;
	    } else {
	        (plan.startTime, plan.endTime, plan.officalVotingTime) = _nextBudgetStartAndEndAndOfficalVotingTime();
	    }
	}
	
	function _newTapProposal(ProposalType _proposalType, uint256 _targetWei) internal {
	    uint256 id = proposals.length++;
        Proposal storage p = proposals[id];
        p.proposalType = _proposalType;
		p.sponsor = msg.sender;
		p.openingTime = now;
		p.closingTime = now + 1 weeks;
		p.isPassed = false;
		p.isFinialized = false;
		p.targetWei = _targetWei;
		
		emit TapProposalAdded(p.openingTime
			, p.closingTime
			, p.targetWei);
	}
	
	function _isThereAnOnGoingTapProposal() internal view returns (bool) {
	    if (proposals.length == 0) {
	        return false;
	    } else {
	        Proposal storage p = proposals[proposals.length - 1];
	        return p.proposalType != ProposalType.Refund  && now < p.closingTime;
	    }
	}
	
	function _budgetEndAndOfficalVotingTime(uint256 _startTime)
	    view
	    internal
	    returns (uint256, uint256)
	{
	    // Decompose to datetime.
        uint32 year;
        uint8 month;
        uint8 mday;
        uint8 hour;
        uint8 minute;
        uint8 second;
        (year, month, mday, hour, minute, second) = _startTime.toGMT();
        
        // Calculate the next end time of budget period.
        month = ((month - 1) / 3 + 1) * 3 + 1;
        if (month > 12) {
            month -= 12;
            year += 1;
        }
        
        mday = 1;
        hour = 0;
        minute = 0;
        second = 0;
        
        uint256 end = DateTimeUtility.toUnixtime(year, month, mday, hour, minute, second) - 1;
     
         // Calculate the offical voting time of the budget period.
        mday = OFFICAL_VOTING_DAY_OF_MONTH;
        hour = 0;
        minute = 0;
        second = 0;
        
        uint256 votingTime = DateTimeUtility.toUnixtime(year, month, mday, hour, minute, second);
        
        return (end, votingTime);
	}
    
    function _nextBudgetStartAndEndAndOfficalVotingTime() 
        view 
        internal 
        returns (uint256, uint256, uint256)
    {
        // Decompose to datetime.
        uint32 year;
        uint8 month;
        uint8 mday;
        uint8 hour;
        uint8 minute;
        uint8 second;
        (year, month, mday, hour, minute, second) = now.toGMT();
        
        // Calculate the next start time of budget period. (1/1, 4/1, 7/1, 10/1)
        month = ((month - 1) / 3 + 1) * 3 + 1;
        if (month > 12) {
            month -= 12;
            year += 1;
        }
        
        mday = 1;
        hour = 0;
        minute = 0;
        second = 0;
        
        uint256 start = DateTimeUtility.toUnixtime(year, month, mday, hour, minute, second);
        
        // Calculate the next end time of budget period.
        month = ((month - 1) / 3 + 1) * 3 + 1;
        if (month > 12) {
            month -= 12;
            year += 1;
        }
        
        uint256 end = DateTimeUtility.toUnixtime(year, month, mday, hour, minute, second) - 1;
        
        // Calculate the offical voting time of the budget period.
        mday = OFFICAL_VOTING_DAY_OF_MONTH;
        hour = 0;
        minute = 0;
        second = 0;
        
        uint256 votingTime = DateTimeUtility.toUnixtime(year, month, mday, hour, minute, second);
        
        return (start, end, votingTime);
    } 
    
    function _hasProposed(address _sponsor, ProposalType proposalType)
        internal
        view
        returns (bool)
    {
        if (proposals.length == 0) {
            return false;
        } else {
            BudgetPlan storage b = budgetPlans[currentBudgetPlanId];
            for (uint256 i = proposals.length - 1; i != 0; --i) {
                Proposal storage p = proposals[i];
                if (p.openingTime < b.startTime) {
                    return false;
                } else  if (p.openingTime <= b.endTime 
                            && p.sponsor == _sponsor 
                            && p.proposalType == proposalType) {
                    return true;
                }
            }
            return false;
        }
    }
    
	function _processClosed() internal {
	    super._processClosed();
	    enableTeamWithdraw();
	}
}