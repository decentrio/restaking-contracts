script {
  fun initialize_modules() {
    restaking::staker_manager::initialize();
    restaking::operator_manager::initialize();
    restaking::slasher::initialize();
    restaking::withdrawal::initialize();
    restaking::rewards_coordinator::initialize();
    restaking::avs_manager::initialize();
    restaking::earner_manager::initialize();
    restaking::coin_wrapper::initialize();
  }
}