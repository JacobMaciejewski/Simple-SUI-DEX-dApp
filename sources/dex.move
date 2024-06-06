module dex::dex{
    const CLIENT_ID : u64 = 122227; // The initial ID of the client posing a request to the orderbook (each request is accompanied by a new client identifier)
    const MAX_U64 : u64 =  18446744073709551615; //The biggest unsigned integer that can be stored in a 64 bit space
    const NO_RESTRICTION : u8 = 0; // Constant implying no restrictions, used for order parameters that have no restrictions
    const FLOAT_SCALING : u64 = 1_000_000_000; // Factor by which the float representation is being multiplied to create an integer representation used within the orderbook
    const EAlreadyMintedThisEpoch : u64 = 0; // The constant code of an error that indicates user has already minted a token within current epoch

    use deepbook::clob_v2::{Self as clob, Pool}; 

    // witness to ensure that there is no DEX struct instance already on chain
    struct DEX has drop{};

    // generic struct used to store information about a specific token type
    // the type of the coin has the phantom descriptor implying that the information about the cointype is not stored within the struct 
    // (good for typechecker error identification)
    struct TokenInfo<phantom CoinType> has store{
        cap : sui::coin::TreasuryCap<CoinType>,
        faucet_lock : sui::table::Table[address, u64]
    };


    // generic struct containing information about DEX, clients' interactions, their limitations and capabilities within the context of the smart contract
    struct DexInfo has key{
        id : sui::object::UID, // unique identifier of an instance of DEX Information struct
        dex_supply : sui::balance::Supply<DEX>, // the total supply of the DEX token
        swaps : sui::table::Table[address, u64], // mapping between addresses and the amount of swaps they have commited
        account_cap : deepbook::custodian_v2::AccountCap, // defines what an account can do within the context of the smart contract
        client_id : u64 // the identifier of a client 
    } 

    #[allow(unused_function)]
    fun init(witness : DEX, ctx : &mut TxContext){

        // create an instance of DEX token with its metadata 
        let (treasury_cap, token_metadata) = sui::coin::create_currency<DEX>(
            witness,
            9, 
            b"DEX", 
            b"DEX Coin",
            b"Coin of Custom SUI DEX",
            std::option::some(sui::url::new_unsafe_from_bytes(b"https://s2.coinmarketcap.com/static/img/coins/64x64/8000.png")),
            ctx
        );

        let dex_info : DexInfo = DexInfo{
            id : sui::object::new(ctx),
            dex_supply : sui::coin::treasury_into_supply(treasury_cap),
            swaps : new sui::table::new(ctx),
            account_cap clob::create_account(ctx),
            client_id : CLIENT_ID
        };

        sui::transfer::public_transfer(dex_info, tx_context::sender(ctx));
        sui::transfer::public_freeze_object(token_metadata);
    }



    // Returns the faucet lock information (last mint epoch) for a user from the structure that stores information about the parameter coin type 
    public fun get_user_last_mint_epoch<CoinType>(dex_info : &DexInfo, user : address) : u64 {

        // dynamic_field::borrow allows for manipulating a structure, extract and add fields to it, as they are now treated as dynamic
        // the identifier of the storage struct is given to extract the struct
        // then we extract the name of the type of the token
        // token_info struct is a dynamic field in the dex information struct, as it is not included in the initial definition

        let token_info : TokenInfo<CoinType> = sui::dynamic_field::borrow<sui::type_name::TypeName, TokenInfo<CoinType>>(&dex_info.id, sui::type_name::get<CoinType>());
        
        // we check if an entry about user's last mint epoch is contained within the faucet lock table of the information structure about the token at hand 
        if(sui::table::contains(&token_info.faucet_lock, user)){
            return *sui::table::borrow(&token_info.faucet_lock, user); // the entry is dereferences and returned as value (via the asterisk)
        };
        return 0;
    }
    
    // if dex contains information about the amount of swaps a user with specified address has done, this number is returned, otherwise 0 
    public fun get_user_swap_count(dex_info : &DexInfo, user : address) : u64 {
        if(sui::table::contains(&dex_info.swaps, user)){
            return sui::table::borrow(&dex_info.swaps, user);
        };
        return 0;
    }

    fun transfer_coin<CoinType>(coin : sui::coin::Coin<CoinType>, sender : address) {
        if(sui::coin::value(coin)){
            sui::coin::destroy_zero(coin);
        }else{
            sui::transfer::public_transfer(c, sender);
        };
    }

    // passes the task of placing a market order to the internal function
    // assigns the ownership of the returns assets to the sender
    public fun place_market_order(dex_info : &mut DexInfo,
                                  pool : &mut deepbook::clob_v2::Pool<ETH, USDC>,
                                  account_cap : &deepbook::custodian_v2::AccountCap,
                                  quantity : u64,
                                  is_bid : bool,
                                  base_coin : sui::coin::Coin<ETH>,
                                  quote_coin : sui::coin::Coin<USDC>,
                                  c : &sui::clock::Clock,
                                  ctx : &mut TxContext){
                                
        (eth_coin, usdc_coin, dex_coin) = place_market_order_internal(dex_info, pool, account_cap, quantity, is_bid, base_coin, quote_coin, c, ctx);

        let sender : address = sui::tx_context::sender(ctx);
        transfer_coin(eth_coin, sender);
        transfer_coin(usdc_coin, sender);
        transfer_coin(dex_coin, sender);
    }

    // Updates the swapping count for the sender of the request based on his previous interactions
    // Every two swaps by the same user, the dex coin supply is changed for some reason
    // The swap request between the ETH and USDC coins is being passed into the native market order function of clob
    public fun place_market_order_internal(dex_info : &mut DexInfo,
                                  pool : &mut deepbook::clob_v2::Pool<ETH, USDC>,
                                  account_cap : &deepbook::custodian_v2::AccountCap,
                                  quantity : u64,
                                  is_bid : bool,
                                  base_coin : sui::coin::Coin<ETH>,
                                  quote_coin : sui::coin::Coin<USDC>,
                                  c : &sui::clock::Clock,
                                  ctx : &mut TxContext){

        let dex_coin = sui::coin::zero();
        let client_order_id : u64 = 0; //necessary argument in the native sui, dex library (clob) - equal to the amount of swaps done (including current) by the user
        let sender = sui::tx_context::sender(ctx);

        if(sui::table::contains(&dex_info.swaps, sender)){ // in the case the sender has already done swaps in the past
            let current_swaps : u64 = sui::table::borrow_mut(&mut dex_info.swaps, sender);
            let updated_swaps : u64 = *current_swaps + 1;
            *current_swaps = updated_swaps; // increase the count of conducted swaps by 1
            client_order_id = updated_swaps;

            // every second swap, set the number of dex coins and their supply within the dex equal to Float Scaling (Not sure why)
            if(updated_swaps % 2 == 0){
                
                // sum the values of the two balances and store them in the dex coin balance in the form of a coin (so it is transferable)

                increased_supply_balance = sui::balance::increase_supply(&mut dex_info.dex_supply, FLOAT_SCALING);
                increased_supply_coin = sui::coin::from_balance(increased_supply_balance, ctx);
                // store the updated, increased supply in the dex coin struct
                sui::coin::join(mut& dex_coin, increased_supply_coin);
            };
        }else{ // in the case the sender hasn't swapped on the dex yet
            sui::table::add(&mut dex_info.swaps, sender, 1); // initialize his swap count and increase it by 1

        };

        let (eth_coin, usdc_coin) = clob::place_market_order<ETH, USDC>(
            pool,
            account_cap,
            client_order_id,
            quantity,
            is_bid,
            base_coin,
            quote_coin,
            c,
            ctx
        );
        return (eth_coin, usdc_coin, dex_coin);
    }

    // we create a pool where teh values are scaled by float scaling (multiply with 1 billion to get int representation)
    // Ticker size (the minimum price change) = 1 USDC - 1e9  
    // Lot size - 1 
    // Fees paid through - SUI coin 
    public fun create_pool(fee : sui::coin::Coin<SUI>, ctx : &mut TxContext){
        return clob::create_pool<ETH, USDC>(1 * FLOAT_SCALING, 1, fee, ctx);
    } 
    
    // creates ask and bids orders in the pool so people can trade
    // called only when there are no orders in the pool
    public fun populate_pool(dex_info : &DexInfo,
                        pool : clob::Pool<ETH, USDC>,
                        c : &sui::clock::Clock,
                        ctx : &mut TxContext){
        create_ask_orders(dex_info, pool, c, ctx);
        create_bid_orders(dex_info, pool, c, ctx);
    }



    
    // add the token information struct to the dex struct per token type (ETH/USDC) as dynamic field
    public fun setup_token_information_for_dex(dex_info : &mut DexInfo,
                                               eth_cap : sui::coin::TreasuryCap,
                                               usdc_cap : sui::coin::TreasuryCap,
                                               ctx : &mut TxContext){

        // the token information struct is being added to the dex structure, being pointed to with a new identifier produced by sui's typename
        sui::dynamic_field::add(&mut dex_info, sui::type_name::get<ETH>(), TokenInfo{cap : eth_cap, faucet_lock : sui::table::new(ctx)});
        sui::dynamic_field::add(&mut dex_info, sui::type_name::get<USDC>(), TokenInfo{cap : usdc_cap, faucet_lock : sui::table::new(ctx)});
    }

    // checks if the token type hasn't been minted by the user within the current epoch 
    // minting epoch is set as the current one and the token is minted
    public fun mint_token<CoinType>(dex_info : mut& DexInfo

    ) : sui::Coin<CoinType>{

        let sender : address = sui::object::sender(ctx);
        let current_epoch : u64 = sui::tx_context::epoch(ctx);
        let token_info : &mut TokenInfo<CoinType> = sui::dynamic_field::borrow_mut<TypeName, TokenInfo<CoinType>>(&mut dex_info, sui::type_name::get<CoinType>());

        if(sui::table::contains(&token_info.faucet_lock, sender)){ // in the case the sender has already minted the token
            let previous_mint_epoch : u64 = *sui::table::borrow(&token_info.faucet_lock, sender);
            assert!(current_epoch > previous_mint_epoch, EAlreadyMintedThisEpoch); //make sure it happened in a previous epoch
        }
        else{
            sui::table::add(&mut token_info.faucet_lock, sender, 0); // initialize memory for sender's token mint epoch (couldn't we just update it with current epoch?)
        }
    
        // update the mint epoch with current one 
        let mint_epoch : &u64 = table::borrow_mut(&mut token_info.faucet_lock, sender); 
        *mint_epoch = sui::tx_context::epoch(ctx);
        // mint the token
        sui::coin::mint(&mut token_info.cap, if (sui::type_name::get<CoinType>() == get<USDC>()) 100 * FLOAT_SCALING else 1 * FLOAT_SCALING, ctx)
    }
}

//     public fun place_market_order(
//     self: &mut Storage,
//     pool: &mut Pool<ETH, USDC>,
//     account_cap: &AccountCap,
//     quantity: u64,
//     is_bid: bool,
//     base_coin: Coin<ETH>,
//     quote_coin: Coin<USDC>,
//     c: &Clock,
//     ctx: &mut TxContext,    
//   ): (Coin<ETH>, Coin<USDC>, Coin<DEX>)


//   // Import necessary modules and types
//   use std::option;
//   use std::type_name::{get, TypeName};
//   use sui::transfer;
//   use sui::sui::SUI;
//   use sui::clock::{Clock};
//   use sui::balance::{Self, Supply};
//   use sui::object::{Self, UID};
//   use sui::table::{Self, Table};
//   use sui::dynamic_field as df;
//   use sui::tx_context::{Self, TxContext};
//   use sui::coin::{Self, TreasuryCap, Coin};
//   use deepbook::clob_v2::{Self as clob, Pool};
//   use deepbook::custodian_v2::AccountCap;
//   use dex::eth::ETH;
//   use dex::usdc::USDC;