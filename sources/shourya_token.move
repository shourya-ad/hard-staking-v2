module hard_staking_v2::shourya_token;

use sui::balance::{Self, Supply};
use sui::coin::{Self, Coin};
use sui::event;

// === Constants ===

const TOTAL_SUPPLY: u64 = 1_000_000_000_000_000_000; // 1 billion with 9 decimals
const MAX_ADMINS: u64 = 2;
const DECIMALS: u8 = 9;

// === Error codes ===

const E_NOT_OWNER: u64 = 1;
const E_MAX_ADMINS_REACHED: u64 = 2;
const E_ADMIN_ALREADY_EXISTS: u64 = 3;
const E_NOT_ADMIN: u64 = 4;
const E_CONTRACT_PAUSED: u64 = 5;
const E_ADMIN_NOT_FOUND: u64 = 6;

// === Structs ===

/// Token Witness
public struct SHOURYA_TOKEN has drop {}

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

/// Token contract state
public struct ContractState has key {
    id: UID,
    paused: bool,
    paused_by: option::Option<address>,
    supply: Supply<SHOURYA_TOKEN>,
}

// === Events ===

/// Event for initial token mint
public struct TokenMinted has copy, drop {
    total_supply: u64,
    recipient: address,
}

/// Event for Admin Cap delegation
public struct AdminCapDelegated has copy, drop {
    admin_address: address,
    delegated_by: address,
    current_admin_count: u64,
}

/// Event when supply object is created
public struct SupplyObjectCreated has copy, drop {
    total_supply: u64,
}

/// Event when contract is paused
public struct ContractPaused has copy, drop {
    paused_by: address,
    timestamp: u64,
}

/// Event when contract is unpaused
public struct ContractUnpaused has copy, drop {
    unpaused_by: address,
    timestamp: u64,
}

/// Event when admin is removed
public struct AdminRemoved has copy, drop {
    admin_address: address,
    removed_by: address,
    remaining_admin_count: u64,
}

// === Init Function ===
fun init(_witness: SHOURYA_TOKEN, _ctx: &mut TxContext) {
    let (mut treasury_cap, metadata) = coin::create_currency(
        _witness,
        DECIMALS,
        b"SHO",
        b"Shourya",
        b"A custom Sui token",
        option::none(),
        _ctx,
    );

    transfer::public_freeze_object(metadata);

    let total_token_supply = coin::mint(&mut treasury_cap, TOTAL_SUPPLY, _ctx);

    let owner_address = tx_context::sender(_ctx);

    transfer::public_transfer(total_token_supply, owner_address);

    // emit token transfer event
    event::emit(TokenMinted {
        total_supply: TOTAL_SUPPLY,
        recipient: owner_address,
    });

    let owner_cap = OwnerCap {
        id: object::new(_ctx),
        owner_address: tx_context::sender(_ctx),
        admins: vector::empty(),
    };

    transfer::transfer(owner_cap, owner_address);

    let supply = coin::treasury_into_supply(treasury_cap);

    // emit supply object created event
    event::emit(SupplyObjectCreated {
        total_supply: balance::supply_value(&supply),
    });

    let contract_state = ContractState {
        id: object::new(_ctx),
        paused: false,
        paused_by: option::none(),
        supply,
    };
    transfer::share_object(contract_state);
}

// === Owner function ===

/// Delegate Admin cap
public fun delegate_admin_cap(
    owner_cap: &mut OwnerCap,
    admin_address: address,
    ctx: &mut TxContext,
) {
    // assert if the caller is actually the owner
    assert!(&owner_cap.owner_address == tx_context::sender(ctx), E_NOT_OWNER);

    // assert if the number of admins has not reached the max limit
    assert!(vector::length(&owner_cap.admins) < MAX_ADMINS, E_MAX_ADMINS_REACHED);

    // assert if the admin already has the admin cap
    assert!(!vector::contains(&owner_cap.admins, &admin_address), E_ADMIN_ALREADY_EXISTS);

    vector::push_back(&mut owner_cap.admins, admin_address);

    let admin_cap = AdminCap {
        id: object::new(ctx),
        admin_address,
    };

    transfer::transfer(admin_cap, admin_address);

    event::emit(AdminCapDelegated {
        admin_address,
        delegated_by: tx_context::sender(ctx),
        current_admin_count: vector::length(&owner_cap.admins),
    });
}

/// Remove an admin
public fun remove_admin(owner_cap: &mut OwnerCap, admin_address: address, ctx: &mut TxContext) {
    assert!(&owner_cap.owner_address == tx_context::sender(ctx), E_NOT_OWNER);

    let (found, index) = vector::index_of(&owner_cap.admins, &admin_address);

    assert!(found, E_ADMIN_NOT_FOUND);

    vector::remove(&mut owner_cap.admins, index);

    event::emit(AdminRemoved {
        admin_address,
        removed_by: tx_context::sender(ctx),
        remaining_admin_count: vector::length(&owner_cap.admins),
    })
}

/// View supply information
public fun view_supply_only_owner(
    owner_cap: &mut OwnerCap,
    state: &ContractState,
    ctx: &mut TxContext,
): u64 {
    assert!(&owner_cap.owner_address == tx_context::sender(ctx), E_NOT_OWNER);

    balance::supply_value(&state.supply)
}

// === Admin Functions ===

/// Pause contract
public fun pause_contract(admin_cap: &AdminCap, state: &mut ContractState, ctx: &mut TxContext) {
    assert!(&admin_cap.admin_address == tx_context::sender(ctx), E_NOT_ADMIN);

    assert!(!state.paused, E_CONTRACT_PAUSED);

    state.paused = true;
    state.paused_by = option::some(tx_context::sender(ctx));

    event::emit(ContractPaused {
        paused_by: tx_context::sender(ctx),
        timestamp: tx_context::epoch(ctx),
    });
}

/// Unpause Contract
public fun unpause_contract(admin_cap: &AdminCap, state: &mut ContractState, ctx: &mut TxContext) {
    assert!(&admin_cap.admin_address == tx_context::sender(ctx), E_NOT_ADMIN);

    assert!(state.paused, E_CONTRACT_PAUSED);

    state.paused = false;
    state.paused_by = option::some(tx_context::sender(ctx));

    event::emit(ContractUnpaused {
        unpaused_by: tx_context::sender(ctx),
        timestamp: tx_context::epoch(ctx),
    });
}

// === Transfer Token ===

/// transfer function that checks pause state
public fun transfer_token(
    state: &ContractState,
    coin: &mut Coin<SHOURYA_TOKEN>,
    amount: u64,
    recipient: address,
    ctx: &mut TxContext,
) {
    assert!(!state.paused, E_CONTRACT_PAUSED);

    let split_coin = coin::split(coin, amount, ctx);

    transfer::public_transfer(split_coin, recipient);
}
