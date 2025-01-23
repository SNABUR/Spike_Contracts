module 0xa8ff8aa5c6cf9b7511250ca1218efee986a38c50c6f794dff95389623e759a4b::nft {

    use aptos_token::token;
    use supra_framework::account;
    use supra_framework::coin;
    use supra_framework::supra_coin::SupraCoin;
    use aptos_std::simple_map;
    use std::signer::address_of;
    use std::vector;
    use std::string::{Self, String, utf8};

    const MODULE_NFT: address = @NFT;

    struct MintInfo has key {
        pool_cap: account::SignerCapability,
        minted: simple_map::SimpleMap<address, u64>,
        cid: u64
    }

    fun init_module(admin: &signer) {
        assert!(address_of(admin) == MODULE_NFT, 1); // Ensure that the admin invoking the initialization is the correct admin

        let (pool_signer, pool_signer_cap) = account::create_resource_account(admin, b"nft_pool");

        move_to(admin, MintInfo {
            pool_cap: pool_signer_cap,
            minted: simple_map::create<address, u64>(),
            cid: 0
        });

        token::create_collection(
            &pool_signer,
            utf8(b"Supra Spike Collection"),
            utf8(b"First NFT collection on SUPRA"),
            utf8(b"https://arweave.net/-A92QKnBo7oPQlUtsdOMKpLbLn0IB1iEbmIa2fyxyCA/0.json"),
            1370,
            vector<bool>[false, false, false]
        );
    }

    public entry fun mint(user: &signer, count: u64) acquires MintInfo {
        let user_addr = address_of(user);
        let mint_info_ref = borrow_global_mut<MintInfo>(MODULE_NFT);
        let cid = mint_info_ref.cid;

        assert!((cid + count) <= 1370, 3); // Ensure Globals minting limit
        let already_minted = if (simple_map::contains_key(&mint_info_ref.minted, &user_addr)) {
            *simple_map::borrow(&mint_info_ref.minted, &user_addr)
        } else {
            0
        };

        assert!((already_minted + count) <= 5, 4);

        coin::transfer<SupraCoin>(user, MODULE_NFT, 1370000000 * count); //Price per NFT 100000000 = 1 Supra

        token::initialize_token_store(user);
        token::opt_in_direct_transfer(user, true);

        let pool_signer = account::create_signer_with_capability(&mint_info_ref.pool_cap);

        let i = 0;
        while (i < count) {
            let mut_token_name = utf8(b"Supra Spike #");
            string::append(&mut mut_token_name, utf8(num_to_str(cid + i)));

            let mut_token_uri = utf8(b"https://arweave.net/-A92QKnBo7oPQlUtsdOMKpLbLn0IB1iEbmIa2fyxyCA/");
            string::append(&mut mut_token_uri, utf8(num_to_str(cid + i)));
            string::append(&mut mut_token_uri, utf8(b".json"));

            let token_data_id = token::create_tokendata(
                &pool_signer,
                utf8(b"Supra Spike Collection"), //collection Name
                mut_token_name, //token name
                utf8(b"Supra Spike first Collection."), //token description
                1, //0 means suppy is infinite
                mut_token_uri, //token URI
                MODULE_NFT, //Royalty payee address
                0, //royalty point denominator
                0, //royalty points numerator
                token::create_token_mutability_config(&vector<bool>[false, false, false, false, false]),
                vector<String>[],
                vector<vector<u8>>[],
                vector<String>[]
            );
            token::mint_token_to(&pool_signer, user_addr, token_data_id, 1);
            i = i + 1;
        };

        mint_info_ref.cid = cid + count;
        if (simple_map::contains_key(&mint_info_ref.minted, &user_addr)) {
            let current_count = *simple_map::borrow_mut(&mut mint_info_ref.minted, &user_addr);
            *simple_map::borrow_mut(&mut mint_info_ref.minted, &user_addr) = current_count + count;
        } else {
            // Agrega una nueva entrada para el usuario
            simple_map::add(&mut mint_info_ref.minted, user_addr, count);
        }
    }

    public fun num_to_str(num: u64): vector<u8> {
        let vec_data = vector::empty<u8>();
        let n = num; 
        
        if (n == 0) {
            vector::push_back(&mut vec_data, 48); 
            return vec_data
        };
        
        while (n > 0) {
            let digit = (n % 10 as u8) + 48;
            vector::push_back(&mut vec_data, digit);
            n = n / 10;
        };
        
        vector::reverse(&mut vec_data);
        
        vec_data
    }

    #[view]
    public fun get_collection_name(): String {
        string::utf8(b"Supra Spike Collection NFT")
    }
}