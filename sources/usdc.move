module dex::usdc{
    // USDC token 
    struct USDC has drop {};

    fun init(witness : USDC, ctx : &mut TxContext){
        let (treasury_cap, token_metadata) = sui::coin::create_currency<USDC>(
            witness, // one witness struct used to verify no other token like this exists on-chain
            9, // Number of decimal points used in its amount representation 
            b"USDC", // The symbol of the USDC token
            b"USDC Coin", //Name of the tokens
            b"A stable coin issued by Circle", //The description of the token
            std::option::some(sui::url::new_unsafe_from_bytes(b"https://s3.coinmarketcap.com/static-gravity/image/5a8229787b5e4c809b5914eef709b59a.png")), //stream of bytes recovered from specified link and formatted in image format
            ctx //Context of the transaction
            );

        sui::transfer::public_transfer(treasury_cap, sui::tx_context::sender(ctx));
        sui::transfer::public_share_object(token_metadata);

    }

    #[test_only]
    public fun test_token_initialization(ctx: &mut TxContext) {
        init(USDC {}, ctx);
    }
}