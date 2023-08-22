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

    // The debt token represents the debt owed by the borrower to the pool.
    IERC20 public debtToken;
    // The loanRouter is the contract that interfaces between the pool and the loan contract.
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

    constructor(address _debtToken, address _loanRouter) {
        debtToken = IERC20(_debtToken);
        loanRouter = _loanRouter;
    }

    /********************************************************************************************/
    /*                                       UTILITY FUNCTIONS                                  */
    /********************************************************************************************/

    /**
     * @dev This function allows the owner to set the address of the loanRouter.
     */
    function setLoanRouter(address _loanRouter) external onlyOwner {
        loanRouter = _loanRouter;
    }

    /**
     * @dev This function allows the owner to set the address of the debtToken.
     */
    function setDebtToken(address _debtToken) external onlyOwner {
        debtToken = _debtToken;
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
        _to.transfer(_amount);
    }

     /**
     * @dev This function sends all the funds in the contract to the owner's address in case of emergency.
     */
    function cleanSweep() external onlyOwner {
        uint256 ethBalance = address(this).balance;
        payable(owner()).transfer(ethBalance);
    }

    /********************************************************************************************/
    /*                                     SMART CONTRACT FUNCTIONS                             */
    /********************************************************************************************/

    /**
     * @dev Called by lender to deposit funds into the pool.
     */
    function deposit() external payable whenNotPaused nonReentrant {
        require(msg.value > 0, "Amount should be greater than 0");
        emit Deposited(msg.sender, msg.value);

        uint256 poolTokens = (totalSupply() == 0)
            ? msg.value
            : (msg.value * totalSupply()) / address(this).balance;
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

        uint256 maxWithdrawal = (balanceOf(msg.sender) *
            address(this).balance) / totalSupply();
        require(_amount <= maxWithdrawal, "Withdrawal exceeds allowed amount");

        uint256 requiredPoolTokens = (_amount * totalSupply()) /
            address(this).balance;
        _burn(msg.sender, requiredPoolTokens);
        emit TokenBurned(msg.sender, requiredPoolTokens);

        payable(msg.sender).transfer(_amount);
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
        require(
            debtToken.transferFrom(msg.sender, address(this), _debtTokenAmount),
            "Transfer of debt tokens failed"
        );

        loans[_borrower] = Loan({
            amountBorrowed += _notional,
            collateralTokens += _debtTokenAmount
        });

        payable(msg.sender).transfer(_notional);
        emit Borrowed(_borrower, _notional);
    }

     /**
     * @dev This function collects the repayments that the borrower has made to the loan contract.
     * The function is called by the loan router when the borrower repays loans or interest.
     * This function calls the collectPayment function in the loan contract.
     */
    function collectPayment(
        address _loanContract
    ) external whenNotPaused onlyLoanRouter {
        uint256 debtTokenBalance = debtToken.balanceOf(address(this));
        ILoanContract loanContract = ILoanContract(_loanContract);
        loanContract.collectPayment(debtTokenBalance);
    }
}

/********************************************************************************************/
/*                                       INTERFACE                                          */
/********************************************************************************************/

interface ILoanContract {
    function collectPayment(uint256 debtTokenBalance) external;
}
