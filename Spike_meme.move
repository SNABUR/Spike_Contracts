address spike {

module memecoins {
    use supra_framework::coin;
    use std::signer;
    use std::string;

    struct SPIKE {}

    struct CoinCapabilities<phantom SPIKE> has key {
        mint_capability: coin::MintCapability<SPIKE>,
        burn_capability: coin::BurnCapability<SPIKE>,
        freeze_capability: coin::FreezeCapability<SPIKE>,
        total_supply: u64, 
    }

    const E_NO_ADMIN: u64 = 0;
    const E_NO_CAPABILITIES: u64 = 1;
    const E_HAS_CAPABILITIES: u64 = 2;
    const E_ALREADY_MINTED: u64 = 3;

    const MAX_SUPPLY: u64 = 13_700_000_000_000_000_000;

    public entry fun init_SPIKE(account: &signer) {
        let (burn_capability, freeze_capability, mint_capability) = coin::initialize<SPIKE>(
            account,
            string::utf8(b"Supra Spike"),
            string::utf8(b"SPIKE"),
            3,
            true,
        );

        assert!(signer::address_of(account) == @spike, E_NO_ADMIN);
        assert!(!exists<CoinCapabilities<SPIKE>>(@spike), E_HAS_CAPABILITIES);

        move_to<CoinCapabilities<SPIKE>>(account, CoinCapabilities<SPIKE>{
            mint_capability,
            burn_capability,
            freeze_capability,
            total_supply: 0
        });
    }

    public entry fun mint(account: &signer, user: address) acquires CoinCapabilities {
        let account_address = signer::address_of(account);
        assert!(account_address == @spike, E_NO_ADMIN);
        assert!(exists<CoinCapabilities<SPIKE>>(account_address), E_NO_CAPABILITIES);

        let capabilities = borrow_global_mut<CoinCapabilities<SPIKE>>(account_address);

        assert!(capabilities.total_supply == 0, E_ALREADY_MINTED);

        capabilities.total_supply = MAX_SUPPLY;

        let coins = coin::mint<SPIKE>(MAX_SUPPLY, &capabilities.mint_capability);
        coin::deposit(user, coins);
    }

    public entry fun register_SPIKE(account: &signer) {
        coin::register<SPIKE>(account);
    }

    public fun total_supply(): u64 acquires CoinCapabilities {
        let capabilities = borrow_global<CoinCapabilities<SPIKE>>(@spike);
        capabilities.total_supply
    }
    
    public fun balance_of(account: address): u64 {
        coin::balance<SPIKE>(account)
    }

    public entry fun transfer_SPIKE(
        sender: &signer,
        recipient: address,
        amount: u64
    ) {
        let coins = coin::withdraw<SPIKE>(sender, amount);

        coin::deposit<SPIKE>(recipient, coins);
    }
}
}