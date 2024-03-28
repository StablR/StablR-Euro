/**
 * SPDX-License-Identifier: MIT
 *
 * Copyright (c) 2018-2020 CENTRE SECZ
 * Copyright (c) 2022 Qredo Ltd.
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */

pragma solidity 0.6.12;

import { SafeMath } from "@openzeppelin/contracts/math/SafeMath.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable } from "../../v1/Ownable.sol";
import { FiatTokenV2_2 } from "../FiatTokenV2_2.sol";
import { FiatTokenProxy } from "../../v1/FiatTokenProxy.sol";
import { V2UpgraderHelper } from "./V2UpgraderHelper.sol";

/**
 * @title V2.2 Upgrader
 * @dev Read docs/v2.2_upgrade.md
 */
contract V2_2Upgrader is Ownable {
    using SafeMath for uint256;

    FiatTokenProxy private _proxy;
    FiatTokenV2_2 private _implementation;
    address private _newProxyAdmin;
    V2UpgraderHelper private _helper;

    /**
     * @notice Constructor
     * @param proxyAddr          FiatTokenProxy contract
     * @param implementationAddr FiatTokenV2_2 implementation contract
     * @param newProxyAdminAddr  Grantee of proxy admin role after upgrade
     */
    constructor(
        FiatTokenProxy proxyAddr,
        FiatTokenV2_2 implementationAddr,
        address newProxyAdminAddr
    ) public Ownable() {
        _proxy = proxyAddr;
        _implementation = implementationAddr;
        _newProxyAdmin = newProxyAdminAddr;
        _helper = new V2UpgraderHelper(address(proxyAddr));
    }

    /**
     * @notice The address of the FiatTokenProxy contract
     * @return Contract address
     */
    function proxy() external view returns (address) {
        return address(_proxy);
    }

    /**
     * @notice The address of the FiatTokenV2 implementation contract
     * @return Contract address
     */
    function implementation() external view returns (address) {
        return address(_implementation);
    }

    /**
     * @notice The address of the V2UpgraderHelper contract
     * @return Contract address
     */
    function helper() external view returns (address) {
        return address(_helper);
    }

    /**
     * @notice The address to which the proxy admin role will be transferred
     * after the upgrade is completed
     * @return Address
     */
    function newProxyAdmin() external view returns (address) {
        return _newProxyAdmin;
    }

    /**
     * @notice Upgrade, transfer proxy admin role to a given address, run a
     * sanity test, and tear down the upgrader contract, in a single atomic
     * transaction. It rolls back if there is an error.
     */
    function upgrade() external onlyOwner {
        // The helper needs to be used to read contract state because
        // AdminUpgradeabilityProxy does not allow the proxy admin to make
        // proxy calls.

        // Check that this contract sufficient funds to run the tests
        uint256 contractBal = _helper.balanceOf(address(this));
        require(contractBal >= 2e5, "V2_1Upgrader: 0.2 EURR needed");

        uint256 callerBal = _helper.balanceOf(msg.sender);

        // Keep original contract metadata
        string memory name = _helper.name();
        string memory symbol = _helper.symbol();
        uint8 decimals = _helper.decimals();
        string memory currency = _helper.currency();
        address masterMinter = _helper.masterMinter();
        address ownerAddr = _helper.fiatTokenOwner();
        address pauser = _helper.pauser();
        address blacklister = _helper.blacklister();

        // Change implementation contract address
        _proxy.upgradeTo(address(_implementation));

        // Transfer proxy admin role
        _proxy.changeAdmin(_newProxyAdmin);

        // Initialize V2 contract
        FiatTokenV2_2 v2_2 = FiatTokenV2_2(address(_proxy));
        v2_2.initializeV2_2();

        // Sanity test
        // Check metadata
        require(
            keccak256(bytes(name)) == keccak256(bytes(v2_2.name())) &&
                keccak256(bytes(symbol)) == keccak256(bytes(v2_2.symbol())) &&
                decimals == v2_2.decimals() &&
                keccak256(bytes(currency)) ==
                keccak256(bytes(v2_2.currency())) &&
                masterMinter == v2_2.masterMinter() &&
                ownerAddr == v2_2.owner() &&
                pauser == v2_2.pauser() &&
                blacklister == v2_2.blacklister(),
            "V2_1Upgrader: metadata test failed"
        );

        // Test balanceOf
        require(
            v2_2.balanceOf(address(this)) == contractBal,
            "V2_1Upgrader: balanceOf test failed"
        );

        // Test transfer
        require(
            v2_2.transfer(msg.sender, 1e5) &&
                v2_2.balanceOf(msg.sender) == callerBal.add(1e5) &&
                v2_2.balanceOf(address(this)) == contractBal.sub(1e5),
            "V2_1Upgrader: transfer test failed"
        );

        // Test approve/transferFrom
        require(
            v2_2.approve(address(_helper), 1e5) &&
                v2_2.allowance(address(this), address(_helper)) == 1e5 &&
                _helper.transferFrom(address(this), msg.sender, 1e5) &&
                v2_2.allowance(address(this), msg.sender) == 0 &&
                v2_2.balanceOf(msg.sender) == callerBal.add(2e5) &&
                v2_2.balanceOf(address(this)) == contractBal.sub(2e5),
            "V2_1Upgrader: approve/transferFrom test failed"
        );

        // Transfer any remaining EURR to the caller
        withdrawEURR();

        // Tear down
        _helper.tearDown();
        selfdestruct(msg.sender);
    }

    /**
     * @notice Withdraw any EURR in the contract
     */
    function withdrawEURR() public onlyOwner {
        IERC20 eurr = IERC20(address(_proxy));
        uint256 balance = eurr.balanceOf(address(this));
        if (balance > 0) {
            require(
                eurr.transfer(msg.sender, balance),
                "V2_1Upgrader: failed to withdraw EURR"
            );
        }
    }

    /**
     * @notice Transfer proxy admin role to newProxyAdmin, and self-destruct
     */
    function abortUpgrade() external onlyOwner {
        // Transfer proxy admin role
        _proxy.changeAdmin(_newProxyAdmin);

        // Tear down
        _helper.tearDown();
        selfdestruct(msg.sender);
    }
}