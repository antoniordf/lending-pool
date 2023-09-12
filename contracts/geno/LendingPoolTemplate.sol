// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

// imports

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
// import IERC1155 files (interface and receiver)
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/access/Upgradeable.sol";

contract lendingPoolTemplate is ERC20("PoolToken", "PT"), ReentrancyGuard, Pausable, Ownable, Upgradeable {

    /********************************************************************************************/
    /*                                       DATA VARIABLES                                     */
    /********************************************************************************************/

    // This represents the stablecoin (e.g., USDC) being supplied to and borrowed from the pool.
    IERC20 public stableCoin;


    // This represents the ERC115 principal token that the loanRouter will swap the stablecoins with
    // IERC1155 public principalToken 

    // The loanRouter is the contract that interfaces between the pool and the loan contract.
    address public loanRouter;

    // add runningTotalQty uint 


    /********************************************************************************************/
    /*                                       FUNCTION MODIFIERS                                 */
    /********************************************************************************************/

    modifier onlyLoanRouter() {
        require(msg.sender == loanRouter, "Caller is not authorized");
        _;
    }

    /********************************************************************************************/
    /*                                       CONSTRUCTOR                                        */
    /********************************************************************************************/

    constructor(address _stableCoin, address _principalToken, address _loanRouter) {
        stableCoin = IERC20(_stableCoin);
        loanRouter = _loanRouter;
        //principalToken = _principalToken
    }

    /********************************************************************************************/
    /*                                     SMART CONTRACT FUNCTIONS                             */
    /********************************************************************************************/

    /**
     * @dev Called by lender to deposit funds into the pool.
     */

     function deposit(uint256 _amount, address _recipient) external {
      // transfer stablecoins 
      // mint pooltokens to recipient
    } 


    /**
     * @dev Called by lender to withdraw funds into the pool.
     */

     function withdraw(uint256 _amount) external {

      // check if amount is within limits (i.e. check reserve-ratio)
      // if not revert transaction 

      // otherwise
      // burn msg.sender's pool tokens 
      // calculate appropriate amount of stablecoins to return 

    }
    
    /**
     * @dev Called by anyone to convert principalTokens to stablecoins
     */

     function collectPayment(uint256 _amount, address _loanContract) external {

      // call redeem on LoanContract for _amount of PrincipalTokens

    } 

     /**
     * @dev Called by loanRouter to swap stablecoins for principalTokens
     */

     function borrow(uint256 _amount, address _recipient) external {

      // modifier for onlyLoanRouter 
      // check if _amount satisfies reserveRatio 
      // transfer stablecoins to recipient 

    } 

    function viewInterestRate() public view {

      // qtyA: read totalSupply of PoolTokens 
      // qtyB: read total balance of PrincipalTokens (ERC1155) inside this contract (might be challenging without knowing all IDs)
      // calculate utilisation  (qtyB / qtyA)
      // utilisation => interest rate 


    }

    

}
