module joystiq::nft_core;

use std::string::{utf8, String};
use sui::clock::Clock;
use sui::coin::Coin;
use sui::hash::keccak256;
use sui::package::claim;
use sui::tx_context::sender;

const VERSION: u64 = 1;

/*------------------
STRUCT DEFINITIONS
-------------------*/
public struct Root has key, store {
    id: UID,
    admin: address,
    version: u64, // version of the contract
    fee: u64, //fee unit per paid mint
}

public struct Collection has key, store {
    id: UID,
    package: String,
    name: String,
    mint_groups: vector<MintGroup>,
}

public struct MintGroup has drop, store {
    name: String,
    merkle_root: Option<vector<u8>>,
    max_mints_per_wallet: u64,
    reserved_supply: u64,
    start_time: u64,
    end_time: u64,
    payments: u8, //total number of payments
}

public struct Payment<phantom T> has drop, store {
    coin: String,
    routes: vector<PaymentRoute>, // Payment routes for this payment
}

public struct PaymentRoute has drop, store {
    method: String, // "transfer" or "burn"
    amount: u64, // Amount in smallest unit
    destination: Option<address>,
}

public struct Minted has key, store {
    id: UID,
    amount: u64,
}

/*------------------
VALIDATION FUNCTIONS
-------------------*/
// Validate an unpaid mint
public entry fun validate_unpaid(
    collection: &mut Collection,
    token_ids: vector<u64>,
    group_index: u64,
    merkle_proof: Option<vector<vector<u8>>>,
    clock: &Clock,
    ctx: &mut TxContext,
) {

    assert!(collection.mint_groups[group_index].payments == 0, 0x99); // Group has to be unpaid

    validate_internal(
        collection,
        group_index,
        merkle_proof,
        token_ids,
        clock,
        ctx,
    );
}

//validate a single coin paid mint
public entry fun validate<T>(
    root: &mut Root,
    collection: &mut Collection,
    token_ids: vector<u64>,
    group_index: u64,
    merkle_proof: Option<vector<vector<u8>>>,
    clock: &Clock,
    coin: Coin<T>,
    ctx: &mut TxContext,
) {
    assert!(collection.mint_groups[group_index].payments == 1, 0x100); // Group has to be exactly one payment

    // Validate the generic
    validate_internal(
        collection,
        group_index,
        merkle_proof,
        token_ids,
        clock,
        ctx,
    );

    // Pay the payment
    let mut payment_key = b"payment_0_of_group_".to_string();
    payment_key.append(group_index.to_string());
    let payment = sui::dynamic_field::borrow<String, Payment<T>>(&collection.id, payment_key);

    let mut coin_1 = pay(
        payment,
        coin,
        token_ids.length(),
        ctx,
    );

    if (payment.coin == utf8(b"0x2::sui::SUI")) {
        coin_1 =
            pay_fee(
                root,
                coin_1,
                token_ids.length(),
                ctx,
            );
    };

    coin_1.destroy_zero();
}

//validate a two coin paid mint
public entry fun validate_2<T1, T2>(
    root: &mut Root,
    collection: &mut Collection,
    token_ids: vector<u64>,
    group_index: u64,
    merkle_proof: Option<vector<vector<u8>>>,
    clock: &Clock,
    coin: Coin<T1>,
    coin2: Coin<T2>,
    ctx: &mut TxContext,
) {
    assert!(collection.mint_groups[group_index].payments == 2, 0x101); // Group has to be exactly two payments

    // Validate the generic
    validate_internal(
        collection,
        group_index,
        merkle_proof,
        token_ids,
        clock,
        ctx,
    );

    // Pay first payment
    let mut payment_0_key = b"payment_0_of_group_".to_string();
    payment_0_key.append(group_index.to_string());
    let payment_0 = sui::dynamic_field::borrow<String, Payment<T1>>(&collection.id, payment_0_key);

    let mut coin_0 = pay(
        payment_0,
        coin,
        token_ids.length(),
        ctx,
    );

    // Pay second payment
    let mut payment_1_key = b"payment_1_of_group_".to_string();
    payment_1_key.append(group_index.to_string());
    let payment_1 = sui::dynamic_field::borrow<String, Payment<T2>>(&collection.id, payment_1_key);

    let mut coin_1 = pay(
        payment_1,
        coin2,
        token_ids.length(),
        ctx,
    );

    if (payment_0.coin == utf8(b"0x2::sui::SUI")) {
        // If the first payment is SUI, pay the fee with the first coin
        coin_0 =
            pay_fee(
                root,
                coin_0,
                token_ids.length(),
                ctx,
            );
    } else if (payment_1.coin == utf8(b"0x2::sui::SUI")) {
        // If the second payment is SUI, pay the fee with the second coin
        coin_1 =
            pay_fee(
                root,
                coin_1,
                token_ids.length(),
                ctx,
            );
    };

    coin_0.destroy_zero();
    coin_1.destroy_zero();
}

