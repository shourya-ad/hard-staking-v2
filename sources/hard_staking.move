module hard_staking_v2::hard_staking;

use hard_staking_v2::shourya_token::SHOURYA_TOKEN;
use sui::balance::{Self, Balance, zero};
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::event;
use sui::table::{Self, Table, new};
use sui::vec_set::{Self, VecSet, empty};

// === Error Codes ===
const E_NOT_OWNER: u64 = 1000;
const E_NOT_ADMIN: u64 = 1001;
const E_INVALID_LOCK_PERIOD: u64 = 1002;
const E_STAKE_STILL_LOCKED: u64 = 1003;
const E_INVALID_STAKE_ID: u64 = 1004;
const E_STAKE_ALREADY_WITHDRAWN: u64 = 1005;
const E_MAX_ADMINS_REACHED: u64 = 1006;
const E_ADMIN_ALREADY_PRESENT: u64 = 1007;
const E_INSUFFICIENT_STAKE_AMOUNT: u64 = 1008;
const E_CONTRACT_ALREADY_PAUSED: u64 = 1009;
const E_ADMIN_NOT_FOUND: u64 = 1010;
const E_CONTRACT_ALREADY_UNPAUSED: u64 = 1011;

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
    total_penalty_collected: u64,
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
        total_penalty_collected: 0,
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
) {
    assert!(!pool.is_paused, E_CONTRACT_ALREADY_PAUSED);

    let lock_in_period = validate_and_get_lock_in_period(lock_in_period_days);

    let staker = tx_context::sender(ctx);
    let amount = coin::value(&asset);

    assert!(amount > 0, E_INSUFFICIENT_STAKE_AMOUNT);

    let current_time = clock::timestamp_ms(clock);
    let maturing_time = current_time + (lock_in_period * 1000);

    let user_stake_position = StakePosition {
        stake_id: pool.next_stake_id,
        staker,
        amount,
        lock_in_period,
        start_timestamp: current_time,
        unlock_timestamp: maturing_time,
        status: STATUS_ACTIVE,
        penalty_paid: 0,
    };

    if (!vec_set::contains(&pool.unique_stakers, &staker)) {
        vec_set::insert(&mut pool.unique_stakers, staker);
    };
    if (!table::contains(&pool.user_stakes, staker)) {
        table::add(&mut pool.user_stakes, staker, vector::empty());
    };
    let stakes = table::borrow_mut(&mut pool.user_stakes, staker);
    vector::push_back(stakes, user_stake_position);

    pool.next_stake_id = pool.next_stake_id + 1;
    pool.total_staked = pool.total_staked + amount;

    let coin_balance = coin::into_balance(asset);
    balance::join(&mut pool.staked_balance, coin_balance);

    event::emit(AssetStaked {
        staker,
        stake_id: user_stake_position.stake_id,
        amount,
        lock_in_period,
        unlock_timestamp: maturing_time,
    });
}

