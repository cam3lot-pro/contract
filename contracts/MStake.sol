// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "./lib/SafeMath.sol";
import "./lib/SafeDecimalMath.sol";


contract MStake is AccessControl {
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeMath for uint256;
    using SafeDecimalMath for uint256;
    using SafeERC20 for IERC20;

    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER");
    bytes32 public constant UPDATE_PRICE_ROLE = keccak256("UPDATE_PRICE");

    address public BTC = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    bool public canUnStake = false;
    uint256 public efficientDuration = 7200;

    uint256 public percentBase = 10000;
    uint256 public feePercent;
    address public feeAddress;

    struct StakeHistoryItem {
        address token;
        uint256 amount;
        uint256 date;
        uint action; // stake 1,unstake 2
    }

    struct StakeInfoItem {
        address token;
        uint256 amount;
    }

    struct Price {
        uint256 price;
        uint256 updatetime;
    }

    mapping(address => Price) public price;

    mapping(address => StakeHistoryItem[]) public stakeHistory;
    mapping(address => mapping(address => uint256)) public stakeInfo;
    EnumerableSet.AddressSet private assets;
    EnumerableSet.AddressSet private users;

    constructor(address _feeAddress) {
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
        _grantRole(UPDATE_PRICE_ROLE, _msgSender());
        _grantRole(MANAGER_ROLE, _msgSender());
        require(_feeAddress != address(0), "invalid feeAddress");
        feeAddress = _feeAddress;
    }

    function setFeeAddress(address _feeAddress) external onlyRole(MANAGER_ROLE) {
        require(_feeAddress != address(0));
        feeAddress = _feeAddress;
    }

    function setFeePercent(uint256 _feePercent) external onlyRole(MANAGER_ROLE) {
        feePercent = _feePercent;
    }

    function setPriceEfficientDuration(uint256 duration) external onlyRole(MANAGER_ROLE) {
        efficientDuration = duration;
    }

    function updatePrice(address token, uint256 _price) external onlyRole(UPDATE_PRICE_ROLE) {
        price[token].price = _price;
        price[token].updatetime = block.timestamp;
    }

    function batchUpdatePrice(address[] memory tokens, uint256[] memory _prices) external onlyRole(UPDATE_PRICE_ROLE) {
        require(tokens.length == _prices.length, "tokens length inconsistent");
        require(tokens.length == assets.length(), "all token prices must be updated");

        for (uint256 i = 0; i < tokens.length; i ++) {
            price[tokens[i]].price = _prices[i];
            price[tokens[i]].updatetime = block.timestamp;
        }
    }

    function getUsersLength() view public returns (uint256) {
        return users.length();
    }

    function getUsers(uint256 offset, uint256 limit) view public returns (uint256 total, address[] memory _users) {
        total = users.length();

        if (total == 0 || offset >= total) {
            return (total, new address[](0));
        }

        uint256 endExclusive = Math.min(total, offset + limit);
        _users = new address[](endExclusive - offset);

        for (uint256 i = offset; i < endExclusive; i++) {
            _users[i - offset] = users.at(i);
        }
    }

    function getStakeHistory(address user) view external returns (StakeHistoryItem[] memory) {
        return stakeHistory[user];
    }

    function getStakeInfo(address user) view external returns (StakeInfoItem[] memory) {
        address[] memory assetsList = getAssets();
        StakeInfoItem[] memory result = new StakeInfoItem[](assetsList.length);
        for (uint256 i = 0; i < assetsList.length; i ++) {
            result[i] = StakeInfoItem({
                token: assetsList[i],
                amount: stakeInfo[user][assetsList[i]]
            });
        }

        return result;
    }

    function getStakeValue(address user) view public returns (uint256 value) {
        address[] memory assetsList = getAssets();
        value = 0;
        for (uint256 i = 0; i < assetsList.length; i ++) {
            address token = assetsList[i];
            require(priceIsValid(token), "invalid price");
            uint256 _value = stakeInfo[user][token].multiplyDecimal(price[token].price);
            value = value.add(_value);
        }
    }

    function batchGetStakeValue(uint256 offset, uint256 limit) external view returns (uint256 total, address[] memory _users, uint256[] memory values) {
        total = users.length();

        if (total == 0 || offset >= total) {
            return (total, new address[](0), new uint256[](0));
        }

        uint256 endExclusive = Math.min(total, offset + limit);
        _users = new address[](endExclusive - offset);
        values = new uint256[](endExclusive - offset);

        for (uint256 i = offset; i < endExclusive; i++) {
            _users[i - offset] = users.at(i);
            values[i - offset] = getStakeValue(users.at(i));
        }
    }

    function priceIsValid(address token) view public returns (bool) {
        return price[token].updatetime.add(efficientDuration) > block.timestamp;
    }

    function setCanUnStake(bool _canUnStake) external onlyRole(MANAGER_ROLE) {
        canUnStake = _canUnStake;
    }

    function addAsset(IERC20 token) external onlyRole(MANAGER_ROLE) {
        assets.add(address(token));
    }

    function removeAsset(IERC20 token) external onlyRole(MANAGER_ROLE) {
        assets.remove(address(token));
    }

    function getAssets() view public returns (address[] memory) {
        return assets.values();
    }

    function getAssetsLength() view public returns (uint256) {
        return assets.length();
    }

    function isValidAsset(address token) view public returns (bool) {
        return assets.contains(token);
    }

    function stakeBTC() payable external {
        require(isValidAsset(BTC), "invalid asset");
        require(msg.value > 0, "amount must be greater than 0");
        require(feeAddress != address(0), "invalid fee address");
        users.add(msg.sender);

        uint256 fee = msg.value.mul(feePercent).div(percentBase);
        (bool sent, bytes memory data) = payable(feeAddress).call{value: fee}("");
        require(sent, "Failed to receive");

        uint256 amount = msg.value.sub(fee);
        stakeInfo[msg.sender][BTC] = stakeInfo[msg.sender][BTC].add(amount);
        stakeHistory[msg.sender].push(StakeHistoryItem({
            token: BTC,
            amount: amount,
            date: block.timestamp,
            action: 1
        }));
    }

    function stake(IERC20 token, uint256 amount) external {
        require(isValidAsset(address(token)), "invalid asset");
        require(amount > 0, "amount must be greater than 0");
        require(feeAddress != address(0), "invalid fee address");
        users.add(msg.sender);

        uint256 fee = amount.mul(feePercent).div(percentBase);
        token.safeTransferFrom(msg.sender, feeAddress, fee);

        amount = amount.sub(fee);
        token.safeTransferFrom(msg.sender, address(this), amount);
        stakeInfo[msg.sender][address(token)] = stakeInfo[msg.sender][address(token)].add(amount);
        stakeHistory[msg.sender].push(StakeHistoryItem({
            token: address(token),
            amount: amount,
            date: block.timestamp,
            action: 1
        }));
    }

    function unstake(IERC20 token, uint256 amount) external {
        require(canUnStake, "can not unstake");
        require(stakeInfo[msg.sender][address(token)] >= amount, "the number of unstakes exceeds the balance");
        stakeInfo[msg.sender][address(token)] = stakeInfo[msg.sender][address(token)].sub(amount);
        token.safeTransfer(msg.sender, amount);
        stakeHistory[msg.sender].push(StakeHistoryItem({
            token: address(token),
            amount: amount,
            date: block.timestamp,
            action: 2
        }));
    }

    function unstakeBTC(uint256 amount) external {
        require(canUnStake, "can not unstake");
        require(stakeInfo[msg.sender][BTC] >= amount, "the number of unstakes exceeds the balance");
        stakeInfo[msg.sender][BTC] = stakeInfo[msg.sender][BTC].sub(amount);
        (bool sent, bytes memory data) = payable(msg.sender).call{value: amount}("");
        require(sent, "Failed to send BTC");
        stakeHistory[msg.sender].push(StakeHistoryItem({
            token: BTC,
            amount: amount,
            date: block.timestamp,
            action: 2
        }));
    }
}
