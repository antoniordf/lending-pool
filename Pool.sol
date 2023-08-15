// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract Pool is ERC20("PoolToken", "PT"), ReentrancyGuard {
    /********************************************************************************************/
    /*                                       DATA VARIABLES                                     */
    /********************************************************************************************/
    // This represents the token issued by the pool when liquidity is supplied.
    // Since the Pool itself is an ERC20 token (it inherits from ERC20),
    // this token is the Pool token itself.
    IERC20 public poolToken = IERC20(address(this));

    // This represents the actual stablecoin (e.g., USDC) being supplied to and borrowed from the pool.
    IERC20 public stableCoin;

    address public immutable owner;
    address public loanRouter;
    bool public isActive = true; // Flag to toggle contract between active and inactive

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

    /**
     * @dev Maps lender address (key) to the number of pool tokens issued to the lender (value)
     */
    mapping(address => uint256) public lenderBalances;

    /********************************************************************************************/
    /*                                       EVENT DEFINITIONS                                  */
    /********************************************************************************************/

    event Deposited(address indexed user, uint256 amount);
    event Borrowed(address indexed borrower, uint256 amount);

    /********************************************************************************************/
    /*                                       FUNCTION MODIFIERS                                 */
    /********************************************************************************************/

    modifier requireActive() {
        require(isActive == true, "The contract is not active");
        _;
    }

    modifier onlyLoanRouter() {
        require(msg.sender == loanRouter, "Caller is not authorized");
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "You are not the contract owner");
        _;
    }

    /********************************************************************************************/
    /*                                       CONSTRUCTOR                                        */
    /********************************************************************************************/

    constructor(address _stableCoin, address _loanRouter) {
        stableCoin = IERC20(_stableCoin);
        loanRouter = _loanRouter;
        owner = msg.sender;
    }

    /********************************************************************************************/
    /*                                       UTILITY FUNCTIONS                                  */
    /********************************************************************************************/

    function setActiveFlag(bool _isActive) external onlyOwner {
        isActive = _isActive;
    }

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
            _tokenAddress != address(poolToken),
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
            address(poolToken) != address(0),
            "Cannot rescue ETH from an ETH pool"
        );
        _to.transfer(_amount);
    }

    /**
     * @dev This function sends all the funds in the contract to the owner's address in case of emergency.
     */
    function cleanSweep() external onlyOwner {
        if (address(stableCoin) == address(0)) {
            uint256 ethBalance = address(this).balance;
            payable(owner).transfer(ethBalance);
        } else {
            uint256 stableCoinBalance = stableCoin.balanceOf(address(this));
            stableCoin.transfer(owner, stableCoinBalance);
        }
    }

    /********************************************************************************************/
    /*                                     SMART CONTRACT FUNCTIONS                             */
    /********************************************************************************************/

    /**
     * @dev Called by lender to deposit funds into the pool. The function checks if assets sent are ETH or a stableCoin.
     */
    function deposit(
        uint256 _amount
    ) external payable requireActive nonReentrant {
        if (address(stableCoin) == address(0)) {
            require(msg.value == _amount, "msg.value and _amount dont match");
            lenderBalances[msg.sender] += _amount;
            _mint(msg.sender, _amount);
        } else {
            require(msg.value == 0, "Shouldnt send ETH with token deposit");
            lenderBalances[msg.sender] += _amount;
            stableCoin.transferFrom(msg.sender, address(this), _amount);
            _mint(msg.sender, _amount);
        }
        emit Deposited(msg.sender, _amount);
    }

    function borrow(
        address _borrower,
        uint256 _notional,
        address _collateralToken,
        uint256 _collateralAmount
    ) external onlyLoanRouter requireActive {
        require(
            _notional <= address(this).balance,
            "Not enough funds in the pool"
        );
        // Accept the collateral tokens from the loanRouter.
        IERC20 collateral = IERC20(_collateralToken);
        require(
            collateral.transferFrom(
                msg.sender,
                address(this),
                _collateralAmount
            ),
            "Transfer of collateral tokens failed"
        );

        // Update the loans mapping with the borrower's details and the collateral tokens
        loans[_borrower] = Loan({
            amountBorrowed: _notional,
            collateralTokens: _collateralAmount
        });

        // Transfer the requested stableCoin or ETH to the loanRouter.
        if (address(stableCoin) == address(0)) {
            payable(msg.sender).transfer(_notional);
            emit Borrowed(_borrower, _notional);
        } else {
            require(
                stableCoin.transfer(msg.sender, _notional),
                "StableCoin transfer failed"
            );
            emit Borrowed(_borrower, _notional);
        }
    }
}