/// Normal unstake after lock period expires
public fun unstake(
    pool: &mut StakingPool,
    stake_id: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<SHOURYA_TOKEN> {
    assert!(!pool.is_paused, E_CONTRACT_ALREADY_PAUSED);

    let staker = tx_context::sender(ctx);
    let current_time = clock::timestamp_ms(clock);

    assert!(table::contains(&pool.user_stakes, staker), E_INVALID_STAKE_ID);

    let stakes = table::borrow_mut(&mut pool.user_stakes, staker);

    let (found, index) = find_stake_by_id(stakes, stake_id);

    assert!(found, E_INVALID_STAKE_ID);

    let stake = vector::borrow_mut(stakes, index);

    assert!(stake.status == STATUS_ACTIVE, E_STAKE_ALREADY_WITHDRAWN);
    assert!(current_time >= stake.unlock_timestamp, E_STAKE_STILL_LOCKED);

    let amount = stake.amount;

    stake.status = STATUS_WITHDRAWN;

    pool.total_staked = pool.total_staked - amount;

    let unstaking_amount = balance::split(&mut pool.staked_balance, amount);
    let unstaking_amount_coins = coin::from_balance(unstaking_amount, ctx);

    event::emit(AssetUnstaked {
        staker,
        stake_id,
        amount,
    });
    unstaking_amount_coins
}

public fun emergency_unstake(
    pool: &mut StakingPool,
    stake_id: u64,
    ctx: &mut TxContext,
): Coin<SHOURYA_TOKEN> {
    assert!(!pool.is_paused, E_CONTRACT_ALREADY_PAUSED);

    let staker = tx_context::sender(ctx);

    assert!(table::contains(&pool.user_stakes, staker), E_INVALID_STAKE_ID);

    let stakes = table::borrow_mut(&mut pool.user_stakes, staker);

    let (found, index) = find_stake_by_id(stakes, stake_id);

    assert!(found, E_INVALID_STAKE_ID);

    let stake = vector::borrow_mut(stakes, index);

    assert!(stake.status == STATUS_ACTIVE, E_STAKE_ALREADY_WITHDRAWN);

    let amount = stake.amount;
    let penalty = (amount * PENALTY_PERCENTAGE) / 100;

    let amount_to_return = amount - penalty;

    stake.status = STATUS_EMERGENCY;
    stake.penalty_paid = penalty;

    pool.total_staked = pool.total_staked - amount;
    pool.total_penalty_collected = pool.total_penalty_collected + penalty;

    let mut total_withdrawal = balance::split(&mut pool.staked_balance, amount);

    let penalty_balance = balance::split(&mut total_withdrawal, penalty);
    balance::join(&mut pool.total_penalty, penalty_balance);

    let unstaking_amount_coins = coin::from_balance(total_withdrawal, ctx);

    event::emit(EmergencyAssetUnstaked {
        staker,
        stake_id,
        amount_returned: amount_to_return,
        penalty,
    });

    unstaking_amount_coins
}

// === View Fundtions ===

/// Get all unique staker addresses
public fun get_unique_stakers(pool: &StakingPool): vector<address> {
    vec_set::into_keys(*&pool.unique_stakers)
}

/// Get all staking positions for a specific address
public fun get_user_stakes(pool: &StakingPool, staker: address): vector<StakePosition> {
    if (table::contains(&pool.user_stakes, staker)) {
        *table::borrow(&pool.user_stakes, staker)
    } else {
        vector::empty()
    }
}

/// Get active stakes only for a user
public fun get_active_user_stakes(pool: &StakingPool, staker: address): vector<StakePosition> {
    let all_active_user_stake = get_user_stakes(pool, staker);
    let mut active_stakes = vector::empty<StakePosition>();

    let mut i = 0;
    let len = vector::length(&all_active_user_stake);

    while (i < len) {
        let stake = vector::borrow(&all_active_user_stake, i);
        if (stake.status == STATUS_ACTIVE) {
            vector::push_back(&mut active_stakes, *stake);
        };
        i = i + 1;
    };
    active_stakes
}

/// Get pool statistics
public fun get_pool_stats(pool: &StakingPool): (u64, u64, u64, u64, bool) {
    (
        pool.total_staked,
        pool.total_penalty_collected,
        vec_set::length(&pool.unique_stakers),
        balance::value(&pool.total_penalty),
        pool.is_paused,
    )
}

// === Helper Functions ===
fun validate_and_get_lock_in_period(days: u64): u64 {
    if (days == 30) {
        LOCK_PERIOD_30_DAYS
    } else if (days == 60) {
        LOCK_PERIOD_60_DAYS
    } else if (days == 90) {
        LOCK_PERIOD_90_DAYS
    } else {
        abort E_INVALID_LOCK_PERIOD
    }
}

fun find_stake_by_id(stakes: &vector<StakePosition>, stake_id: u64): (bool, u64) {
    let mut i = 0;
    let len = vector::length(stakes);

    while (i < len) {
        let stake = vector::borrow(stakes, i);
        if (stake.stake_id == stake_id) {
            return (true, i)
        };
        i = i + 1;
    };

    (false, 0)
}
