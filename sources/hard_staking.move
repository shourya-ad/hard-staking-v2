module hard_staking_v2::hard_staking;

use hard_staking_v2::shourya_token::SHOURYA_TOKEN;
use sui::balance::{Balance, zero};
use sui::clock::Clock;
use sui::coin::{Self, Coin};
use sui::event;
use sui::table::{Table, new};
use sui::vec_set::{VecSet, empty};

// === Error Codes ===
const E_NOT_OWNER: u64 = 1000;
const E_NOT_ADMIN: u64 = 1001;
const E_INVALID_TOKEN_TYPE: u64 = 1003;
const E_INVALID_LOCK_PERIOD: u64 = 1004;
const E_STAKE_STILL_LOCKED: u64 = 1005;
const E_INVALID_STAKE_ID: u64 = 1006;
const E_STAKE_ALREADY_WITHDRAWN: u64 = 1007;
const E_MAX_ADMINS_REACHED: u64 = 1008;
const E_ADMIN_ALREADY_PRESENT: u64 = 1009;
const E_ADMIN_CANNOT_ADD_ADMIN: u64 = 1010;
const E_INSUFFICIENT_STAKE_AMOUNT: u64 = 1011;
const E_CONTRACT_ALREADY_PAUSED: u64 = 1012;
const E_ADMIN_NOT_FOUND: u64 = 1012;
const E_CONTRACT_ALREADY_UNPAUSED: u64 = 1013;

// === Constants ===
const MAX_ADMINS: u64 = 2;
const PENALTY_PERCENTAGE: u64 = 10;

const LOCK_PERIOD_30_DAYS: u64 = 2592000;
const LOCK_PERIOD_60_DAYS: u64 = 5184000;
const LOCK_PERIOD_90_DAYS: u64 = 7776000;

/// Stake status constants
const STATUS_ACTIVE: u8 = 1;
const STATUS_WITHDRAWN: u8 = 2;
const STATUS_EMERGENCY: u8 = 3;

// === Structs ===
/// Owner Cap
public struct OwnerCap has key, store {
    id: UID,
    owner_address: address,
    admins: vector<address>,
}

/// Admin Cap
public struct AdminCap has key, store {
    id: UID,
    admin_address: address,
}

public struct StakingPool has key {
    id: UID,
    owner: address,
    is_paused: bool,
    paused_by: option::Option<address>,
    staked_balance: Balance<SHOURYA_TOKEN>,
    total_penalty: Balance<SHOURYA_TOKEN>,
    unique_stakers: VecSet<address>,
    user_stakes: Table<address, vector<StakePosition>>,
    total_staked: u64,
    next_stake_id: u64,
}

public struct StakePosition has copy, drop, store {
    stake_id: u64,
    staker: address,
    amount: u64,
    lock_in_period: u64,
    start_timestamp: u64,
    unlock_timestamp: u64,
    status: u8,
    penalty_paid: u64,
}

// === Events ===

/// Event for staking asset
public struct AssetStaked has copy, drop {
    staker: address,
    stake_id: u64,
    amount: u64,
    lock_in_period: u64,
    unlock_timestamp: u64,
}

/// Event for unstaking asset
public struct AssetUnstaked has copy, drop {
    staker: address,
    stake_id: u64,
    amount: u64,
}

/// Event for emergency unstaking asset, with some penalty
public struct EmergencyAssetUnstaked has copy, drop {
    staker: address,
    stake_id: u64,
    amount_returned: u64,
    penalty: u64,
}

/// Event in case the contract is paused
public struct StakingContractPaused has copy, drop {
    paused_by: address,
    timestamp: u64,
}

/// Event when the contract is unpaused
public struct StakingContractUnpaused has copy, drop {
    paused_by: address,
    timestamp: u64,
}

/// Event after the Admin Cap is delegated by the owner
public struct AdminCapDelegated has copy, drop {
    admin_address: address,
    delegated_by: address,
}

/// Event after the Admin Cap is revoked by the owner
public struct AdminCapRemoved has copy, drop {
    admin_address: address,
    removed_by: address,
}

// === Init Function ===

fun init(ctx: &mut TxContext) {
    let owner_cap = OwnerCap {
        id: object::new(ctx),
        owner_address: tx_context::sender(ctx),
        admins: vector::empty(),
    };

    let sender = tx_context::sender(ctx);

    let staking_pool = StakingPool {
        id: object::new(ctx),
        owner: sender,
        is_paused: false,
        paused_by: option::none(),
        staked_balance: zero<SHOURYA_TOKEN>(),
        total_penalty: zero<SHOURYA_TOKEN>(),
        unique_stakers: empty(),
        user_stakes: new(ctx),
        total_staked: 0,
        next_stake_id: 1,
    };

    transfer::share_object(staking_pool);

    transfer::public_transfer(owner_cap, sender);
}

// === Owner functions ===

public fun delegate_admin_cap(
    owner_cap: &mut OwnerCap,
    admin_address: address,
    ctx: &mut TxContext,
) {
    assert!(&owner_cap.owner_address == tx_context::sender(ctx), E_NOT_OWNER);

    assert!(vector::length(&owner_cap.admins) < MAX_ADMINS, E_MAX_ADMINS_REACHED);

    assert!(!vector::contains(&owner_cap.admins, &admin_address), E_ADMIN_ALREADY_PRESENT);

    vector::push_back(&mut owner_cap.admins, admin_address);

    let admin_cap = AdminCap {
        id: object::new(ctx),
        admin_address,
    };

    transfer::transfer(admin_cap, admin_address);

    event::emit(AdminCapDelegated {
        admin_address,
        delegated_by: tx_context::sender(ctx),
    })
}

public fun remove_admin(owner_cap: &mut OwnerCap, admin_address: address, ctx: &mut TxContext) {
    assert!(&owner_cap.owner_address == tx_context::sender(ctx), E_NOT_OWNER);

    let (found, index) = vector::index_of(&owner_cap.admins, &admin_address);

    assert!(found, E_ADMIN_NOT_FOUND);

    vector::remove(&mut owner_cap.admins, index);

    event::emit(AdminCapRemoved {
        admin_address,
        removed_by: tx_context::sender(ctx),
    });
}

// === Admin functions ===

public fun pause_contract(_admin_cap: &AdminCap, pool: &mut StakingPool, ctx: &TxContext) {
    assert!(&_admin_cap.admin_address == tx_context::sender(ctx), E_NOT_ADMIN);

    assert!(!pool.is_paused, E_CONTRACT_ALREADY_PAUSED);

    pool.is_paused = true;

    event::emit(StakingContractPaused {
        paused_by: tx_context::sender(ctx),
        timestamp: tx_context::epoch(ctx),
    });
}

public fun unpause_contract(_admin_cap: &AdminCap, pool: &mut StakingPool, ctx: &TxContext) {
    assert!(&_admin_cap.admin_address == tx_context::sender(ctx), E_NOT_ADMIN);

    assert!(pool.is_paused, E_CONTRACT_ALREADY_UNPAUSED);

    pool.is_paused = false;

    event::emit(StakingContractUnpaused {
        paused_by: tx_context::sender(ctx),
        timestamp: tx_context::epoch(ctx),
    });
}

// === Staking Function ===

public fun stake(
    pool: &mut StakingPool,
    asset: Coin<SHOURYA_TOKEN>,
    lock_in_period_days: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {}