/*------------------
COLLECTION REGISTRATION AND UPDATES
-------------------*/
public entry fun register_collection(
    //root: &mut Root,
    publisher: &mut sui::package::Publisher,
    name: String,
    ctx: &mut TxContext,
) {
    let package = std::string::from_ascii(*publisher.package());


    let collection = Collection {
        id: object::new(ctx),
        package,
        name,
        mint_groups: vector::empty<MintGroup>(),
    };

    transfer::public_share_object(collection);

}

public entry fun update_collection(
    //root: &mut Root,
    collection: &mut Collection,
    _: &mut sui::package::Publisher,
    name: String,
    mg_name: vector<String>,
    mg_merkle_root: vector<Option<vector<u8>>>,
    mg_max_mints_per_wallet: vector<u64>,
    mg_reserved_supply: vector<u64>,
    mg_start_time: vector<u64>,
    mg_end_time: vector<u64>,
    ctx: &mut TxContext,
) {
    //let package = std::string::from_ascii(*publisher.package());

    // Get the collection from the root object
    //let collection = sui::dynamic_field::borrow_mut<String, Collection>(&mut root.id, package);

    // Update the collection name
    collection.name = name;

    let mut mint_groups = vector::empty<MintGroup>();
    let num_groups = vector::length(&mg_name);
    let mut i = 0;
    while (i < num_groups) {
        //create minted objects for each group
        let mut group_minted_key = b"minted_count_".to_string();
        group_minted_key.append(mg_name[i]);
        if (!sui::dynamic_field::exists_(&collection.id, group_minted_key)) {
            let group_minted = Minted {
                id: object::new(ctx),
                amount: 0, // Initialize with 0 minted
            };
            sui::dynamic_field::add(&mut collection.id, group_minted_key, group_minted);
        };

        // Create the mint group
        let group = MintGroup {
            name: mg_name[i],
            merkle_root: mg_merkle_root[i],
            max_mints_per_wallet: mg_max_mints_per_wallet[i],
            reserved_supply: mg_reserved_supply[i],
            start_time: mg_start_time[i],
            end_time: mg_end_time[i],
            payments: 0, // Default to one payment, it will be set in set_payments
        };
        vector::push_back(&mut mint_groups, group);

        //create minted objects for each group
        i = i + 1;
    };

    // Update the mint groups in the collection
    collection.mint_groups = mint_groups;
}

/*------------------
PAYMENT FUNCTIONS
-------------------*/

public entry fun set_payments<C1, C2, D1, D2>(
    //root: &mut Root,
    collection: &mut Collection,
    _: &mut sui::package::Publisher,
    group_index: u64,
    payment_0_coin: Option<String>,
    payment_0_routes_methods: vector<String>,
    payment_0_routes_amounts: vector<u64>,
    payment_0_routes_destinations: vector<Option<address>>,
    payment_1_coin: Option<String>,
    payment_1_routes_methods: vector<String>,
    payment_1_routes_amounts: vector<u64>,
    payment_1_routes_destinations: vector<Option<address>>,
    _ctx: &mut TxContext,
) {
    //assert that if payment_1_coin is set, then payment_0_coin also must be set
    if (payment_1_coin.is_some() && payment_0_coin.is_none()) {
        abort 0x102
    };

    if (payment_0_coin.is_some() && payment_1_coin.is_some()) {
        // Compare the provided coin type strings (exact, case-sensitive)
        if (std::string::as_bytes(payment_0_coin.borrow()) == std::string::as_bytes(payment_1_coin.borrow())) {
            abort 0x103
        };
        // Also ensure the generic coin type params differ
        let t0 = std::type_name::get<C1>();
        let t1 = std::type_name::get<C2>();
        if (std::type_name::borrow_string(&t0).as_bytes() == std::type_name::borrow_string(&t1).as_bytes()) {
            abort 0x104
        };
    };

    let mut payment_0_key = b"payment_0_of_group_".to_string();
    payment_0_key.append(group_index.to_string());
    if (sui::dynamic_field::exists_(&collection.id, payment_0_key)) {
        sui::dynamic_field::remove<String, Payment<D1>>(&mut collection.id, payment_0_key);
    };
    let mut payment_1_key = b"payment_1_of_group_".to_string();
    payment_1_key.append(group_index.to_string());
    if (sui::dynamic_field::exists_(&collection.id, payment_1_key)) {
        sui::dynamic_field::remove<String, Payment<D2>>(&mut collection.id, payment_1_key);
    };

    // create the first payment if it is set
    if (payment_0_coin.is_some()) {
        // Create the first payment
        let payment_0 = create_payment<C1>(
            *payment_0_coin.borrow(),
            payment_0_routes_methods,
            payment_0_routes_amounts,
            payment_0_routes_destinations,
        );

        // Add the first payment to the mint group
        let mut payment_0_key = b"payment_0_of_group_".to_string();
        payment_0_key.append(group_index.to_string());
        sui::dynamic_field::add(
            &mut collection.id,
            payment_0_key,
            payment_0,
        );

        collection.mint_groups[group_index].payments = 1;
    };

    // If the second payment is set, create it
    if (payment_1_coin.is_some()) {
        // Create the second payment
        let payment_1 = create_payment<C2>(
            *payment_1_coin.borrow(),
            payment_1_routes_methods,
            payment_1_routes_amounts,
            payment_1_routes_destinations,
        );

        // Add the second payment to the mint group
        let mut payment_1_key = b"payment_1_of_group_".to_string();
        payment_1_key.append(group_index.to_string());
        sui::dynamic_field::add(
            &mut collection.id,
            payment_1_key,
            payment_1,
        );
        collection.mint_groups[group_index].payments = 2;
    };

    if (payment_0_coin.is_none() && payment_1_coin.is_none()) {
        // If no payments are set, reset the payments count
        collection.mint_groups[group_index].payments = 0;
    }
}

