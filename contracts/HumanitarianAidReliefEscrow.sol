// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract HumanitarianAidReliefEscrow {
    enum Role {
        None,
        Donor,
        ReliefAgency,
        Arbiter
    }

    enum MissionStatus {
        Pending,
        In_Transit,
        Delivered,
        Disputed,
        Resolved
    }

    struct User {
        string name;
        Role role;
        address wallet;
        uint256 reputation;
        bool registered;
    }

    struct Pledge {
        address agency;
        uint256 amount;
    }

    struct Mission {
        uint256 id;
        string category;
        string region;
        uint256 maxBudget;
        address donor;
        address selectedAgency;
        uint256 selectedPledge;
        uint256 escrowedAmount;
        MissionStatus status;
        bool escrowDeposited;
        bool deliveredByAgency;
        Pledge[] pledges;
    }

    address public immutable unArbiter;
    uint256 public missionCount;
    uint256 public collectedFees;

    mapping(address => User) public users;
    mapping(uint256 => Mission) private missions;

    event UserRegistered(address indexed user, string name, Role role);
    event MissionPosted(
        uint256 indexed missionId,
        address indexed donor,
        string category,
        string region,
        uint256 maxBudget
    );
    event Pledged(uint256 indexed missionId, address indexed agency, uint256 amount);
    event MissionFunded(uint256 indexed missionId, address indexed agency, uint256 amount);
    event DeliveredMarked(uint256 indexed missionId, address indexed agency);
    event DeliveryApproved(
        uint256 indexed missionId,
        address indexed donor,
        address indexed agency,
        uint256 payout,
        uint256 fee
    );
    event MissionDisputed(uint256 indexed missionId, address indexed donor);
    event DisputeResolved(
        uint256 indexed missionId,
        bool agencyFault,
        uint256 donorRefund,
        uint256 agencyPayout,
        uint256 fee
    );
    event FeesWithdrawn(address indexed arbiter, uint256 amount);

    modifier onlyRegistered() {
        require(users[msg.sender].registered, "User not registered");
        _;
    }

    modifier onlyDonor() {
        require(users[msg.sender].registered, "User not registered");
        require(users[msg.sender].role == Role.Donor, "Only donor allowed");
        _;
    }

    modifier onlyAgency() {
        require(users[msg.sender].registered, "User not registered");
        require(users[msg.sender].role == Role.ReliefAgency, "Only relief agency allowed");
        _;
    }

    modifier onlyArbiter() {
        require(msg.sender == unArbiter, "Only arbiter allowed");
        _;
    }

    modifier validMission(uint256 missionId) {
        require(missionId < missionCount, "Invalid mission id");
        _;
    }

    constructor(string memory arbiterName) {
        unArbiter = msg.sender;
        users[msg.sender] = User({
            name: arbiterName,
            role: Role.Arbiter,
            wallet: msg.sender,
            reputation: 0,
            registered: true
        });
        emit UserRegistered(msg.sender, arbiterName, Role.Arbiter);
    }

    function register(string memory _name, Role _role) external {
        require(!users[msg.sender].registered, "Wallet already registered");
        require(bytes(_name).length > 0, "Name required");
        require(_role == Role.Donor || _role == Role.ReliefAgency, "Invalid role");

        uint256 startingReputation = 0;
        if (_role == Role.ReliefAgency) {
            startingReputation = 100;
        }

        users[msg.sender] = User({
            name: _name,
            role: _role,
            wallet: msg.sender,
            reputation: startingReputation,
            registered: true
        });

        emit UserRegistered(msg.sender, _name, _role);
    }

    function postMission(string memory _category, string memory _region, uint256 _maxBudget) external onlyDonor {
        require(bytes(_category).length > 0, "Category required");
        require(bytes(_region).length > 0, "Region required");
        require(_maxBudget > 0, "Max budget must be > 0");

        Mission storage m = missions[missionCount];
        m.id = missionCount;
        m.category = _category;
        m.region = _region;
        m.maxBudget = _maxBudget;
        m.donor = msg.sender;
        m.selectedAgency = address(0);
        m.selectedPledge = 0;
        m.escrowedAmount = 0;
        m.status = MissionStatus.Pending;
        m.escrowDeposited = false;
        m.deliveredByAgency = false;

        emit MissionPosted(missionCount, msg.sender, _category, _region, _maxBudget);
        missionCount++;
    }

    function pledgeToMission(uint256 missionId, uint256 _amount)
        external
        onlyAgency
        validMission(missionId)
    {
        Mission storage m = missions[missionId];

        require(m.status == MissionStatus.Pending, "Mission not pending");
        require(_amount > 0, "Amount must be > 0");
        require(_amount <= m.maxBudget, "Pledge exceeds max budget");
        require(users[msg.sender].reputation >= 40, "Reputation below 40");

        for (uint256 i = 0; i < m.pledges.length; i++) {
            require(m.pledges[i].agency != msg.sender, "Agency already pledged");
        }

        m.pledges.push(Pledge({ agency: msg.sender, amount: _amount }));
        emit Pledged(missionId, msg.sender, _amount);
    }

    function fundMission(uint256 missionId, uint256 pledgeIndex)
        external
        payable
        onlyDonor
        validMission(missionId)
    {
        Mission storage m = missions[missionId];

        require(msg.sender == m.donor, "Not mission donor");
        require(m.status == MissionStatus.Pending, "Mission not pending");
        require(!m.escrowDeposited, "Escrow already funded");
        require(pledgeIndex < m.pledges.length, "Invalid pledge index");

        Pledge storage p = m.pledges[pledgeIndex];
        require(p.agency != address(0), "Invalid agency pledge");

        if (msg.value < p.amount) {
            revert("Insufficient escrow amount");
        }

        uint256 excess = msg.value - p.amount;

        // Effects before interactions
        m.selectedAgency = p.agency;
        m.selectedPledge = p.amount;
        m.escrowedAmount = p.amount;
        m.escrowDeposited = true;
        m.deliveredByAgency = false;
        m.status = MissionStatus.In_Transit;

        if (excess > 0) {
            _safeTransfer(payable(msg.sender), excess, "Refund failed");
        }

        emit MissionFunded(missionId, p.agency, p.amount);
    }

    function markDelivered(uint256 missionId)
        external
        onlyAgency
        validMission(missionId)
    {
        Mission storage m = missions[missionId];

        require(msg.sender == m.selectedAgency, "Not selected agency");
        require(m.status == MissionStatus.In_Transit, "Mission not in transit");
        require(m.escrowDeposited, "Escrow not funded");

        m.deliveredByAgency = true;
        emit DeliveredMarked(missionId, msg.sender);
    }

    function approveDelivery(uint256 missionId)
        external
        onlyDonor
        validMission(missionId)
    {
        Mission storage m = missions[missionId];

        require(msg.sender == m.donor, "Not mission donor");
        require(m.status == MissionStatus.In_Transit, "Mission not in transit");
        require(m.deliveredByAgency, "Agency has not marked delivered");
        require(m.escrowDeposited, "Escrow not funded");

        uint256 amount = m.escrowedAmount;
        uint256 fee = _calculateFee(amount);
        uint256 payout = amount - fee;

        // Effects before interactions
        collectedFees += fee;
        m.escrowDeposited = false;
        m.escrowedAmount = 0;
        m.status = MissionStatus.Delivered;
        users[m.selectedAgency].reputation += 15;

        _safeTransfer(payable(m.selectedAgency), payout, "Agency payout failed");
        emit DeliveryApproved(missionId, msg.sender, m.selectedAgency, payout, fee);
    }

    function raiseDispute(uint256 missionId)
        external
        onlyDonor
        validMission(missionId)
    {
        Mission storage m = missions[missionId];

        require(msg.sender == m.donor, "Not mission donor");
        require(m.status == MissionStatus.In_Transit, "Dispute allowed only in transit");
        require(m.deliveredByAgency, "Agency has not marked delivered");
        require(m.escrowDeposited, "No escrow available");

        m.status = MissionStatus.Disputed;
        emit MissionDisputed(missionId, msg.sender);
    }

    function resolveDispute(uint256 missionId, bool agencyFault)
        external
        onlyArbiter
        validMission(missionId)
    {
        Mission storage m = missions[missionId];

        require(m.status == MissionStatus.Disputed, "Mission not disputed");
        require(m.escrowDeposited, "No escrow available");

        uint256 donorRefund = 0;
        uint256 agencyPayout = 0;
        uint256 fee = 0;
        uint256 amount = m.escrowedAmount;

        if (agencyFault) {
            donorRefund = amount;

            // Effects before interaction
            if (users[m.selectedAgency].reputation >= 30) {
                users[m.selectedAgency].reputation -= 30;
            } else {
                users[m.selectedAgency].reputation = 0;
            }
            m.escrowDeposited = false;
            m.escrowedAmount = 0;
            m.status = MissionStatus.Resolved;

            _safeTransfer(payable(m.donor), donorRefund, "Refund to donor failed");
        } else {
            fee = _calculateFee(amount);
            agencyPayout = amount - fee;

            // Effects before interaction
            collectedFees += fee;
            m.escrowDeposited = false;
            m.escrowedAmount = 0;
            m.status = MissionStatus.Resolved;

            _safeTransfer(payable(m.selectedAgency), agencyPayout, "Agency payout failed");
        }

        emit DisputeResolved(missionId, agencyFault, donorRefund, agencyPayout, fee);
    }

    function withdrawFees(uint256 amount) external onlyArbiter {
        require(amount > 0, "Amount must be > 0");
        require(amount <= collectedFees, "Not enough fees");

        collectedFees -= amount;
        _safeTransfer(payable(msg.sender), amount, "Fee withdrawal failed");
        emit FeesWithdrawn(msg.sender, amount);
    }

    function getMission(uint256 missionId)
        external
        view
        validMission(missionId)
        returns (
            uint256 id,
            string memory category,
            string memory region,
            uint256 maxBudget,
            address donor,
            address selectedAgency,
            uint256 selectedPledge,
            uint256 escrowedAmount,
            MissionStatus status,
            bool escrowDeposited,
            bool deliveredByAgency,
            uint256 pledgeCount
        )
    {
        Mission storage m = missions[missionId];
        return (
            m.id,
            m.category,
            m.region,
            m.maxBudget,
            m.donor,
            m.selectedAgency,
            m.selectedPledge,
            m.escrowedAmount,
            m.status,
            m.escrowDeposited,
            m.deliveredByAgency,
            m.pledges.length
        );
    }

    function getPledge(uint256 missionId, uint256 pledgeIndex)
        external
        view
        validMission(missionId)
        returns (address agency, uint256 amount)
    {
        Mission storage m = missions[missionId];
        require(pledgeIndex < m.pledges.length, "Invalid pledge index");

        Pledge storage p = m.pledges[pledgeIndex];
        return (p.agency, p.amount);
    }

    function _calculateFee(uint256 amount) internal pure returns (uint256) {
        if (amount < 2 ether) {
            return (amount * 2) / 100;
        }
        return (amount * 1) / 100;
    }

    function _safeTransfer(address payable recipient, uint256 amount, string memory errorMessage) internal {
        (bool sent, ) = recipient.call{value: amount}("");
        require(sent, errorMessage);
    }
}
