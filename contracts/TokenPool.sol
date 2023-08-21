// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/access/Upgradeable.sol";

contract Pool is
    ERC20("PoolToken", "PT"),
    ReentrancyGuard,
    Pausable,
    Ownable,
    Upgradeable
{
    /********************************************************************************************/
    /*                                       DATA VARIABLES                                     */
    /********************************************************************************************/

    // This represents the actual stablecoin (e.g., USDC) being supplied to and borrowed from the pool.
    IERC20 public stableCoin;
    IERC20 public debtToken;

    address public loanRouter;

    /**
     * @dev Struct containing loan information. collateralTokens represent ownership of the assets in collateral.
     */
    struct Loan {
        uint256 amountBorrowed;
        uint256 collateralTokens;
    }

    /**
     * @dev Maps borrower address (key) to the value of the loan (value)
     */
    mapping(address => Loan) public loans;

    /********************************************************************************************/
    /*                                       EVENT DEFINITIONS                                  */
    /********************************************************************************************/

    event Deposited(address indexed user, uint256 amount);
    event Borrowed(address indexed borrower, uint256 amount);
    event PoolTokensMinted(address indexed lender, uint256 poolTokens);
    event Withdrawal(address indexed lender, uint256 amount);
    event TokenBurned(address indexed lender, uint256 tokenAmount);
    event PaymentCollected(uint256 amount);

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

    constructor(address _stableCoin, address _debtToken, address _loanRouter) {
        stableCoin = IERC20(_stableCoin);
        debtToken = IERC20(_debtToken);
        loanRouter = _loanRouter;
    }

    /********************************************************************************************/
    /*                                       UTILITY FUNCTIONS                                  */
    /********************************************************************************************/

    function setLoanRouter(address _loanRouter) external onlyOwner {
        loanRouter = _loanRouter;
    }

    /**
     * @dev This function allows the owner to rescue mistakenly sent tokens to the contract.
     */
    function rescueTokens(
        address _tokenAddress,
        address _to,
        uint256 _amount
    ) external onlyOwner {
        require(
            _tokenAddress != address(this),
            "Cannot rescue main pool token"
        );
        IERC20(_tokenAddress).transfer(_to, _amount);
    }

    /**
     * @dev This function allows the owner to rescue mistakenly sent ETH to the contract.
     */
    function rescueETH(
        address payable _to,
        uint256 _amount
    ) external onlyOwner {
        require(
            address(this) != address(0),
            "Cannot rescue ETH from an ETH pool"
        );
        _to.transfer(_amount);
    }

    /**
     * @dev This function sends all the funds in the contract to the owner's address in case of emergency.
     */
    function cleanSweep() external onlyOwner {
        uint256 stableCoinBalance = stableCoin.balanceOf(address(this));
        stableCoin.transfer(owner(), stableCoinBalance);
    }

    /********************************************************************************************/
    /*                                     SMART CONTRACT FUNCTIONS                             */
    /********************************************************************************************/

    /**
     * @dev Called by lender to deposit funds into the pool.
     */
    function deposit(uint256 _amount) external whenNotPaused nonReentrant {
        require(_amount > 0, "Amount should be greater than 0");
        require(
            stableCoin.transferFrom(msg.sender, address(this), _amount),
            "Pool failed to receive funds"
        );
        emit Deposited(msg.sender, _amount);

        // Calculate the proportional number of poolTokens to be minted
        uint256 poolTokens = (totalSupply() == 0)
            ? _amount
            : (_amount * totalSupply()) / address(this).balance;
        _mint(msg.sender, poolTokens);
        emit PoolTokensMinted(msg.sender, poolTokens);
    }

    /**
     * @dev Called by lender to withdraw funds from the pool.
     */
    function withdraw(uint256 _amount) external whenNotPaused nonReentrant {
        require(_amount > 0, "Amount has to be greater than 0");
        require(
            _amount <= address(this).balance,
            "Not enough funds in the pool"
        );

        // Calculate maximum amount of stable coins the lender can withdraw
        uint256 maxWithdrawal = (balanceOf(msg.sender) *
            address(this).balance) / totalSupply();
        require(_amount <= maxWithdrawal, "Withdrawal exceeds allowed amount");

        // Calculating how many pool tokens need to be sent to this contract
        uint256 requiredPoolTokens = (_amount * totalSupply()) /
            address(this).balance;

        // Burns the received pool tokens
        _burn(msg.sender, requiredPoolTokens);
        emit TokenBurned(msg.sender, requiredPoolTokens);

        // transfers stablecoins to caller in proportion to the tokens he sent (must take into account interest)
        stableCoin.transfer(msg.sender, _amount);
        emit Withdrawal(msg.sender, _amount);
    }

    /**
     * @dev Called by the loanRouter. This function accepts the debt token and sends the borrowed funds to the loanRouter.
     */
    function borrow(
        address _borrower,
        uint256 _notional,
        uint256 _debtTokenAmount
    ) external onlyLoanRouter whenNotPaused {
        require(
            _notional <= address(this).balance,
            "Not enough funds in the pool"
        );
        // Accept the debt tokens from the loanRouter.
        require(
            debtToken.transferFrom(msg.sender, address(this), _debtTokenAmount),
            "Transfer of debt tokens failed"
        );

        // Update the loans mapping with the loan's details and the debt tokens
        loans[_borrower] = Loan({
            amountBorrowed: _notional,
            debtTokenAmount: _debtTokenAmount
        });

        // Transfer the requested stableCoin or ETH to the loanRouter.
        require(
            stableCoin.transfer(msg.sender, _notional),
            "StableCoin transfer failed"
        );
        emit Borrowed(_borrower, _notional);
    }

    /**
     * @dev This function collects the repayments that the borrower has made to the loan contract.
     * The function is called by the function that the borrower calls in the loan contract when repaying loans or interest.
     * When collecting the funds, this function sends the debt token to the loan contract.
     */
    function collectPayment(
        uint256 _amount,
        uint256 _debt_outstanding
    ) external whenNotPaused {
        // Get a balance of debt tokens held by this contract.
        uint256 debtTokenBalance = debtToken.balanceOf(address(this));
        require(debtTokenBalance > 0, "No debt tokens available");
        // Divide outstanding debt by debt token balance to find unit value of debt token
        uint256 debtTokenUnitValue = _debt_outstanding / debtTokenBalance;
        // Divide _amount by unit value of debt token to find the amount of debt tokens to send to the loan contract
        uint256 requiredDebtTokens = _amount / debtTokenUnitValue;
        // Send debt tokens to the loan contract
        require(
            debtToken.transfer(msg.sender, requiredDebtTokens),
            "Failed to transfer debt tokens"
        );
        // Transfer _amount from the loan contract to the pool
        require(
            stableCoin.transferFrom(msg.sender, address(this), _amount),
            "Failed to collect payment"
        );
        emit PaymentCollected(_amount);
    }
}
