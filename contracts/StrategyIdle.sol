// SPDX-License-Identifier: GPL-3.0
// Feel free to change the license, but this is what we use

// Feel free to change this version of Solidity. We support >=0.6.0 <0.7.0;
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

// These are the core Yearn libraries
import {
    BaseStrategy,
    StrategyParams
} from "@yearnvaults/contracts/BaseStrategy.sol";
import "@openzeppelinV3/contracts/token/ERC20/IERC20.sol";
import "@openzeppelinV3/contracts/math/Math.sol";
import "@openzeppelinV3/contracts/math/SafeMath.sol";
import "@openzeppelinV3/contracts/utils/Address.sol";
import "@openzeppelinV3/contracts/token/ERC20/SafeERC20.sol";

import "../interfaces/Idle/IIdleTokenV3_1.sol";
import "../interfaces/Idle/IdleController.sol";
import "../interfaces/Compound/Comptroller.sol";
import "../interfaces/Uniswap/IUniswapRouter.sol";

contract StrategyIdle is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    address immutable public uniswapRouterV2;
    address immutable public comp;
    address immutable public idle;
    address immutable public comptroller;
    address immutable public idleController;
    address immutable public idleYieldToken;
    address immutable public underlying;
    address immutable public referral;

    address[] public uniswapCompPath;
    address[] public uniswapIdlePath;

    constructor(
        address _vault,
        address _comp,
        address _idle,
        address _weth,
        address _comptroller,
        address _idleController,
        address _idleYieldToken,
        address _underlying,
        address _referral,
        address _uniswapRouterV2
    ) public BaseStrategy(_vault) {
        comp = _comp;
        idle = _idle;
        comptroller = _comptroller;
        idleController = _idleController;
        idleYieldToken = _idleYieldToken;
        underlying = _underlying;
        referral = _referral;

        uniswapRouterV2 = _uniswapRouterV2;
        uniswapCompPath = [_comp, _weth, _idle];
        uniswapIdlePath = [_idle, _weth, _underlying];
    }

    // ******** OVERRIDE THESE METHODS FROM BASE CONTRACT ************

    function name() external override pure returns (string memory) {
        return "StrategyIdle";
    }

    function estimatedTotalAssets() public override view returns (uint256) {
        // TODO: Build a more accurate estimate using the value of all positions in terms of `want`
        return want.balanceOf(address(this))
                   .add(balanceOnIdle()) //TODO: estimate COMP+IDLE value
        ;
    }

    /*
     * Perform any strategy unwinding or other calls necessary to capture the "free return"
     * this strategy has generated since the last time it's core position(s) were adjusted.
     * Examples include unwrapping extra rewards. This call is only used during "normal operation"
     * of a Strategy, and should be optimized to minimize losses as much as possible. This method
     * returns any realized profits and/or realized losses incurred, and should return the total
     * amounts of profits/losses/debt payments (in `want` tokens) for the Vault's accounting
     * (e.g. `want.balanceOf(this) >= _debtPayment + _profit - _loss`).
     *
     * NOTE: `_debtPayment` should be less than or equal to `_debtOutstanding`. It is okay for it
     *       to be less than `_debtOutstanding`, as that should only used as a guide for how much
     *       is left to pay back. Payments should be made to minimize loss from slippage, debt,
     *       withdrawal fees, etc.
     */
    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {
        // Try to pay debt asap
        if (_debtOutstanding > 0) {
            uint256 _amountFreed = liquidatePosition(_debtOutstanding);
            // Using Math.min() since we might free more than needed
            _debtPayment = Math.min(_amountFreed, _debtOutstanding);
        }

        //TODO: is it worth the optimization?
        if (
            IdleController(idleController).idleAccrued(address(idleYieldToken)) > 0 || 
            Comptroller(comptroller).compAccrued(address(idleYieldToken)) > 0
        ) {
            IIdleTokenV3_1(idleYieldToken).redeemIdleToken(0);
        }

        // If we have IDLE or COMP, let's convert them!
        // This is done in a separate step since there might have been
        // a migration or an exitPosition
        
        // 1. COMP => IDLE via ETH
        // 2. total IDLE => underlying via ETH 
        // This might be > 0 because of a strategy migration
        uint256 balanceOfWantBeforeSwap = balanceOfWant();
        _liquidateComp();
        _liquidateIdle();
        _profit = balanceOfWant().sub(balanceOfWantBeforeSwap);
    }

    /*
     * Perform any adjustments to the core position(s) of this strategy given
     * what change the Vault made in the "investable capital" available to the
     * strategy. Note that all "free capital" in the strategy after the report
     * was made is available for reinvestment. Also note that this number could
     * be 0, and you should handle that scenario accordingly.
     */
    function adjustPosition(uint256 _debtOutstanding) internal override {
        // TODO: Do something to invest excess `want` tokens (from the Vault) into your positions
        // NOTE: Try to adjust positions so that `_debtOutstanding` can be freed up on *next* harvest (not immediately)

        //emergency exit is dealt with in prepareReturn
        if (emergencyExit) {
            return;
        }

        uint256 _wantAvailable = balanceOfWant().sub(_debtOutstanding);
        if (_wantAvailable > 0) {
            IIdleTokenV3_1(idleYieldToken).mintIdleToken(_wantAvailable, true, referral);
        }
    }

    /*
     * Make as much capital as possible "free" for the Vault to take. Some
     * slippage is allowed. The goal is for the strategy to divest as quickly as possible
     * while not suffering exorbitant losses. This function is used during emergency exit
     * instead of `prepareReturn()`. This method returns any realized losses incurred, and
     * should also return the amount of `want` tokens available to repay outstanding debt
     * to the Vault.
     */
    function exitPosition(uint256 _debtOutstanding)
        internal
        override
        returns (uint256 _profit, uint256 _loss, uint256 _debtPayment)
    {
        //TODO: avoid any check of emergency exit (e.g. virtual price)
        return prepareReturn(_debtOutstanding);
    }

    /*
     * Liquidate as many assets as possible to `want`, irregardless of slippage,
     * up to `_amountNeeded`. Any excess should be re-invested here as well.
     */
    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _amountFreed)
    {
        // TODO: Do stuff here to free up to `_amountNeeded` from all positions back into `want`
        // NOTE: Return `_amountFreed`, which should be `<= _amountNeeded`

        if (balanceOfWant() < _amountNeeded) {
            //TODO: check virtual price not decreasing
            uint256 currentVirtualPrice = IIdleTokenV3_1(idleYieldToken).tokenPrice();
            uint256 valueToRedeem = (_amountNeeded.sub(balanceOfWant())).mul(1e18).div(currentVirtualPrice);

            IIdleTokenV3_1(idleYieldToken).redeemIdleToken(valueToRedeem);
        }

        _amountFreed = balanceOfWant();
    }

    // NOTE: Can override `tendTrigger` and `harvestTrigger` if necessary

    function prepareMigration(address _newStrategy) internal override {
        // TODO: Transfer any non-`want` tokens to the new strategy
        // NOTE: `migrate` will automatically forward all `want` in this strategy to the new one

        uint256 balance = IERC20(idleYieldToken).balanceOf(address(this));

        // this automatically claims the COMP and IDLE gov tokens
        IIdleTokenV3_1(idleYieldToken).redeemIdleToken(balance);

        // Transfer COMP and IDLE to new strategy
        IERC20(comp).transfer(_newStrategy, IERC20(comp).balanceOf(address(this)));
        IERC20(idle).transfer(_newStrategy, IERC20(idle).balanceOf(address(this)));
    }

    function protectedTokens()
        internal
        override
        view
        returns (address[] memory)
    {
        address[] memory protected = new address[](4);

        protected[0] = address(want); // TODO: should be default included?
        protected[1] = idleYieldToken;
        protected[2] = idle;
        protected[3] = comp;

        return protected;
    }

    function balanceOnIdle() public view returns (uint256) {
        uint256 currentVirtualPrice = IIdleTokenV3_1(idleYieldToken).tokenPrice();
        //TODO: check virtual price not decreasing
        return IERC20(idleYieldToken).balanceOf(address(this)).mul(currentVirtualPrice).div(1e18);
    }

    function balanceOfWant() public view returns (uint256) {
        return IERC20(want).balanceOf(address(this));
    }

    function _liquidateComp() internal {
        uint256 compBalance = IERC20(comp).balanceOf(address(this));
        if (compBalance > 0) {
            IERC20(comp).safeApprove(uniswapRouterV2, 0);
            IERC20(comp).safeApprove(uniswapRouterV2, compBalance);
            IUniswapRouter(uniswapRouterV2).swapExactTokensForTokens(
                compBalance, 1, uniswapCompPath, address(this), block.timestamp
            );
        }
    }

    function _liquidateIdle() internal {
        uint256 idleBalance = IERC20(idle).balanceOf(address(this));
        if (idleBalance > 0) {
            IERC20(idle).safeApprove(uniswapRouterV2, 0);
            IERC20(idle).safeApprove(uniswapRouterV2, idleBalance);

            IUniswapRouter(uniswapRouterV2).swapExactTokensForTokens(
                idleBalance, 1, uniswapIdlePath, address(this), block.timestamp
            );
        }
    }
}