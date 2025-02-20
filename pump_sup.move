module pump::pump_sup {
    use aptos_std::simple_map::{Self, SimpleMap};

    use std::signer::address_of;
    use std::string;
    use std::string::String;
    use std::vector;
    use std::option::{Self, Option};
    use aptos_std::math64;
    use aptos_std::type_info::type_name;
    use supra_framework::account;
    use supra_framework::account::SignerCapability;
    use supra_framework::supra_coin::SupraCoin;
    use supra_framework::coin;
    use supra_framework::coin::Coin;
    use supra_framework::event;
    use supra_framework::timestamp;
    use pump::Liquid_Staking_Token;
    use spike_amm::amm_router;

    //errors
    const ERROR_INVALID_LENGTH: u64 = 1;
    const ERROR_NO_AUTH: u64 = 2;
    const ERROR_INITIALIZED: u64 = 3;
    const ERROR_NOT_ALLOW_PRE_MINT: u64 = 4;
    const ERROR_ALREADY_PUMP: u64 = 5;
    const ERROR_PUMP_NOT_EXIST: u64 = 6;
    const ERROR_PUMP_COMPLETED: u64 = 7;
    const ERROR_PUMP_AMOUNT_IS_NULL: u64 = 8;
    const ERROR_PUMP_AMOUNT_TO_LOW: u64 = 9;
    const ERROR_TOKEN_DECIMAL: u64 = 10;
    const ERROR_INSUFFICIENT_LIQUIDITY: u64 = 11;
    const ERROR_SLIPPAGE_TOO_HIGH: u64 = 12;
    const ERROR_OVERFLOW: u64 = 13;
    const ERROR_PUMP_NOT_COMPLETED: u64 = 14;
    const ERROR_EXCEED_TRANSFER_THRESHOLD: u64 = 15;
    const ERROR_BELOW_TRANSFER_THRESHOLD: u64 = 16;
    const ERROR_NOT_NORMAL_DEX: u64 = 17;
    const ERROR_INSUFFICIENT_BALANCE: u64 = 18;
    const ERROR_WAIT_DURATION_PASSED: u64 = 19;
    const ERROR_AMOUNT_TOO_LOW: u64 = 20;
    const ERROR_NO_LAST_BUYER: u64 = 21;
    const ERROR_NOT_LAST_BUYER: u64 = 22;
    const ERROR_WAIT_TIME_NOT_REACHED: u64 = 23;
    const ERROR_NO_SELL_IN_HIGH_FEE_PERIOD: u64 = 24;

    // Decimal places for (8)
    const DECIMALS: u64 = 100_000_000;

    /*
    Configuration for the Pump module
    */
    struct PumpConfig has key, store {
        platform_fee: u64,
        resource_cap: SignerCapability,
        platform_fee_address: address,
        initial_virtual_token_reserves: u64,
        initial_virtual_supra_reserves: u64,
        token_decimals: u8,
        dex_transfer_threshold: u64,
        wait_duration: u64, // 8 hours = 28800 seconds
        min_supra_amount: u64, // Minimum purchase amount = 100_000_000 (1 SUPRA)
        high_fee: u64, // High fee rate period fee = 1000 (10%)
        deadline: u64
    }

    struct TokenList has key, store {
        token_list: vector<address>
    }

    struct Pool has key, store, copy, drop {
        real_token_reserves: u64,
        virtual_token_reserves: u64,
        virtual_supra_reserves: u64,
        is_completed: bool,
        is_normal_dex: bool,
        dev: address,
        last_buyer: Option<LastBuyer>
    }

    struct TokenPairRecord has key, store, copy {
        index: u64,
        name: String,
        symbol: String,
        pool: Pool
    }

    struct PoolRecord has key, store {
        records: SimpleMap<address, TokenPairRecord>,
        real_supra_reserves: SimpleMap<address, Coin<SupraCoin>>
    }

    // struct to track the last buyer
    struct LastBuyer has store, copy, drop {
        buyer: address,
        timestamp: u64,
        token_amount: u64
    }

    // Event handle struct for all pump-related events
    struct Handle has key {
        created_events: event::EventHandle<PumpEvent>,
        trade_events: event::EventHandle<TradeEvent>,
        transfer_events: event::EventHandle<TransferEvent>,
        unfreeze_events: event::EventHandle<UnfreezeEvent>
    }

    // Event emitted when a new pump is created
    #[event]
    struct PumpEvent has drop, store {
        pool: String,
        dev: address,
        description: String,
        name: String,
        symbol: String,
        token_address: address,
        uri: String,
        website: String,
        telegram: String,
        twitter: String,
        platform_fee: u64,
        initial_virtual_token_reserves: u64,
        initial_virtual_supra_reserves: u64,
        token_decimals: u8
    }

    //Event emitted for each trade
    #[event]
    struct TradeEvent has drop, store {
        supra_amount: u64,
        is_buy: bool,
        token_address: address,
        token_amount: u64,
        user: address,
        virtual_supra_reserves: u64,
        virtual_token_reserves: u64,
        timestamp: u64
    }

    //Event emitted when tokens are transferred
    #[event]
    struct TransferEvent has drop, store {
        supra_amount: u64,
        token_address: address,
        token_amount: u64,
        user: address,
        virtual_supra_reserves: u64,
        virtual_token_reserves: u64,
        burned_amount: u64
    }

    //Event emitted when a token account is unfrozen
    #[event]
    struct UnfreezeEvent has drop, store {
        token_address: String,
        user: address
    }

    /*
    Calculates the amount of SUPRA when buying
    @param virtual_supra_reserves - Current virtual SUPRA reserves (x)
    @param virtual_token_reserves - Current virtual token reserves (y)
    @param token_amount - Amount of token to add (delta y)
    @return SUPRA amount required (delta x)
    Formula: delta x = ((x * y) / (y - delta y)) - x
    */
    fun calculate_add_liquidity_cost(
        supra_reserves: u256, token_reserves: u256, token_amount: u256
    ): u256 {
        assert!(
            supra_reserves > 0 && token_reserves > 0 && token_amount > 0,
            ERROR_INSUFFICIENT_LIQUIDITY
        );
        let reserve_diff = token_reserves - token_amount;
        assert!(reserve_diff > 0, ERROR_INSUFFICIENT_LIQUIDITY);

        let div_part1 = ((supra_reserves * token_reserves) / reserve_diff);
        let div_part2 = ((supra_reserves * token_reserves * 100) / reserve_diff);
        
        let result = if (div_part1 * 100 < div_part2) {
            div_part1 + 1
        } else {
            div_part1
        };

        result - supra_reserves
    }

    /*
    Calculates the amount of SUPRA received when selling
    @param token_reserves - Current virtual token reserves (y)
    @param supra_reserves - Current virtual SUPRA reserves (x)
    @param token_value - Value of the token (delta y)
    @return SUPRA amount received (delta x)
    Formula: delta x = x - ((x * y) / (y + delta y))
    */
    fun calculate_sell_token(
        token_reserves: u256, supra_reserves: u256, token_value: u256
    ): u256 {
        assert!(
            token_reserves > 0 && supra_reserves > 0 && token_value > 0,
            ERROR_INSUFFICIENT_LIQUIDITY
        );

        let div_part1 = (token_reserves * supra_reserves) / (token_value + token_reserves);
        let div_part2 = (token_reserves * supra_reserves * 100) / (token_value + token_reserves);
        let result = if (div_part1 * 100 < div_part2) {
            div_part1 + 1
        } else {
            div_part1
        };

        supra_reserves - result
    }

    /*
    Calculates the amount of token received when buying
    @param token_reserves - Current virtual token reserves (y)
    @param supra_reserves - Current virtual SUPRA reserves (x)
    @param SUPRA_value - Value of SUPRA (delta x)
    @return Token amount received (delta y)
    Formula: delta y = y - ((x * y) / (x + delta x))
    */
    fun calculate_buy_token(
        token_reserves: u256, supra_reserves: u256, supra_value: u256
    ): u256 {
        assert!(
            token_reserves > 0 && supra_reserves > 0 && supra_value > 0,
            ERROR_INSUFFICIENT_LIQUIDITY
        );

        let div_part1 = (token_reserves * supra_reserves) / (supra_value + supra_reserves);
        let div_part2 = (token_reserves * supra_reserves * 100) / (
            supra_value + supra_reserves
        );
        if (div_part1 * 100 < div_part2) {
            div_part1 = div_part1 + 1;
        };
        token_reserves - div_part1
    }

    /*
    Verifies that the constant product (k) value hasn't decreased after an operation
    @param initial_meme - Initial MEME token reserves
    @param initial_supra - Initial SUPRA reserves
    @param final_meme - Final MEME token reserves
    @param final_supra - Final SUPRA reserves
    */
    fun verify_k_value(
        initial_meme: u64,
        initial_supra: u64,
        final_meme: u64,
        final_supra: u64
    ) {
        assert!(
            initial_meme > 0 && initial_supra > 0,
            ERROR_INSUFFICIENT_LIQUIDITY
        );
        assert!(
            final_meme > 0 && final_supra > 0,
            ERROR_INSUFFICIENT_LIQUIDITY
        );

        let initial_k = (initial_meme as u128) * (initial_supra as u128);
        let final_k = (final_meme as u128) * (final_supra as u128);

        assert!(final_k >= initial_k, ERROR_INSUFFICIENT_LIQUIDITY);
    }

    //Initialize module with admin account
    fun init_module(admin: &signer) {
        initialize(admin);
    }

    //Initialize the pump module with configuration
    //@param pump_admin - Signer with admin privileges
    public fun initialize(pump_admin: &signer) {
        assert!(address_of(pump_admin) == @pump, ERROR_NO_AUTH);
        assert!(
            !exists<PumpConfig>(address_of(pump_admin)),
            ERROR_INITIALIZED
        );

        let (resource_account, signer_cap) =
            account::create_resource_account(pump_admin, b"pump");
        // let resource_addr = signer::address_of(&resource_account);
        move_to(
            pump_admin,
            Handle {
                created_events: account::new_event_handle<PumpEvent>(pump_admin),
                trade_events: account::new_event_handle<TradeEvent>(pump_admin),
                transfer_events: account::new_event_handle<TransferEvent>(pump_admin),
                unfreeze_events: account::new_event_handle<UnfreezeEvent>(pump_admin)
            }
        );
        move_to(
            pump_admin,
            PumpConfig {
                platform_fee: 50,
                platform_fee_address: @pump,
                resource_cap: signer_cap,
                initial_virtual_token_reserves: 100_000_000 * DECIMALS,
                initial_virtual_supra_reserves: 30 * DECIMALS,
                token_decimals: 8,
                dex_transfer_threshold: 1_370_000 * DECIMALS,
                wait_duration: 28800, // 8 hours = 28800 seconds
                min_supra_amount: 1_370_000, // Minimum purchase amount = 1_370_000 (1 SUPRA)
                high_fee: 1000, // High fee rate period fee = 1000 (10%)
                deadline: 10800 // 3 hours = 10800 seconds
            }
        );

        let token_list = TokenList { token_list: vector::empty() };
        move_to(&resource_account, token_list);

        let pool_record = PoolRecord {
            records: simple_map::create(),
            real_supra_reserves: simple_map::create()
        };
        move_to(&resource_account, pool_record);
        coin::register<SupraCoin>(&resource_account);
    }

    #[view]
    public fun buy_token_amount(
        token_in_name: String, token_in_symbol: String, buy_token_amount: u64
    ): u64 acquires PumpConfig, PoolRecord {
        let token_addr =
            Liquid_Staking_Token::get_fa_obj_address(token_in_name, token_in_symbol);
        let config = borrow_global<PumpConfig>(@pump);

        let resource_addr = account::get_signer_capability_address(&config.resource_cap);
        assert!(exists<PoolRecord>(resource_addr), ERROR_PUMP_NOT_EXIST);

        let pool_record = borrow_global_mut<PoolRecord>(resource_addr);
        let token_pair_record =
            simple_map::borrow<address, TokenPairRecord>(
                &mut pool_record.records, &token_addr
            );
        let pool = token_pair_record.pool;

        let token_amount = math64::min(buy_token_amount, pool.virtual_token_reserves);

        let liquidity_cost =
            calculate_add_liquidity_cost(
                (pool.virtual_supra_reserves as u256),
                (pool.virtual_token_reserves as u256),
                (token_amount as u256)
            );

        (liquidity_cost as u64)
    }

    #[view]
    public fun buy_supra_amount(
        token_in_name: String, token_in_symbol: String, buy_supra_amount: u64
    ): u64 acquires PumpConfig, PoolRecord {
        let token_addr =
            Liquid_Staking_Token::get_fa_obj_address(token_in_name, token_in_symbol);
        let config = borrow_global<PumpConfig>(@pump);
        let resource_addr = account::get_signer_capability_address(&config.resource_cap);
        assert!(exists<PoolRecord>(resource_addr), ERROR_PUMP_NOT_EXIST);

        let pool_record = borrow_global_mut<PoolRecord>(resource_addr);
        let token_pair_record =
            simple_map::borrow<address, TokenPairRecord>(
                &mut pool_record.records, &token_addr
            );
        let pool = token_pair_record.pool;

        (
            calculate_buy_token(
                (pool.virtual_token_reserves as u256),
                (pool.virtual_supra_reserves as u256),
                (buy_supra_amount as u256)
            ) as u64
        )
    }

    #[view]
    public fun sell_token(
        token_in_name: String, token_in_symbol: String, sell_token_amount: u64
    ): u64 acquires PumpConfig, PoolRecord {
        let token_addr =
            Liquid_Staking_Token::get_fa_obj_address(token_in_name, token_in_symbol);
        let config = borrow_global<PumpConfig>(@pump);

        let resource_addr = account::get_signer_capability_address(&config.resource_cap);
        assert!(exists<PoolRecord>(resource_addr), ERROR_PUMP_NOT_EXIST);

        let pool_record = borrow_global_mut<PoolRecord>(resource_addr);
        let token_pair_record =
            simple_map::borrow<address, TokenPairRecord>(
                &mut pool_record.records, &token_addr
            );
        let pool = token_pair_record.pool;
        let liquidity_remove =
            calculate_sell_token(
                (pool.virtual_token_reserves as u256),
                (pool.virtual_supra_reserves as u256),
                (sell_token_amount as u256)
            );

        (liquidity_remove as u64)
    }

    #[view]
    public fun get_current_price(
        token_in_name: String, token_in_symbol: String
    ): u64 acquires PumpConfig, PoolRecord {
        let token_addr =
            Liquid_Staking_Token::get_fa_obj_address(token_in_name, token_in_symbol);
        let config = borrow_global<PumpConfig>(@pump);
        let resource_addr = account::get_signer_capability_address(&config.resource_cap);
        assert!(exists<PoolRecord>(resource_addr), ERROR_PUMP_NOT_EXIST);

        let pool_record = borrow_global_mut<PoolRecord>(resource_addr);
        let token_pair_record =
            simple_map::borrow<address, TokenPairRecord>(
                &mut pool_record.records, &token_addr
            );
        let pool = token_pair_record.pool;
        assert!(!pool.is_completed, ERROR_PUMP_COMPLETED);

        let supra_reserves = (pool.virtual_supra_reserves as u256);
        let token_reserves = (pool.virtual_token_reserves as u256);

        let ret_price = ((supra_reserves * 100_000_000) / token_reserves);
        (ret_price as u64)
    }

    #[view]
    public fun get_pool_state(
        token_in_name: String, token_in_symbol: String
    ): (u64, u64, bool) acquires PumpConfig, PoolRecord {
        let token_addr =
            Liquid_Staking_Token::get_fa_obj_address(token_in_name, token_in_symbol);
        let config = borrow_global<PumpConfig>(@pump);
        let resource_addr = account::get_signer_capability_address(&config.resource_cap);
        assert!(exists<PoolRecord>(resource_addr), ERROR_PUMP_NOT_EXIST);

        let pool_record = borrow_global_mut<PoolRecord>(resource_addr);
        let token_pair_record =
            simple_map::borrow<address, TokenPairRecord>(
                &mut pool_record.records, &token_addr
            );
        let pool = token_pair_record.pool;
        (pool.virtual_token_reserves, pool.virtual_supra_reserves, pool.is_completed)
    }

    #[view]
    public fun buy_price_with_fee(
        token_in_name: String, token_in_symbol: String, buy_meme_amount: u64
    ): u64 acquires PumpConfig, PoolRecord {
        let config = borrow_global<PumpConfig>(@pump);
        let fee = config.platform_fee;
        let supra_amount = buy_supra_amount(
            token_in_name, token_in_symbol, buy_meme_amount
        );
        let platform_fee = math64::mul_div(supra_amount, fee, 10000);
        supra_amount + platform_fee
    }

    #[view]
    public fun sell_price_with_fee(
        token_in_name: String, token_in_symbol: String, sell_meme_amount: u64
    ): u64 acquires PumpConfig, PoolRecord {
        let config = borrow_global<PumpConfig>(@pump);
        let fee = config.platform_fee;
        let supra_amount = sell_token(token_in_name, token_in_symbol, sell_meme_amount);
        let platform_fee = math64::mul_div(supra_amount, fee, 10000);
        supra_amount - platform_fee
    }

    #[view]
    public fun get_price_impact(
        token_in_name: String,
        token_in_symbol: String,
        amount: u64,
        is_buy: bool
    ): u64 acquires PumpConfig, PoolRecord {
        if (amount == 0) {
            return 0
        };
        let token_addr =
            Liquid_Staking_Token::get_fa_obj_address(token_in_name, token_in_symbol);

        let config = borrow_global<PumpConfig>(@pump);
        let resource_addr = account::get_signer_capability_address(&config.resource_cap);
        assert!(exists<PoolRecord>(resource_addr), ERROR_PUMP_NOT_EXIST);

        let pool_record = borrow_global_mut<PoolRecord>(resource_addr);
        let token_pair_record =
            simple_map::borrow<address, TokenPairRecord>(
                &mut pool_record.records, &token_addr
            );
        let pool = token_pair_record.pool;
        let supra_reserves = (pool.virtual_supra_reserves as u256);
        let token_reserves = (pool.virtual_token_reserves as u256);
        let amount_256 = (amount as u256);

        if (token_reserves == 0 || supra_reserves == 0) {
            return 0
        };

        let initial_price = (supra_reserves * 100_000_000) / token_reserves;

        let final_price =
            if (is_buy) {
                let supra_in =
                    calculate_add_liquidity_cost(
                        supra_reserves, token_reserves, amount_256
                    );
                let new_supra = supra_reserves + supra_in;
                let new_token = token_reserves - amount_256;
                if (new_token == 0) {
                    return 10000 // 100% impact
                };
                (new_supra * 100_000_000) / new_token
            } else {
                let supra_out =
                    calculate_sell_token(token_reserves, supra_reserves, amount_256);
                let new_supra = supra_reserves - supra_out;
                let new_token = token_reserves + amount_256;
                if (new_supra == 0) {
                    return 10000 // 100% impact
                };
                (new_supra * 100_000_000) / new_token
            };

        if (initial_price == 0) {
            return 10000 // 100% impact
        };

        let price_diff =
            if (final_price > initial_price) {
                (final_price - initial_price) * 10000
            } else {
                (initial_price - final_price) * 10000
            };

        ((price_diff / initial_price) as u64)
    }

    // Get last buyer information
    #[view]
    public fun get_last_buyer(
        token_in_name: String,
        token_in_symbol: String
    ): (address, u64, u64) acquires PumpConfig, PoolRecord {
        let token_addr = Liquid_Staking_Token::get_fa_obj_address(token_in_name, token_in_symbol);
        let config = borrow_global<PumpConfig>(@pump);
        let resource_addr = account::get_signer_capability_address(&config.resource_cap);
        
        let pool_record = borrow_global<PoolRecord>(resource_addr);
        let token_pair_record = simple_map::borrow(&pool_record.records, &token_addr);
        let pool = token_pair_record.pool;
        
        if (option::is_none(&pool.last_buyer)) {
            return (@0x0, 0, 0)
        };
        
        let last_buyer = option::borrow(&pool.last_buyer);
        (
            last_buyer.buyer,
            last_buyer.timestamp + config.wait_duration,
            last_buyer.token_amount
        )
    }

    // Get current pump stage
    #[view]
    public fun get_pump_stage(
        token_in_name: String,
        token_in_symbol: String
    ): u8 acquires PumpConfig, PoolRecord {
        let config = borrow_global<PumpConfig>(@pump);
        let resource_addr = account::get_signer_capability_address(&config.resource_cap);
        let token_addr = Liquid_Staking_Token::get_fa_obj_address(token_in_name, token_in_symbol);
        
        let pool_record = borrow_global<PoolRecord>(resource_addr);
        let token_pair_record = simple_map::borrow(&pool_record.records, &token_addr);
        let pool = token_pair_record.pool;
        
        // Stage 4: Pool completed
        if (pool.is_completed) {
            return 4
        };
        
        let real_supra_reserves = simple_map::borrow(&pool_record.real_supra_reserves, &token_addr);
        let current_supra_balance = coin::value<SupraCoin>(real_supra_reserves);

        // Stage 1: Before reaching threshold
        if (current_supra_balance < config.dex_transfer_threshold) {
            return 1
        };

        // Stage 2: After threshold but before wait duration
        if (option::is_some(&pool.last_buyer)) {
            let last_buyer = option::borrow(&pool.last_buyer);
            let current_time = timestamp::now_seconds();

            if (current_time < last_buyer.timestamp + config.wait_duration) {
                return 2
            };

            // Stage 3: After wait duration
            return 3
        };

        // Stage 2: After threshold but no last buyer yet
        1
    }
    /*
    Deploy a new MEME token and create its pool
    */
    entry public fun deploy(
        caller: &signer,
        description: String,
        name: String,
        symbol: String,
        uri: String,
        website: String,
        telegram: String,
        twitter: String
    ) acquires PumpConfig, Handle, TokenList, PoolRecord {
        // Validate string lengths
        assert!(!(string::length(&description) > 1000), ERROR_INVALID_LENGTH);
        assert!(!(string::length(&name) > 100), ERROR_INVALID_LENGTH);
        assert!(!(string::length(&symbol) > 100), ERROR_INVALID_LENGTH);
        assert!(!(string::length(&uri) > 100), ERROR_INVALID_LENGTH);
        assert!(!(string::length(&website) > 100), ERROR_INVALID_LENGTH);
        assert!(!(string::length(&telegram) > 100), ERROR_INVALID_LENGTH);
        assert!(!(string::length(&twitter) > 100), ERROR_INVALID_LENGTH);

        let config = borrow_global<PumpConfig>(@pump);
        let resource_addr = account::get_signer_capability_address(&config.resource_cap);
        assert!(exists<PoolRecord>(resource_addr), ERROR_PUMP_NOT_EXIST);
        let sender = address_of(caller);

        Liquid_Staking_Token::create_fa(
            name,
            symbol,
            config.token_decimals,
            uri,
            website
        );
        let token_list = borrow_global_mut<TokenList>(resource_addr);
        let pool_record = borrow_global_mut<PoolRecord>(resource_addr);

        // Create and initialize pool
        let pool = Pool {
            real_token_reserves: config.initial_virtual_token_reserves,
            virtual_token_reserves: config.initial_virtual_token_reserves,
            virtual_supra_reserves: config.initial_virtual_supra_reserves,
            is_completed: false,
            is_normal_dex: false,
            dev: sender,
            last_buyer: option::none()
        };

        let token_pair_record = TokenPairRecord {
            index: vector::length(&token_list.token_list),
            name: name,
            symbol: symbol,
            pool
        };

        let token_address = Liquid_Staking_Token::get_fa_obj_address(name, symbol);
        simple_map::add(&mut pool_record.records, token_address, token_pair_record);
        simple_map::add(
            &mut pool_record.real_supra_reserves, token_address, coin::zero<SupraCoin>()
        );

        vector::push_back(&mut token_list.token_list, token_address);

        // Emit creation event
        event::emit_event(
            &mut borrow_global_mut<Handle>(@pump).created_events,
            PumpEvent {
                platform_fee: config.platform_fee,
                initial_virtual_token_reserves: config.initial_virtual_token_reserves,
                initial_virtual_supra_reserves: config.initial_virtual_supra_reserves,
                token_decimals: config.token_decimals,
                pool: type_name<Pool>(),
                token_address,
                dev: sender,
                description,
                name,
                symbol,
                uri,
                website,
                telegram,
                twitter
            }
        );
    }

    fun get_token_by_sup(
        pool: &mut Pool, supra_in_amount: u64, token_out_amount: u64
        
    ) {
        assert!(
            token_out_amount <= pool.virtual_token_reserves,
            ERROR_INSUFFICIENT_LIQUIDITY
        );
        assert!(
            token_out_amount > 0 && supra_in_amount > 0,
            ERROR_PUMP_AMOUNT_IS_NULL
        );
        let initial_virtual_token = pool.virtual_token_reserves;
        let initial_virtual_supra = pool.virtual_supra_reserves;
        if (supra_in_amount > 0) {
            pool.virtual_supra_reserves = pool.virtual_supra_reserves + supra_in_amount;
        };

        pool.virtual_token_reserves = pool.virtual_token_reserves - token_out_amount;

        verify_k_value(
            initial_virtual_token,
            initial_virtual_supra,
            pool.virtual_token_reserves,
            pool.virtual_supra_reserves
        );
    }

    //Buy MEME tokens with SUPRA without slippage protection
    //@param caller - Signer buying the tokens
    //@param token_addr - FA tokens address
    //@param buy_meme_amount - Amount of MEME tokens to buy
    public entry fun buy(
        caller: &signer,
        token_in_name: String,
        token_in_symbol: String,
        buy_token_amount: u64
    ) acquires PumpConfig, PoolRecord, Handle {
        assert!(buy_token_amount > 0, ERROR_PUMP_AMOUNT_IS_NULL);
        let token_addr =
            Liquid_Staking_Token::get_fa_obj_address(token_in_name, token_in_symbol);
        let sender = address_of(caller);
        let config = borrow_global<PumpConfig>(@pump);

        if (!coin::is_account_registered<SupraCoin>(sender)) {
            coin::register<SupraCoin>(caller);
        };

        let resource = account::create_signer_with_capability(&config.resource_cap);
        let resource_addr = address_of(&resource);
        assert!(exists<PoolRecord>(resource_addr), ERROR_PUMP_NOT_EXIST);

        let pool_record = borrow_global_mut<PoolRecord>(resource_addr);
        let token_pair_record =
            simple_map::borrow_mut<address, TokenPairRecord>(
                &mut pool_record.records, &token_addr
            );
        let pool = &mut token_pair_record.pool;

        assert!(!pool.is_completed, ERROR_PUMP_COMPLETED);

        let real_supra_reserves =
            simple_map::borrow_mut<address, Coin<SupraCoin>>(
                &mut pool_record.real_supra_reserves, &token_addr
            );
        let current_supra_balance = coin::value(real_supra_reserves);

        // Check the minimum purchase amount
        let token_amount = math64::min(buy_token_amount, pool.real_token_reserves);

        // Check if the high fee period has started
        if (current_supra_balance >= config.dex_transfer_threshold) {
            // Check if the wait duration has passed since the last buy
            if (option::is_some(&pool.last_buyer)) {
                let last_buyer = option::borrow(&pool.last_buyer);
                let current_time = timestamp::now_seconds();
                assert!(
                    current_time - last_buyer.timestamp < config.wait_duration,
                    ERROR_WAIT_DURATION_PASSED
                );
            };
            
            let liquidity_cost = 
                calculate_add_liquidity_cost(
                    (pool.virtual_supra_reserves as u256),
                    (pool.virtual_token_reserves as u256),
                    (buy_token_amount as u256)
                );

            // Check the minimum purchase amount
            assert!(
                (liquidity_cost as u64) >= config.min_supra_amount, ERROR_AMOUNT_TOO_LOW
            );

            // Use high fee (10%)
            let platform_fee = 
                math64::mul_div((liquidity_cost as u64), config.high_fee, 10000);

            // Total cost (liquidity cost + fee)
            let total_cost = (liquidity_cost as u64) + platform_fee;
            // Withdraw coins
            let total_supra_coin = coin::withdraw<SupraCoin>(caller, total_cost);
            let platform_fee_coin = coin::extract(&mut total_supra_coin, platform_fee);

            let supra_in_amount = coin::value<SupraCoin>(&total_supra_coin);
            // Pass only liquidity_cost (without fee) to the pool calculation
            get_token_by_sup(pool, supra_in_amount, token_amount);
            coin::merge<SupraCoin>(real_supra_reserves, total_supra_coin);

            // Update the last buyer information
            if (option::is_some(&pool.last_buyer)) {
                let _last_buyer = option::borrow(&pool.last_buyer);
                // Clean up previous records
            };

            // Record the new last buyer
            pool.last_buyer = option::some(LastBuyer {
                buyer: sender,
                timestamp: timestamp::now_seconds(),
                token_amount: buy_token_amount
            });

            Liquid_Staking_Token::mint(
                sender,
                token_amount,
                token_pair_record.name,
                token_pair_record.symbol
            );
            coin::deposit(config.platform_fee_address, platform_fee_coin);

            event::emit_event(
                &mut borrow_global_mut<Handle>(@pump).trade_events,
                TradeEvent {
                    supra_amount: supra_in_amount,
                    is_buy: true,
                    token_address: token_addr,
                    token_amount,
                    user: sender,
                    virtual_supra_reserves: pool.virtual_supra_reserves,
                    virtual_token_reserves: pool.virtual_token_reserves,
                    timestamp: timestamp::now_seconds()
                }
            );
            return
        };

        let liquidity_cost = 
            calculate_add_liquidity_cost(
                (pool.virtual_supra_reserves as u256),
                (pool.virtual_token_reserves as u256),
                (token_amount as u256)
            );

        // Check the minimum purchase amount
        assert!((liquidity_cost as u64) >= 10000, ERROR_AMOUNT_TOO_LOW);

        let platform_fee =
            math64::mul_div(
                (liquidity_cost as u64),
                config.platform_fee,
                10000
            );

        let total_cost = (liquidity_cost as u64) + platform_fee;
        let total_supra_coin = coin::withdraw<SupraCoin>(caller, total_cost);
        let platform_fee_coin = coin::extract(&mut total_supra_coin, platform_fee);

        let supra_in_amount = coin::value<SupraCoin>(&total_supra_coin);

        // Check if this buy will trigger the high fee period
        let will_trigger_high_fee = current_supra_balance < config.dex_transfer_threshold && 
            (current_supra_balance + supra_in_amount) >= config.dex_transfer_threshold;

        // If this buy will trigger high fee period, record this buyer as LastBuyer
        if (will_trigger_high_fee) {
            if (option::is_some(&pool.last_buyer)) {
                let _last_buyer = option::borrow(&pool.last_buyer);
            };
            pool.last_buyer = option::some(LastBuyer {
                buyer: sender,
                timestamp: timestamp::now_seconds(),
                token_amount: buy_token_amount
            });
        };

        get_token_by_sup(pool, supra_in_amount, token_amount);
        //here we need to fix total supra coin
        coin::merge<SupraCoin>(real_supra_reserves, total_supra_coin);
        // let token_amount = coin::value(&received_token);
        // let supra_amount = coin::value(&remaining_supra);
        
        Liquid_Staking_Token::mint(
            sender,
            token_amount,
            token_pair_record.name,
            token_pair_record.symbol
        );
        coin::deposit(config.platform_fee_address, platform_fee_coin);

        event::emit_event(
            &mut borrow_global_mut<Handle>(@pump).trade_events,
            TradeEvent {
                supra_amount: total_cost,
                is_buy: true,
                token_address: token_addr,
                token_amount,
                user: sender,
                virtual_supra_reserves: pool.virtual_supra_reserves,
                virtual_token_reserves: pool.virtual_token_reserves,
                timestamp: timestamp::now_seconds()
            }
        );
    }

    //Buy MEME tokens with SUPRA with slippage limit
    //@param caller - Signer buying the tokens
    //@param token_addr - FA tokens address
    //@param buy_token_amount - Amount of MEME tokens to buy
    //@param max_price_impact - Maximum price impact allowed
    public entry fun buy_with_slippage(
        caller: &signer,
        token_in_name: String,
        token_in_symbol: String,
        buy_token_amount: u64,
        max_price_impact: u64
    ) acquires PumpConfig, PoolRecord, Handle {
        let price_impact =
            get_price_impact(
                token_in_name,
                token_in_symbol,
                buy_token_amount,
                true
            );
        assert!(price_impact <= max_price_impact, ERROR_SLIPPAGE_TOO_HIGH);
        buy(
            caller,
            token_in_name,
            token_in_symbol,
            buy_token_amount
        )
    }

    fun get_sup_by_token(
        pool: &mut Pool, token_in_amount: u64, supra_out_amount: u64
    ) {
        assert!(
            supra_out_amount <= pool.virtual_supra_reserves,
            ERROR_INSUFFICIENT_LIQUIDITY
        );
        assert!(
            token_in_amount > 0 && supra_out_amount > 0,
            ERROR_PUMP_AMOUNT_IS_NULL
        );
        let initial_virtual_token = pool.virtual_token_reserves;
        let initial_virtual_supra = pool.virtual_supra_reserves;

        if (token_in_amount > 0) {
            pool.virtual_token_reserves = pool.virtual_token_reserves + token_in_amount;
        };

        pool.virtual_supra_reserves = pool.virtual_supra_reserves - supra_out_amount;

        verify_k_value(
            initial_virtual_token,
            initial_virtual_supra,
            pool.virtual_token_reserves,
            pool.virtual_supra_reserves
        );
    }

    //Sell MEME tokens for SUPRA with no slippage protection
    //@param caller - Signer selling the tokens
    //@param sell_token_amount - Amount of MEME tokens to sell
    public entry fun sell(
        caller: &signer,
        token_in_name: String,
        token_in_symbol: String,
        sell_token_amount: u64
    ) acquires PumpConfig, PoolRecord, Handle {
        assert!(sell_token_amount > 0, ERROR_PUMP_AMOUNT_IS_NULL);
        
        let token_addr = 
            Liquid_Staking_Token::get_fa_obj_address(token_in_name, token_in_symbol);
        let sender = address_of(caller);
        let config = borrow_global<PumpConfig>(@pump);
        let resource_addr = account::get_signer_capability_address(&config.resource_cap);
        assert!(exists<PoolRecord>(resource_addr), ERROR_PUMP_NOT_EXIST);
        
        let pool_record = borrow_global_mut<PoolRecord>(resource_addr);
        assert!(exists<PoolRecord>(resource_addr), ERROR_PUMP_NOT_EXIST); //added
        let token_pair_record = 
            simple_map::borrow_mut<address, TokenPairRecord>(
                &mut pool_record.records, &token_addr
            );
        let pool = &mut token_pair_record.pool;
        
        assert!(!pool.is_completed, ERROR_PUMP_COMPLETED);
        assert!(
            sell_token_amount <= pool.virtual_token_reserves, 
            ERROR_INSUFFICIENT_LIQUIDITY
        );
        
        // Add balance check
        let token_balance = Liquid_Staking_Token::get_balance(
            sender,
            token_pair_record.name,
            token_pair_record.symbol
        );
        assert!(sell_token_amount <= token_balance, ERROR_INSUFFICIENT_BALANCE);


        let real_supra_reserves = 
            simple_map::borrow_mut<address, Coin<SupraCoin>>(
                &mut pool_record.real_supra_reserves, &token_addr
            );
        let current_supra_balance = coin::value(real_supra_reserves);
        
        assert!(
            current_supra_balance <= config.dex_transfer_threshold,
            ERROR_NO_SELL_IN_HIGH_FEE_PERIOD
        );

        // Calculate SUPRA amount to receive
        let liquidity_remove =
            (
                calculate_sell_token(
                    (pool.virtual_token_reserves as u256),
                    (pool.virtual_supra_reserves as u256),
                    (sell_token_amount as u256)
                ) as u64
            );
        
        // Check the minimum purchase amount
        assert!((liquidity_remove as u64) >= 10000, ERROR_AMOUNT_TOO_LOW);

        Liquid_Staking_Token::burn(
            sender,
            sell_token_amount,
            token_pair_record.name,
            token_pair_record.symbol
        );

        // Execute swap
        get_sup_by_token(pool, sell_token_amount, liquidity_remove);

        // Handle platform fee
        let platform_fee = math64::mul_div(liquidity_remove, config.platform_fee, 10000);
        let supra_to_user = coin::extract<SupraCoin>(
            real_supra_reserves, liquidity_remove
        );
        let supra_amount = coin::value<SupraCoin>(&supra_to_user);
        let platform_fee_coin = coin::extract<SupraCoin>(&mut supra_to_user, platform_fee);

        // Distribute coins
        coin::deposit(config.platform_fee_address, platform_fee_coin);
        coin::deposit(sender, supra_to_user);

        // Emit trade event
        event::emit_event(
            &mut borrow_global_mut<Handle>(@pump).trade_events,
            TradeEvent {
                supra_amount,
                is_buy: false,
                token_address: token_addr,
                token_amount: sell_token_amount,
                user: sender,
                virtual_supra_reserves: pool.virtual_supra_reserves,
                virtual_token_reserves: pool.virtual_token_reserves,
                timestamp: timestamp::now_seconds()
            }
        );
    }

    //Sell MEME tokens for SUPRA with slippage limit
    //@param caller - Signer selling the tokens
    //@param sell_token_amount - Amount of MEME tokens to sell
    //@param max_price_impact - Maximum price impact allowed
    public entry fun sell_with_slippage(
        caller: &signer,
        token_in_name: String,
        token_in_symbol: String,
        sell_token_amount: u64,
        max_price_impact: u64
    ) acquires PumpConfig, PoolRecord, Handle {
        let price_impact =
            get_price_impact(
                token_in_name,
                token_in_symbol,
                sell_token_amount,
                false
            );
        assert!(price_impact <= max_price_impact, ERROR_SLIPPAGE_TOO_HIGH);
        sell(
            caller,
            token_in_name,
            token_in_symbol,
            sell_token_amount
        )
    }

    //Update configuration
    //@param admin - Admin signer with permission to update config
    //@param new_platform_fee - New platform fee rate (in basis points)
    //@param new_platform_fee_address - New address to receive platform fees
    //@param new_initial_virtual_token_reserves - New initial virtual token reserves
    //@param new_initial_virtual_supra_reserves - New initial virtual SUPRA reserves
    //@param new_token_decimals - New token decimals
    //@param new_dex_transfer_threshold - New threshold for DEX transfer
    //@param new_high_fee - New high fee rate (in basis points)
    //@param new_wait_duration - New wait duration in seconds
    //@param new_min_supra_amount - New minimum SUPRA amount for purchases
    public entry fun update_config(
        admin: &signer,
        new_platform_fee: u64,
        new_platform_fee_address: address,
        new_initial_virtual_token_reserves: u64,
        new_initial_virtual_supra_reserves: u64,
        new_token_decimals: u8,
        new_dex_transfer_threshold: u64,
        new_high_fee: u64,
        new_wait_duration: u64,
        new_min_supra_amount: u64,
        new_deadline: u64
    ) acquires PumpConfig {
        assert!(address_of(admin) == @pump, ERROR_NO_AUTH);
        let config = borrow_global_mut<PumpConfig>(@pump);

        config.platform_fee = new_platform_fee;
        config.platform_fee_address = new_platform_fee_address;
        config.initial_virtual_token_reserves = new_initial_virtual_token_reserves;
        config.initial_virtual_supra_reserves = new_initial_virtual_supra_reserves;
        config.token_decimals = new_token_decimals;
        config.dex_transfer_threshold = new_dex_transfer_threshold;
        config.high_fee = new_high_fee;
        config.wait_duration = new_wait_duration;
        config.min_supra_amount = new_min_supra_amount;
        config.deadline = new_deadline;
    }

    //Update DEX transfer threshold
    //@param admin - Admin signer with permission to update threshold
    //@param new_threshold - New threshold value for DEX transfer
    public entry fun update_dex_threshold(
        admin: &signer, new_threshold: u64
    ) acquires PumpConfig {
        assert!(address_of(admin) == @pump, ERROR_NO_AUTH);
        let config = borrow_global_mut<PumpConfig>(@pump);
        config.dex_transfer_threshold = new_threshold;
    }

    //Update platform fee rate
    //@param admin - Admin signer with permission to update fee
    //@param new_fee - New platform fee rate (in basis points)
    public entry fun update_platform_fee(admin: &signer, new_fee: u64) acquires PumpConfig {
        assert!(address_of(admin) == @pump, ERROR_NO_AUTH);
        let config = borrow_global_mut<PumpConfig>(@pump);
        config.platform_fee = new_fee;
    }

    //Update platform fee receiving address
    //@param admin - Admin signer with permission to update address
    //@param new_address - New address to receive platform fees
    public entry fun update_platform_fee_address(
        admin: &signer, new_address: address
    ) acquires PumpConfig {
        assert!(address_of(admin) == @pump, ERROR_NO_AUTH);
        let config = borrow_global_mut<PumpConfig>(@pump);
        config.platform_fee_address = new_address;
    }

    // ========================================= Migration Part ========================================
    // Claim migration right
    public entry fun claim_migration_right(
        caller: &signer,
        name: String,
        symbol: String
    ) acquires PumpConfig, PoolRecord, Handle {
        let config = borrow_global<PumpConfig>(@pump);
        let resource_addr = account::get_signer_capability_address(&config.resource_cap);
        assert!(exists<PoolRecord>(resource_addr), ERROR_PUMP_NOT_EXIST);
        let token_addr = Liquid_Staking_Token::get_fa_obj_address(name, symbol);
        let pool_record = borrow_global_mut<PoolRecord>(resource_addr);
        let token_pair_record = simple_map::borrow_mut<address, TokenPairRecord>(
            &mut pool_record.records, &token_addr
        );

        assert!(option::is_some(&token_pair_record.pool.last_buyer), ERROR_NO_LAST_BUYER);
        let last_buyer = option::borrow(&token_pair_record.pool.last_buyer);

        assert!(
            timestamp::now_seconds() >= last_buyer.timestamp + config.wait_duration,
            ERROR_WAIT_TIME_NOT_REACHED
        );

        let winner_address = last_buyer.buyer;
        let real_supra_reserves = simple_map::borrow_mut<address, Coin<SupraCoin>>(
            &mut pool_record.real_supra_reserves, &token_addr
        );
        migrate_to_spike_dex(
            caller,
            name,
            symbol,
            token_pair_record,
            real_supra_reserves,
            winner_address
        );
    }

    // Transfer supfun to normal dex if there is no dex support
    fun migrate_to_spike_dex(
        caller: &signer,
        name: String, 
        symbol: String,
        token_pair_record: &mut TokenPairRecord,
        real_supra_reserves: &mut Coin<SupraCoin>,
        winner_address: address
    ) acquires PumpConfig, Handle {
        let sender = address_of(caller);
        let token_addr = Liquid_Staking_Token::get_fa_obj_address(name, symbol);
        let config = borrow_global<PumpConfig>(@pump);
        let resource_addr = account::get_signer_capability_address(&config.resource_cap);
        let resource_signer = account::create_signer_with_capability(&config.resource_cap);

        let pool = &mut token_pair_record.pool;

        // check pool is not completed
        assert!(!pool.is_completed, ERROR_PUMP_COMPLETED);

        let real_supra_amount = coin::value<SupraCoin>(real_supra_reserves);

        // check if migration threshold is reached
        assert!(
            real_supra_amount >= config.dex_transfer_threshold,
            ERROR_INSUFFICIENT_LIQUIDITY
        );

        let virtual_price = 
            (pool.virtual_supra_reserves as u256) * 100_000_000 
                / (pool.virtual_token_reserves as u256);

        let required_token = (((real_supra_amount as u256) * 100_000_000 / virtual_price) as u64);
        let burned_amount = pool.virtual_token_reserves - required_token;
        pool.is_completed = true;

        // Calculate reward for winner (10% of the token amount)
        let reward_amount = pool.virtual_token_reserves / 10;

        // Send reward to winner
        Liquid_Staking_Token::mint(
            winner_address,
            reward_amount,
            token_pair_record.name,
            token_pair_record.symbol
        );

        // Extract gas fee from supra coins (0.1 SUPRA = 10000000 octa)
        let gas_amount = 10000000;
        let gas_coin = coin::extract<SupraCoin>(real_supra_reserves, gas_amount);

        // Store gas fee in resource account
        coin::deposit(resource_addr, gas_coin);

        // Store tokens in resource account
        let real_supra_amount = coin::value<SupraCoin>(real_supra_reserves);
        let real_supra = coin::extract<SupraCoin>(real_supra_reserves, real_supra_amount);
        coin::deposit<SupraCoin>(resource_addr, real_supra);

        // should mint required_token to dex
        Liquid_Staking_Token::mint(
            resource_addr,
            required_token,
            token_pair_record.name,
            token_pair_record.symbol
        );

        amm_router::add_liquidity_supra(
            &resource_signer,
            // token: address,
            token_addr,
            // amount_token_desired: u64,
            required_token,
            // amount_token_min: u64,
            0,
            // amount_supra_desired: u64,
            real_supra_amount,  // Removed gas_amount subtraction
            // amount_supra_min: u64,
            0,
            // to: address,
            resource_addr,
            // deadline: u64,
            timestamp::now_seconds() + config.deadline
        );

        // Emit transfer event
        event::emit_event(
            &mut borrow_global_mut<Handle>(@pump).transfer_events,
            TransferEvent {
                supra_amount: real_supra_amount,
                token_address: token_addr,
                token_amount: required_token,
                user: sender,
                virtual_supra_reserves: pool.virtual_supra_reserves,
                virtual_token_reserves: pool.virtual_token_reserves,
                burned_amount
            }
        );
    }

}
