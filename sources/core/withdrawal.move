module restaking::withdrawal {
  use aptos_framework::event;
  use aptos_framework::fungible_asset::{Metadata};
  use aptos_framework::object::{Object};
  use aptos_framework::account::{Self, SignerCapability};
  use aptos_framework::timestamp;
  use aptos_std::smart_table::{Self, SmartTable};
  use aptos_std::aptos_hash;
  use std::string;


  use std::vector;
  use std::signer;
  use std::bcs;
  use restaking::package_manager;
  use restaking::staker_manager;
  use restaking::operator_manager;
  use restaking::math_utils;
  use restaking::epoch;
  use restaking::slasher;
  use restaking::slashing_accounting;

  const MAX_WITHDRAWAL_DELAY: u64 = 7 * 24 * 3600; // 7 days
  const WITHDRAWAL_NAME: vector<u8> = b"WITHDRAWAL";

  const ETOKENS_ZERO_LENGTH: u64 = 301;
  const EWITHDRAWAL_NOT_PENDING: u64 = 302;
  const EWITHDRAWAL_DELAY_NOT_PASSED_YET: u64 = 303;
  const EWITHDRAWAL_INPUT_LENGTH_MISMATCH: u64 = 304;
  const ESENDER_NOT_WITHDRAWER: u64 = 305;
  const EMAX_WITHDRAWAL_DELAY_EXCEEDED: u64 = 306;
  const EWITHDRAWAL_STILL_SLASHABLE: u64 = 307;

  struct Withdrawal has copy, drop, store {
    staker: address,
    delegated_to: address,
    withdrawer: address,
    nonce: u256,
    start_time: u64,
    tokens: vector<Object<Metadata>>,
    nonnormalized_shares: vector<u128>,
  }

  struct PendingWithdrawalData has drop, store {
    is_pending: bool,
    creation_epoch: u64,
  }

  struct WithdrawalConfigs has key {
    signer_cap: SignerCapability,
    min_withdrawal_delay: u64,
    pending_withdrawals: SmartTable<u256, PendingWithdrawalData>,
    token_withdrawal_delay: SmartTable<Object<Metadata>, u64>,
  }

  #[event]
  struct WithdrawalQueued has drop, store{
    withdrawal_root: u256,
    withdrawal: Withdrawal,
  }

  #[event]
  struct WithdrawalCompleted has drop, store {
    withdrawal_root: u256,
  }

  #[event]
  struct MinWithdrawalDelaySet has drop, store{
    min_withdrawal_delay: u64,
  }

  #[event]
  struct TokenWithdrawalDelaySet has drop, store {
    token: Object<Metadata>,
    token_withdrawal_delay: u64,
  }

    /// Create the delegation manager account to host staking delegations.
    public entry fun initialize() {
        if (is_initialized()) {
            return
        };

        // derive a resource account from swap signer to manage Wrapper Account
        let staking_signer = &package_manager::get_signer();
        let (withdrawal_signer, signer_cap) = account::create_resource_account(staking_signer, WITHDRAWAL_NAME);
        package_manager::add_address(string::utf8(WITHDRAWAL_NAME), signer::address_of(&withdrawal_signer));
        move_to(&withdrawal_signer, WithdrawalConfigs {
            signer_cap,
            min_withdrawal_delay: 24 * 3600, // 1 day
            pending_withdrawals: smart_table::new(),
            token_withdrawal_delay: smart_table::new()
        });
    }

    #[view]
    public fun is_initialized(): bool {
        package_manager::address_exists(string::utf8(WITHDRAWAL_NAME))
    }
    #[view]
    /// Return the address of the resource account that stores pool manager configs.
    public fun withdrawal_address(): address {
      package_manager::get_address(string::utf8(WITHDRAWAL_NAME))
    }

  public entry fun undelegate(sender: &signer, staker: address) acquires WithdrawalConfigs{
    let operator = staker_manager::undelegate(sender, staker);
    let (tokens, token_shares) = staker_manager::staker_nonormalized_shares(staker);

    if(vector::length(&tokens) > 0){
      remove_shares_and_queue_withdrawal(
        staker,
        operator,
        staker,
        tokens,
        token_shares
      );
    };
  }

  public entry fun queue_withdrawal(
    sender: &signer,
    tokens: vector<Object<Metadata>>,
    nonnormalized_shares: vector<u128>
  ) acquires WithdrawalConfigs {
    let sender_addr = signer::address_of(sender);
    let operator = staker_manager::delegate_of(sender_addr);
    remove_shares_and_queue_withdrawal(sender_addr, operator, sender_addr, tokens, nonnormalized_shares);
  }


  fun remove_shares_and_queue_withdrawal(
    staker: address,
    operator: address,
    withdrawer: address,
    tokens: vector<Object<Metadata>>,
    nonnormalized_shares: vector<u128>
  ): Withdrawal acquires WithdrawalConfigs {
    let tokens_length = vector::length(&tokens);
    let shares_length = vector::length(&nonnormalized_shares);

    assert!(tokens_length > 0, ETOKENS_ZERO_LENGTH);
    assert!(tokens_length == shares_length, EWITHDRAWAL_INPUT_LENGTH_MISMATCH);
    let idx = 0;
    while(idx < tokens_length){
      if(operator != @0x0){
        let token = vector::borrow(&tokens, idx);
        let token_shares = vector::borrow(&nonnormalized_shares, idx);
        operator_manager::decrease_operator_shares(operator, staker, *token, *token_shares);
        staker_manager::remove_shares(staker, *token, *token_shares);
      };
      idx = idx + 1;
    };
    let nonce = staker_manager::cummulative_withdrawals_queued(staker);
    staker_manager::increment_cummulative_withdrawals_queued(staker);

    let withdrawal = Withdrawal {
      staker,
      delegated_to: operator,
      withdrawer,
      nonce,
      start_time: timestamp::now_seconds(),
      tokens,
      nonnormalized_shares
    };

    let withdrawal_root = withdrawal_root(&withdrawal);
    let configs = mut_withdrawal_configs();
    smart_table::upsert(&mut configs.pending_withdrawals, withdrawal_root, PendingWithdrawalData {
      is_pending: true,
      creation_epoch: epoch::current_epoch()
    });

    event::emit(WithdrawalQueued {
      withdrawal_root,
      withdrawal
    });

    withdrawal
  }

  public entry fun complete_queued_withdrawal(
    sender: &signer,
    staker: address,
    delegated_to: address,
    withdrawer: address,
    nonce: u256,
    start_time: u64,
    tokens: vector<Object<Metadata>>,
    nonnormalized_shares: vector<u128>,
    receive_as_tokens: bool
  ) acquires WithdrawalConfigs {

    let sender_addr = signer::address_of(sender);

    assert!(sender_addr == withdrawer, ESENDER_NOT_WITHDRAWER);

    let withdrawal_root = withdrawal_root(&Withdrawal {
      staker,
      delegated_to,
      withdrawer,
      nonce,
      start_time,
      tokens,
      nonnormalized_shares
    });
    let configs = mut_withdrawal_configs();

    let pending_withdrawal_data = smart_table::borrow(&configs.pending_withdrawals, withdrawal_root);
    let end_of_slashability_epoch = epoch::end_of_slashability_epoch(pending_withdrawal_data.creation_epoch);
    
    assert!(epoch::current_epoch() > end_of_slashability_epoch, EWITHDRAWAL_STILL_SLASHABLE);
    assert!(pending_withdrawal_data.is_pending == true, EWITHDRAWAL_NOT_PENDING);

    smart_table::remove(&mut configs.pending_withdrawals, withdrawal_root);

    let now = timestamp::now_seconds();
    assert!(start_time + configs.min_withdrawal_delay <= now, EWITHDRAWAL_DELAY_NOT_PASSED_YET);

    let tokens_length = vector::length(&tokens);

    let idx = 0;

    while(idx < tokens_length){
      let token = *vector::borrow(&tokens, idx);
      
      let withdrawal_delay = *smart_table::borrow_with_default(&configs.token_withdrawal_delay, token, &0);
      assert!(start_time + withdrawal_delay <= now, EWITHDRAWAL_DELAY_NOT_PASSED_YET);
      
      let nonnormalized_shares = *vector::borrow(&nonnormalized_shares, idx);

      let (can_withdraw, scaling_factor) = slasher::get_withdrawability_and_scaling_factor_at_epoch(
        delegated_to,
        token,
        end_of_slashability_epoch
      );

      assert!(can_withdraw, EWITHDRAWAL_STILL_SLASHABLE);

      let shares = slashing_accounting::normalize(nonnormalized_shares, scaling_factor);
      
      if(receive_as_tokens){
        staker_manager::withdraw(staker, token, shares);
      } else {
        staker_manager::add_shares(sender_addr, token, nonnormalized_shares);
        let operator = staker_manager::delegate_of(staker);
        if(operator != @0x0){
          operator_manager::increase_operator_shares(operator, sender_addr, token, nonnormalized_shares);
        }
      };
      idx = idx + 1;
    };

    event::emit(WithdrawalCompleted {
      withdrawal_root
    });
  } 

  #[view]
  public fun withdrawal_delay(tokens: vector<Object<Metadata>>): u64 acquires WithdrawalConfigs {
    let configs = withdrawal_configs();
    let withdrawal_delay = configs.min_withdrawal_delay;
    let tokens_length = vector::length(&tokens);

    let idx = 0;
    while(idx < tokens_length){
      let token = *vector::borrow(&tokens, idx);
      let token_withdrawal_delay = *smart_table::borrow_with_default(&configs.token_withdrawal_delay, token, &0);
      if(withdrawal_delay < token_withdrawal_delay){
        withdrawal_delay = token_withdrawal_delay;
      };
      idx = idx + 1;
    };

    withdrawal_delay
  }

  fun withdrawal_root(withdrawal: &Withdrawal): u256 {
    let bytes = bcs::to_bytes(withdrawal);
    let hash_vec = aptos_hash::keccak256(bytes);
    math_utils::bytes32_to_u256(hash_vec)
  }

  inline fun withdrawal_configs(): &WithdrawalConfigs acquires WithdrawalConfigs {
    borrow_global<WithdrawalConfigs>(withdrawal_address())
  }

  inline fun mut_withdrawal_configs(): &mut WithdrawalConfigs acquires WithdrawalConfigs{
    borrow_global_mut<WithdrawalConfigs>(withdrawal_address())
  }

  // OPERATIONS
  public entry fun set_min_withdrawal_delay(owner: &signer, delay: u64) acquires WithdrawalConfigs{
    package_manager::only_owner(signer::address_of(owner));
    assert!(delay <= MAX_WITHDRAWAL_DELAY, EMAX_WITHDRAWAL_DELAY_EXCEEDED);
    event::emit(MinWithdrawalDelaySet {
      min_withdrawal_delay: delay
    });
    let configs = mut_withdrawal_configs();
    configs.min_withdrawal_delay = delay;
  }


  #[view]
  public fun minimum_withdrawal_delay(): u64 acquires WithdrawalConfigs{
    let configs = withdrawal_configs();
    return configs.min_withdrawal_delay
  }

  public entry fun set_token_withdrawal_delay(owner: &signer, token: Object<Metadata>, delay: u64) acquires WithdrawalConfigs{
    package_manager::only_owner(signer::address_of(owner));
    assert!(delay <= MAX_WITHDRAWAL_DELAY, EMAX_WITHDRAWAL_DELAY_EXCEEDED);

    event::emit(TokenWithdrawalDelaySet {
      token,
      token_withdrawal_delay: delay
    });
    let configs = mut_withdrawal_configs();
    smart_table::upsert(&mut configs.token_withdrawal_delay, token, delay);
  }

  #[test_only]
  public fun queue_withdrawal_for_test(
    sender: &signer,
    tokens: vector<Object<Metadata>>,
    nonnormalized_shares: vector<u128>
  ): (
    address, 
    address, 
    address, 
    u256, 
    u64,
  ) acquires WithdrawalConfigs {
    let sender_addr = signer::address_of(sender);
    let operator = staker_manager::delegate_of(sender_addr);
    let withdrawal = remove_shares_and_queue_withdrawal(sender_addr, operator, sender_addr, tokens, nonnormalized_shares);
    (
      withdrawal.staker,
      withdrawal.delegated_to,
      withdrawal.withdrawer,
      withdrawal.nonce,
      withdrawal.start_time,
    )
  }

  #[test_only]
  friend restaking::delegation_tests;
}