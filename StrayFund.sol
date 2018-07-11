pragma solidity ^0.4.24;

import "./openzeppelin-solidity/contracts/math/SafeMath.sol";
import "./openzeppelin-solidity/contracts/ownership/Ownable.sol";
import "./DateTimeUtility.sol";
import "./StrayToken.sol";

/**
 * @title StrayFund
 * @dev The DAICO managed fund.
 */
contract StrayFund is Ownable {
	using SafeMath for uint256;
	using DateTimeUtility for uint256;
	
    // The fund state.
	enum State {
	    NotReady       // The fund is not ready for any operations.
	    , TeamWithdraw // The fund can be withdrawn and voting proposals.
	    , Refunding    // The fund only can be refund..
	    , Closed       // The fund is closed.
	}
	

	// @dev Proposal type for voting.
	enum ProposalType { 
	    Tap          // Tap proposal sponsored by token holder out of company.
	    , OfficalTap // Tap proposal sponsored by company.
	    , Refund     // Refund proposal.
	}
	
	// A special number indicates that no valid id.
	uint256 NON_UINT256 = (2 ** 256) - 1;
	
	// Data type represent a vote.
	struct Vote {
		address tokeHolder; // Voter address.
		bool inSupport;     // Support or not.
	}
	
	// Voting proposal.
	struct Proposal {              
	    ProposalType proposalType; // Proposal type.
	    address sponsor;           // Who proposed this vote.
	    uint256 openingTime;       // Opening time of the voting.
	    uint256 closingTime;       // Closing time of the voting.
	    Vote[] votes;              // All votes.
		mapping (address => bool) voted; // Prevent duplicate vote.
		bool isPassed;             // Final result.
		bool isFinialized;         // Proposal state.
		uint256 targetWei;         // Tap proposal target.
	}
	
	// Budget plan stands a budget period for the team to withdraw the funds.
	struct BudgetPlan {
	    uint256 proposalId;       // The tap proposal id.
	    uint256 budgetInWei;      // Budget in wei.
	    uint256 withdrawnWei;     // Withdrawn wei.
	    uint256 startTime;        // Start time of this budget plan. 
	    uint256 endTime;          // End time of this budget plan.
	    uint256 officalVotingTime; // The offical tap voting time in this period.
	}
	
	// Team wallet to receive the budget.
	address public teamWallet;
	
	// Fund state.
	State public state;
	
	// Stary Token.
	StrayToken public token;
	
	// Proposal history.
	Proposal[] public proposals;
	
	// Budget plan history.
	BudgetPlan[] public budgetPlans;
	
	// Current budget plan id.
	uint256 currentBudgetPlanId;
	
	// The mininum budget.
	uint256 public MIN_WITHDRAW_WEI = 1 ether;
	
	// The fist withdraw rate when the crowdsale was successed.
	uint256 public FIRST_WITHDRAW_RATE = 20;
	
	// The voting duration.
	//uint256 public VOTING_DURATION = 1 weeks;
	uint256 public VOTING_DURATION = 1 minutes;
	
	// Offical voting day of the last month of budget period. 
	uint8 public OFFICAL_VOTING_DAY_OF_MONTH = 23;
	
	// Refund lock duration.
	//uint256 public REFUND_LOCK_DURATION = 30 days;
	uint256 public REFUND_LOCK_DURATION = 30 seconds;
	
	// Refund lock date.
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
	    require(state == State.TeamWithdraw);
	    _;
	}
	
	/*
		constructor() public {
	    address _teamWallet = msg.sender;
	    StrayToken t = new StrayToken(0x14723a09acff6d2a60dcdf7aa4aff308fddc160c
	        , 0x4b0897b0513fdc7c541b6d9d7e929c4e5364d2db);
	    t.transfer(msg.sender, t.balanceOf(address(this)).mul(8).div(10));
	    t.transfer(0x583031d1113ad414f02576bd6afabfb302140225, t.balanceOf(address(this)));
	    t.setFundContract(address(this));
	    t.transferOwnership(msg.sender);
	    
	    address _token = address(t);

	}
	*/
	/**
	 * @param _teamWallet The wallet which receives the funds.
	 * @param _token Stray token address.
	 */
    constructor(address _teamWallet, address _token) public {
		require(_teamWallet != address(0));
		require(_token != address(0));
		
		teamWallet = _teamWallet;
		state = State.NotReady;
		token = StrayToken(_token);
	}
	
	/**
	 * @dev Enable the TeamWithdraw state.
	 */
	function enableTeamWithdraw() onlyOwner public {
		require(state == State.NotReady);
		state = State.TeamWithdraw;
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
	
	/**
	 * @dev Close the fund.
	 */
	function close() onlyOwner inWithdrawState public {
	    require(address(this).balance < MIN_WITHDRAW_WEI);
	    
		state = State.Closed;
		emit Closed();
		
		teamWallet.transfer(address(this).balance);
	}
	
	/**
	 * @dev Check if there is an ongoing proposal.
	 */
	function isThereAnOnGoingProposal() public view returns (bool) {
	    if (proposals.length == 0 || state != State.TeamWithdraw) {
	        return false;
	    } else {
	        Proposal storage p = proposals[proposals.length - 1];
	        return now < p.closingTime;
	    }
	}
	
	/**
	 * @dev Check if next budget period plan has been made.
	 */
	function isNextBudgetPlanMade() public view returns (bool) {
	    if (state != State.TeamWithdraw) {
	        return false;
	    } else {
	        return currentBudgetPlanId != budgetPlans.length - 1;
	    }
	}
	
	/**
	 * @dev Get number of proposals. 
	 */
	function numberOfProposals() public view returns (uint256) {
	    return proposals.length;
	}
	
	/**
	 * @dev Get number of budget plans. 
	 */
	function numberOfBudgetPlan() public view returns (uint256) {
	    return budgetPlans.length;
	}
	
	/**
	 * @dev Try to finialize the last proposal.
	 */
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
	
	/**
	 * @dev Create new tap proposal by address out of company.
	 * @param _targetWei The voting target.
	 */
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
	    require(state == State.TeamWithdraw);
	    
	    // Proposal is disable when the budget plan has been made.
	    require(!isNextBudgetPlanMade());
	    
	    // Proposal voting is exclusive.
	    require(!isThereAnOnGoingProposal());
	    
	    // Validation of time restriction.
	    BudgetPlan storage b = budgetPlans[currentBudgetPlanId];
		require(now <= b.officalVotingTime && now >= b.startTime);
		
		// Sponsor is not allowed to propose repeatly in the same budget period.
		require(!_hasProposed(msg.sender, ProposalType.Tap));
		
		// Create a new proposal.
		_newTapProposal(ProposalType.Tap, _targetWei);
	}
	
	/**
	 * @dev Create new tap proposal by company.
	 * @param _targetWei The voting target.
	 */
	function newTapProposalFromCompany(uint256 _targetWei)
	    onlyOwner 
	    inWithdrawState 
	    public
	{
	    // Check the last result.
	    tryFinializeLastProposal();
	    require(state == State.TeamWithdraw);
	    
	    // Proposal is disable when the budget plan has been made.
	    require(!isNextBudgetPlanMade());
	    
	    // Proposal voting is exclusive.
	    require(!isThereAnOnGoingProposal());
	    
	    // Validation of time restriction.
	    BudgetPlan storage b = budgetPlans[currentBudgetPlanId];
		require(now >= b.officalVotingTime);
		
		// Create a new proposal.
		_newTapProposal(ProposalType.OfficalTap, _targetWei);
	}
	
	/**
	 * @dev Create a refund proposal.
	 */
	function newRefundProposal() onlyTokenHolders inWithdrawState public {
	    // Check the last result.
	    tryFinializeLastProposal();
	    require(state == State.TeamWithdraw);
	    
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
	
	/**
	 * @dev Vote for a tap proposal.
	 * @param _supportsProposal True if the vote supports the proposal.
	 */
	function voteForTap(bool _supportsProposal)
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
		p.votes[voteId].inSupport = _supportsProposal;
		p.voted[msg.sender] = true;
		
		// Signal the event.
		emit TapVoted(msg.sender, _supportsProposal);
	}
	
	/**
	 * @dev Vote for a tap proposal.
	 * @param _supportsProposal True if the vote supports the proposal.
	 */
	function voteForRefund(bool _supportsProposal)
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
		p.votes[voteId].inSupport = _supportsProposal;
		p.voted[msg.sender] = true;
		
		// Signal the event.
		emit RefundVoted(msg.sender, _supportsProposal);
	}
	
	/**
	 * @dev Withdraw the wei to team wallet.
	 * @param _amount Withdraw wei.
	 */
	function withdraw(uint256 _amount) onlyOwner inWithdrawState public {
	    // Check the last result.
	    tryFinializeLastProposal();
	    require(state == State.TeamWithdraw);
	    
	    // Try to update the budget plans.
	    BudgetPlan storage currentPlan = budgetPlans[currentBudgetPlanId];
	    if (now > currentPlan.endTime) {
	        require(isNextBudgetPlanMade());
	        ++currentBudgetPlanId;
	    }
	    
	    // Withdraw the weis.
	    _withdraw(_amount);
	}
	
	/**
	 * @dev Withdraw when there is no budget plans.
	 */
	function withdrawOnNoAvailablePlan() onlyOwner inWithdrawState public {
	    require(address(this).balance >= MIN_WITHDRAW_WEI);
	    
	    // Check the last result.
	    tryFinializeLastProposal();
	    require(state == State.TeamWithdraw);
	    
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
	    plan.withdrawnWei = 0;
	    plan.startTime = now;
	    (plan.endTime, plan.officalVotingTime) = _budgetEndAndOfficalVotingTime(now);
	    
	    ++currentBudgetPlanId;
	    
	    // Withdraw the weis.
	    _withdraw(MIN_WITHDRAW_WEI);
	}
	
	/**
     * @dev Tokenholders can claim refunds here.
     */
	function claimRefund() onlyTokenHolders public {
	    // Check the state.
		require(state == State.Refunding);
		
		// Validate the time.
		require(now > refundLockDate + REFUND_LOCK_DURATION);
		
		// Calculate the transfering wei and burn all the token of the refunder.
		uint256 amount = address(this).balance.mul(token.balanceOf(msg.sender)).div(token.totalSupply());
		token.burnAll(msg.sender);
		
		// Signal the event.
		msg.sender.transfer(amount);
	}
	
	/**
     * @dev Receive the initial funds from crowdsale contract.
     */
	function receiveInitialFunds() payable public {
	    require(state == State.NotReady);
	}
	
	/**
     * @dev Fallback function to receive initial funds.
     */
	function () payable public {
	    receiveInitialFunds();
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
	    state = State.Refunding;
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
	    // The minimum wei requirement.
		require(_targetWei >= MIN_WITHDRAW_WEI && _targetWei <= address(this).balance);
	    
	    uint256 id = proposals.length++;
        Proposal storage p = proposals[id];
        p.proposalType = _proposalType;
		p.sponsor = msg.sender;
		p.openingTime = now;
		p.closingTime = now + VOTING_DURATION;
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
            for (uint256 i = proposals.length - 1;; --i) {
                Proposal storage p = proposals[i];
                if (p.openingTime < b.startTime) {
                    return false;
                } else if (p.openingTime <= b.endTime 
                            && p.sponsor == _sponsor 
                            && p.proposalType == proposalType
                            && !p.isPassed) {
                    return true;
                }
                
                if (i == 0)
                    break;
            }
            return false;
        }
    }
}