fun create_payment<T>(
    coin: String,
    routes_methods: vector<String>,
    routes_amounts: vector<u64>,
    routes_destinations: vector<Option<address>>,
): Payment<T> {
    let mut payment = Payment<T> {
        coin,
        routes: vector::empty<PaymentRoute>(),
    };

    // Validate routes and add them to the payment
    let num_routes = vector::length(&routes_methods);
    let mut i = 0;
    while (i < num_routes) {
        if (routes_methods[i] != utf8(b"transfer") && routes_methods[i] != utf8(b"burn")) {
            abort 0x105 // Unsupported payment model
        };

        let route = PaymentRoute {
            method: routes_methods[i],
            amount: routes_amounts[i],
            destination: routes_destinations[i],
        };
        vector::push_back(&mut payment.routes, route);
        i = i + 1;
    };

    payment
}

fun pay<T>(payment: &Payment<T>, mut coin: Coin<T>, amount: u64, ctx: &mut TxContext): Coin<T> {
    let routes_len = vector::length(&payment.routes);
    let coin_mut = &mut coin;

    // If only 1 route and it's exactly equal to total, transfer full coin
    if (routes_len == 1) {
        let route = &payment.routes[0];
        let route_amount = route.amount * amount;

        let pay_coin = sui::coin::split(coin_mut, route_amount, ctx);

        if (route.method == utf8(b"burn")) {
            let dead = b"000000000000000000000000000000000000000000000000000000000000dead";
            let dest_address = sui::address::from_ascii_bytes(&dead);
            transfer::public_transfer(pay_coin, dest_address);
        } else {
            transfer::public_transfer(pay_coin, *route.destination.borrow());
        }
    } else {
        // Multi-route fallback
        let mut i = 0;
        while (i < routes_len) {
            let route = &payment.routes[i];
            let route_amount = route.amount * amount;
            let pay_coin = sui::coin::split(coin_mut, route_amount, ctx);

            if (route.method == utf8(b"burn")) {
                let dead = b"000000000000000000000000000000000000000000000000000000000000dead";
                let dest_address = sui::address::from_ascii_bytes(&dead);

                transfer::public_transfer(pay_coin, dest_address);
            } else {
                transfer::public_transfer(pay_coin, *route.destination.borrow());
            };

            i = i + 1;
        };
    };

    return coin

    //coin.destroy_zero();
}

fun pay_fee<T>(root: &Root, mut coin: Coin<T>, amount: u64, ctx: &mut TxContext): Coin<T> {
    let fee = root.fee * amount;
    if (fee != 0) {
        let coin_mut = &mut coin;
        let pay_coin = sui::coin::split(coin_mut, fee, ctx);
        let admin_address = root.admin;
        transfer::public_transfer(pay_coin, admin_address);
    };

    return coin
}

/*------------------
VALIDATION FUNCTIONS
-------------------*/

