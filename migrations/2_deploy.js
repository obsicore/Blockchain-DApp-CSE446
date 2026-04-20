const HumanitarianAidReliefEscrow = artifacts.require("HumanitarianAidReliefEscrow");

module.exports = function(deployer) {
  deployer.deploy(HumanitarianAidReliefEscrow, "United Nations");
};
