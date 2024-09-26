script {
  use aptos_framework::coin::{Self, Coin};
  use aptos_framework::fungible_asset::{Self, FungibleAsset, Metadata};
  use aptos_framework::object::{Self, Object, ConstructorRef};
  use aptos_framework::primary_fungible_store;

  use std::signer;
  use std::string;
  use std::option;

  fun mint_fa(creator: &signer, name: vector<u8>, amount: u64) {
    let token_ctor = object::create_named_object(creator, name);
    primary_fungible_store::create_primary_store_enabled_fungible_asset(
      &token_ctor,
      option::none(),
      string::utf8(name),
      string::utf8(name),
      8,
      string::utf8(b""),
      string::utf8(b""),
    );
    let mint_ref = &fungible_asset::generate_mint_ref(&token_ctor);
    let fa = fungible_asset::mint(mint_ref, amount);
    let token = fungible_asset::asset_metadata(&fa);
    let store = primary_fungible_store::ensure_primary_store_exists(signer::address_of(creator), token);
    fungible_asset::deposit(store, fa);
  }
}