fun validate_internal(
    collection: &mut Collection,
    group_index: u64,
    merkle_proof: Option<vector<vector<u8>>>,
    token_ids: vector<u64>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let amount = token_ids.length();
    let group = &mut collection.mint_groups[group_index];

    //check if the mint group is open
    if (group.start_time > clock.timestamp_ms()) {
        abort 0x106 // Mint group not open
    };

    if (group.end_time != 0 && group.end_time < clock.timestamp_ms()) {
        abort 0x107 // Mint group closed
    };

    // Get group mints

    let mut group_minted_key = b"minted_count_".to_string();
    group_minted_key.append(group.name);
    let group_mints = sui::dynamic_field::borrow_mut<String, Minted>(
        &mut collection.id,
        group_minted_key,
    );

    // Check if the requested amount is valid
    if (group.reserved_supply != 0 && group_mints.amount + amount > group.reserved_supply) {
        abort 0x108 // Mint group supply exceeded
    };

    group_mints.amount = group_mints.amount + amount; // Increment the total minted amount

    //Prepare the mint key to track mints per wallet
    let mut mint_key = b"minted_count_in_".to_string();
    mint_key.append(group.name);
    mint_key.append(b"_of_".to_string());
    mint_key.append(sender(ctx).to_string());

    // Check if the user has already minted in this group
    if (sui::dynamic_field::exists_(&collection.id, mint_key)) {
        //if so how many have they minted?
        let minted = sui::dynamic_field::borrow_mut<String, Minted>(&mut collection.id, mint_key);
        if (
            group.max_mints_per_wallet != 0 && minted.amount + amount > group.max_mints_per_wallet
        ) {
            abort 0x109 // User has exceeded max mints per wallet
        };
        minted.amount = minted.amount + amount; // Increment the mint amount
    } else {
        // If the user has not minted in this group, we check if they have exceeded the max mints per wallet
        if (group.max_mints_per_wallet != 0 && amount > group.max_mints_per_wallet) {
            abort 0x109 // User has exceeded max mints per wallet
        };
        // If the user has not minted yet, we create a new Minted object for them
        let new_mint = Minted {
            id: object::new(ctx),
            amount: amount, // Set the initial amount to the requested amount
        };
        sui::dynamic_field::add(&mut collection.id, mint_key, new_mint);
    };

    // save token id -> owner mapping to record who minted which tokens
    let mut i = 0;
    while (i < amount) {
        let token_id_key = token_ids[i].to_string();
        sui::dynamic_field::add(
            &mut collection.id,
            token_id_key,
            sender(ctx).to_string(),
        );
        i = i + 1;
    };

    // Check if the user is allowlisted
    if (group.merkle_root.is_some()) {
        if (merkle_proof.is_none()) {
            abort 0x110
        };

        let proof = merkle_proof.borrow();
        let root_hash = group.merkle_root.borrow();
        let sender_bytes = tx_context::sender(ctx).to_bytes();
        let mut computed = keccak256(&sender_bytes); // vector<u8>

        let mut i = 0;
        let n = vector::length(proof);
        while (i < n) {
            let sib = vector::borrow(proof, i); // &vector<u8>
            let cat = if (joystiq::utils::bytes_less_than(&computed, sib)) {
                joystiq::utils::concat_bytes(&computed, sib)
            } else {
                joystiq::utils::concat_bytes(sib, &computed)
            };
            computed = keccak256(&cat);
            i = i + 1;
        };

        if (!joystiq::utils::bytes_eq(&computed, root_hash)) {
            abort 0x111 // Merkle proof validation failed
        }
    };
}

/*------------------
ADMIN LEVEL ENTRIES
-------------------*/
public entry fun update_admin(root: &mut Root, new_admin: address, ctx: &mut TxContext) {
    // Ensure the sender is the admin
    assert!(tx_context::sender(ctx) == root.admin, 0);

    // Update the admin
    root.admin = new_admin;
}

public entry fun update_fee(root: &mut Root, new_fee: u64, ctx: &mut TxContext) {
    // Ensure the sender is the admin
    assert!(tx_context::sender(ctx) == root.admin, 0);

    // Update the fee
    root.fee = new_fee;
}

public struct NFT_CORE has drop {}

fun init(otw: NFT_CORE, ctx: &mut TxContext) {
    // Claim publisher for display
    let publisher = claim(otw, ctx);

    let root = Root {
        id: object::new(ctx),
        admin: sender(ctx),
        version: VERSION, // Initialize with the current version
        fee: 0, // Default fee unit
    };

    transfer::public_transfer(publisher, sender(ctx));
    transfer::share_object(root);
}

entry fun migrate(root: &mut Root, ctx: &TxContext) {
    assert!(tx_context::sender(ctx) == root.admin, 0);

    // Update the version
    root.version = VERSION;
}
