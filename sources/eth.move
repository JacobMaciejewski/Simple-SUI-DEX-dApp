module dex::eth {
  // Creating a dummy empty object for the ETH object data type
  // It will be used to verify the singular instance of this type with the one witness check  
  public struct ETH has drop {}

  #[allow(lint(share_owned))]
  fun init(witness: ETH, ctx: &mut TxContext) {

      // Creating a new token named ETH with its metadata   
      let (treasury_cap, metadata) = sui::coin::create_currency<ETH>(
            witness, 
            9, // ETH token has 9 decimal points
            b"ETH",
            b"ETH Coin", 
            b"Ethereum Native Coin", // Description of the token
            std::option::some(sui::url::new_unsafe_from_bytes(b"https://s2.coinmarketcap.com/static/img/coins/64x64/1027.png")), // Fetch ETH token logo from the web
            ctx
        );

      transfer::public_transfer(treasury_cap, sui::tx_context::sender(ctx)); // The ownership of the Treasury Cap which contains the max supply of the token is given to the caller
      transfer::public_share_object(metadata); // Metadata are shared to everyone on the global storage
  }

  #[test_only]
  public fun test_token_initialization(ctx: &mut TxContext) {
      init(ETH {}, ctx);
  }
}