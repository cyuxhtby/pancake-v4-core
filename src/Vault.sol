// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2024 PancakeSwap
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IVault, IVaultToken} from "./interfaces/IVault.sol";
import {PoolId, PoolIdLibrary} from "./types/PoolId.sol"; // The poolId is the hashed pool key
import {PoolKey} from "./types/PoolKey.sol"; // Holds config and identification data for the pool 
import {SettlementGuard} from "./libraries/SettlementGuard.sol"; // This manages the locks for flash accounting
import {Currency, CurrencyLibrary} from "./types/Currency.sol";
// Distinction:
// BalanceDelta: Represents the net change in balances for two currencies (amount0 and amount1) at the app level.
// Currency Delta: Represents changes for a specific currency for a settler in the vault.
import {BalanceDelta} from "./types/BalanceDelta.sol"; // Represents net balance changes for pool operations, tracking changes for two currencies for amount0 and amount1 as single signed int256
import {ILockCallback} from "./interfaces/ILockCallback.sol"; // Assuming its a callback for once flash accouting settles ? TODO: look into callback
// Is this distinction at the app level or at the pool level? 
import {SafeCast} from "./libraries/SafeCast.sol";
import {VaultReserves} from "./libraries/VaultReserves.sol";
import {VaultToken} from "./VaultToken.sol";

contract Vault is IVault, VaultToken, Ownable {
    using SafeCast for *;
    using PoolIdLibrary for PoolKey; // Gets poolId for given key 
    using CurrencyLibrary for Currency; // holding and transfering native and tokens lib
    using VaultReserves for Currency; // get and set vault reserves lib 

    mapping(address => bool) public override isAppRegistered; // Registered pool managers (AMM designs)

    /// @dev keep track of each app's reserves
    mapping(address => mapping(Currency currency => uint256 reserve)) public reservesOfApp; // The reserves of a given AMM design? 

    /// @notice only registered app is allowed to perform accounting
    modifier onlyRegisteredApp() {
        if (!isAppRegistered[msg.sender]) revert AppUnregistered();

        _;
    }

    /// @notice revert if no locker is set
    modifier isLocked() {
        if (SettlementGuard.getLocker() == address(0)) revert NoLocker();
        _;
    }

    /// @inheritdoc IVault
    // Permissioned AMM design registration
    function registerApp(address app) external override onlyOwner {
        isAppRegistered[app] = true;

        emit AppRegistered(app);
    }

    /// @inheritdoc IVault
    function getLocker() external view override returns (address) {
        return SettlementGuard.getLocker();
    }

    /// @inheritdoc IVault
    function getUnsettledDeltasCount() external view override returns (uint256) {
        return SettlementGuard.getUnsettledDeltasCount();
    }

    /// @inheritdoc IVault
    function currencyDelta(address settler, Currency currency) external view override returns (int256) {
        return SettlementGuard.getCurrencyDelta(settler, currency);
    }

    /// @dev interaction must start from lock
    /// @inheritdoc IVault
    // TODO: Further look into this locking mechanism
    function lock(bytes calldata data) external override returns (bytes memory result) {
        /// @dev only one locker at a time
        SettlementGuard.setLocker(msg.sender);

        result = ILockCallback(msg.sender).lockAcquired(data);
        /// @notice the caller can do anything in this callback as long as all deltas are offset after this
        if (SettlementGuard.getUnsettledDeltasCount() != 0) revert CurrencyNotSettled();

        /// @dev release the lock
        SettlementGuard.setLocker(address(0));
    }

    /// @inheritdoc IVault
    // Called by a pool manager to store intermediate deltas between settlments
    function accountAppBalanceDelta(PoolKey memory key, BalanceDelta delta, address settler)
        external
        override
        isLocked
        onlyRegisteredApp
    {
        // extract amount changes for both currencies
        int128 delta0 = delta.amount0();
        int128 delta1 = delta.amount1();

        // keep track of the balance on app level
        _accountDeltaForApp(msg.sender, key.currency0, delta0);
        _accountDeltaForApp(msg.sender, key.currency1, delta1);

        // keep track of the balance on vault level
        SettlementGuard.accountDelta(settler, key.currency0, delta0);
        SettlementGuard.accountDelta(settler, key.currency1, delta1);
    }

    /// @inheritdoc IVault
    // Most delta update calls seem to be pool specific
    // I have yet to find a call that is currency specific 
    function accountAppBalanceDelta(Currency currency, int128 delta, address settler)
        external
        override
        isLocked
        onlyRegisteredApp
    {
        _accountDeltaForApp(msg.sender, currency, delta);
        SettlementGuard.accountDelta(settler, currency, delta);
    }

    /// @inheritdoc IVault
    // Transfers assets out of vault
    function take(Currency currency, address to, uint256 amount) external override isLocked {
        unchecked {
            SettlementGuard.accountDelta(msg.sender, currency, -(amount.toInt128()));
            currency.transfer(to, amount);
        }
    }

    /// @inheritdoc IVault
    // Mints LP token
    function mint(address to, Currency currency, uint256 amount) external override isLocked {
        unchecked {
            SettlementGuard.accountDelta(msg.sender, currency, -(amount.toInt128()));
            _mint(to, currency, amount);
        }
    }


    // So anybody can synce the reserves of vault at any point ? 
    function sync(Currency currency) public returns (uint256 balance) {
        balance = currency.balanceOfSelf();
        currency.setVaultReserves(balance);
    }

    /// @inheritdoc IVault
    function settle(Currency currency) external payable override isLocked returns (uint256 paid) {
        if (!currency.isNative()) {
            if (msg.value > 0) revert SettleNonNativeCurrencyWithValue();
            uint256 reservesBefore = currency.getVaultReserves();
            uint256 reservesNow = sync(currency);
            paid = reservesNow - reservesBefore;
        } else {
            paid = msg.value;
        }

        SettlementGuard.accountDelta(msg.sender, currency, paid.toInt128());
    }

    /// @inheritdoc IVault
    // Burn LP token
    function burn(address from, Currency currency, uint256 amount) external override isLocked {
        SettlementGuard.accountDelta(msg.sender, currency, amount.toInt128());
        _burnFrom(from, currency, amount);
    }

    /// @inheritdoc IVault
    // Seems to rely on the app or pool manager to ensure proper checks are in place
    function collectFee(Currency currency, uint256 amount, address recipient) external onlyRegisteredApp {
        reservesOfApp[msg.sender][currency] -= amount;
        currency.transfer(recipient, amount);
    }

    /// @inheritdoc IVault
    function reservesOfVault(Currency currency) external view returns (uint256 amount) {
        return currency.getVaultReserves();
    }

    function _accountDeltaForApp(address app, Currency currency, int128 delta) internal {
        if (delta == 0) return;

        if (delta >= 0) {
            /// @dev arithmetic underflow make sure trader can't withdraw too much from app
            reservesOfApp[app][currency] -= uint128(delta);
        } else {
            /// @dev arithmetic overflow make sure trader won't deposit too much into app
            reservesOfApp[app][currency] += uint128(-delta);
        }
    }
}
