module IDO::ido {
    use supra_framework::coin;
    use std::signer;
    use std::vector;
    use publisher::adf_utils;
    use aptos_std::table::{Self, Table};

    const MODULE_ADMIN: address = @publisher;
    const ERROR_ONLY_ADMIN: u64 = 0;
    const ERROR_ALREADY_INITIALIZED: u64 = 1;
    const ERROR_COIN_NOT_INITIALIZED: u64 = 2;
    const ERROR_NOT_CREATOR: u64 = 3;
    const ERROR_USER_NOT_FOUND: u64 = 4;
    const ERROR_USER_NOT_WHITELIST: u64 = 5;
    const ERROR_USER_ALREADY_BOUGHT: u64 = 6;
    const P7: u64 = 10000000;

    struct RSVToken<phantom X, phantom Y> {}

    struct IDO_INFO<phantom C, phantom T> has key {
        fundAddress: address,

        whiteList: Table<address, u64>, 

        idoTOken: coin::Coin<T>,
        price: u64,
        beginTime: u64,
        releaseTime: u64,
        endTime: u64,
        minBuy: u64,
        maxBuy: u64,
    }

    public entry fun createNewIDO<Currency, CoinType>(admin: &signer, fundAddress: address, price: u64, beginTime: u64, endTime: u64, minBuy: u64, maxBuy: u64, releaseTime: u64) {
        let admin_addr = signer::address_of(admin);
        assert!(admin_addr == MODULE_ADMIN, ERROR_ONLY_ADMIN);
        assert!(!exists<IDO_INFO<Currency, CoinType>>(admin_addr), ERROR_ALREADY_INITIALIZED);
        adf_utils::check_coin_store<Currency>(admin);
        adf_utils::check_coin_store<CoinType>(admin);

        move_to<IDO_INFO<Currency, CoinType>>(admin, IDO_INFO<Currency, CoinType>{fundAddress: fundAddress, whiteList: table::new(), idoTOken: coin::zero<CoinType>(), price: price, beginTime: beginTime, endTime: endTime, minBuy: minBuy, maxBuy: maxBuy, releaseTime: releaseTime});
    }

    public entry fun addWhiteList<Currency, CoinType>(admin: &signer, addresses: vector<address>) acquires IDO_INFO{
        let admin_addr = signer::address_of(admin);
        assert!(admin_addr == MODULE_ADMIN, ERROR_ONLY_ADMIN);

        assert!(exists<IDO_INFO<Currency, CoinType>>(MODULE_ADMIN), ERROR_COIN_NOT_INITIALIZED);
        let idoInfo = borrow_global_mut<IDO_INFO<Currency, CoinType>>(MODULE_ADMIN);

        let a_len = vector::length(&addresses);
        let i = 0;

        while (i < a_len) {

            let add = *vector::borrow(&addresses, i);
            table::add(&mut idoInfo.whiteList, add, 0);
            i = i+1;
        };
    }

    public entry fun depositToken<Currency, CoinType>(admin: &signer, amount: u64) acquires IDO_INFO{
        let admin_addr = signer::address_of(admin);
        assert!(admin_addr == MODULE_ADMIN, ERROR_ONLY_ADMIN);

        assert!(exists<IDO_INFO<Currency, CoinType>>(MODULE_ADMIN), ERROR_COIN_NOT_INITIALIZED);
        let idoInfo = borrow_global_mut<IDO_INFO<Currency, CoinType>>(MODULE_ADMIN);
        let depositCoin = coin::withdraw<CoinType>(admin, amount);
        coin::merge(&mut idoInfo.idoTOken, depositCoin);
    }
    
    public entry fun joinIdo<Currency, CoinType>(sender: &signer, amount: u64) acquires IDO_INFO{
        assert!(exists<IDO_INFO<Currency, CoinType>>(MODULE_ADMIN), ERROR_COIN_NOT_INITIALIZED);
        let idoInfo = borrow_global_mut<IDO_INFO<Currency, CoinType>>(MODULE_ADMIN);

        let depositCoin = coin::withdraw<Currency>(sender, amount*idoInfo.price/P7);
        coin::deposit(MODULE_ADMIN, depositCoin);
        table::upsert(&mut idoInfo.whiteList, signer::address_of(sender), amount);
    }

    public entry fun claim<Currency, CoinType>(sender: &signer) acquires IDO_INFO {
        assert!(exists<IDO_INFO<Currency, CoinType>>(MODULE_ADMIN), ERROR_COIN_NOT_INITIALIZED);
        let idoInfo = borrow_global_mut<IDO_INFO<Currency, CoinType>>(MODULE_ADMIN);

        let sender_addr = signer::address_of(sender);

        if(!coin::is_account_registered<CoinType>(sender_addr)) {
            coin::register<CoinType>(sender);
        };

        let balance = table::remove(&mut idoInfo.whiteList, signer::address_of(sender));
        assert!(balance > 0, ERROR_USER_NOT_FOUND);        

        let depositCoin = coin::extract<CoinType>(&mut idoInfo.idoTOken, balance);
        coin::deposit(signer::address_of(sender), depositCoin);
    }
}
